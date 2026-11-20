-- StockLab Online: temporary room player names, optional passwords, and debt offer phase.
-- Apply after the base schema, room passwords, game engine, and competition-order-draw migrations.

ALTER TABLE public.room_members ADD COLUMN IF NOT EXISTS display_name text;
UPDATE public.room_members rm
SET display_name=coalesce(nullif(btrim(p.display_name),''),'Pemain')
FROM public.profiles p
WHERE p.id=rm.user_id AND (rm.display_name IS NULL OR btrim(rm.display_name)='');
UPDATE public.room_members SET display_name='Pemain' WHERE display_name IS NULL OR btrim(display_name)='';
ALTER TABLE public.room_members ALTER COLUMN display_name SET DEFAULT 'Pemain';
ALTER TABLE public.room_members ALTER COLUMN display_name SET NOT NULL;

-- Stop keeping player profiles as persistent data.
DELETE FROM public.profiles;

CREATE OR REPLACE FUNCTION private.create_room_impl(p_display_name text, p_max_players integer, p_password text, p_bidding_seconds integer, p_turn_seconds integer, p_idle_timeout_minutes integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_room_id uuid;
  v_code text;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING errcode='28000'; END IF;
  IF p_display_name IS NULL OR char_length(trim(p_display_name)) NOT BETWEEN 2 AND 24 THEN
    RAISE EXCEPTION 'Username must be 2 to 24 characters' USING errcode='22023';
  END IF;
  IF p_max_players IS NULL OR p_max_players NOT BETWEEN 3 AND 5 THEN
    RAISE EXCEPTION 'Room capacity must be between 3 and 5' USING errcode='22023';
  END IF;
  IF p_bidding_seconds IS NULL OR p_bidding_seconds NOT BETWEEN 15 AND 600
     OR p_turn_seconds IS NULL OR p_turn_seconds NOT BETWEEN 15 AND 300
     OR p_idle_timeout_minutes IS NULL OR p_idle_timeout_minutes NOT BETWEEN 5 AND 120 THEN
    RAISE EXCEPTION 'Durasi room di luar batas yang diizinkan.' USING errcode='22023';
  END IF;

  FOR attempt IN 1..10 LOOP
    SELECT string_agg(substr(v_alphabet,(floor(random()*length(v_alphabet))::int+1),1),'')
    INTO v_code FROM generate_series(1,6);
    INSERT INTO public.rooms(
      invite_code,host_id,max_players,bidding_seconds,turn_seconds,idle_timeout_minutes,last_activity_at
    )
    VALUES(v_code,v_user_id,p_max_players,p_bidding_seconds,p_turn_seconds,p_idle_timeout_minutes,now())
    ON CONFLICT(invite_code) DO NOTHING RETURNING id INTO v_room_id;
    IF v_room_id IS NOT NULL THEN EXIT; END IF;
  END LOOP;
  IF v_room_id IS NULL THEN
    RAISE EXCEPTION 'Could not allocate a unique room code. Try again.' USING errcode='55000';
  END IF;

  IF nullif(p_password,'') IS NOT NULL THEN
    INSERT INTO private.room_credentials(room_id,password_hash)
    VALUES(v_room_id,'sha256'||chr(36)||encode(extensions.digest(convert_to(p_password,'UTF8'),'sha256'),'hex'));
  END IF;
  INSERT INTO public.room_members(room_id,user_id,seat_no,is_ready,display_name)
  VALUES(v_room_id,v_user_id,1,true,trim(p_display_name));

  RETURN jsonb_build_object(
    'room_id',v_room_id,'invite_code',v_code,'seat_no',1,'max_players',p_max_players,
    'bidding_seconds',p_bidding_seconds,'turn_seconds',p_turn_seconds,'idle_timeout_minutes',p_idle_timeout_minutes
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION private.start_game_impl(p_room_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_player_count integer;
  v_players jsonb;
  v_action_deck jsonb;
  v_standard_economy jsonb;
  v_special_economy jsonb;
  v_economy_deck jsonb;
  v_economy_stacks jsonb := '{}'::jsonb;
  v_stack jsonb;
  v_sector text;
  v_game_id uuid;
  v_state jsonb;
  v_mutual_fund_pair jsonb;
  v_order_cards jsonb;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING errcode='28000'; END IF;
  SELECT * INTO v_room FROM public.rooms WHERE id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Room not found' USING errcode='P0002'; END IF;
  IF v_room.host_id<>v_user_id THEN RAISE EXCEPTION 'Only host can start' USING errcode='42501'; END IF;
  IF v_room.status<>'waiting' THEN RAISE EXCEPTION 'Room is not waiting' USING errcode='55000'; END IF;
  IF EXISTS(SELECT 1 FROM public.games WHERE room_id=p_room_id) THEN
    RAISE EXCEPTION 'A game already exists for this room' USING errcode='23505';
  END IF;

  SELECT count(*)::integer INTO v_player_count FROM public.room_members WHERE room_id=p_room_id;
  IF v_player_count NOT BETWEEN 3 AND 5 THEN
    RAISE EXCEPTION 'Room needs 3 to 5 players' USING errcode='22023';
  END IF;
  IF EXISTS(SELECT 1 FROM public.room_members WHERE room_id=p_room_id AND is_ready IS NOT TRUE) THEN
    RAISE EXCEPTION 'All players must be ready' USING errcode='55000';
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'user_id',q.user_id,'display_name',q.display_name,'seat_no',q.seat_no,
    'is_host',q.user_id=v_room.host_id,'order_no',q.order_no,'order_card_number',NULL,
    'shares',jsonb_build_object('finance',0,'consumer',0,'agriculture',0,'mining',0,'mutual_fund',0),
    'split_tokens',jsonb_build_object('finance',0,'consumer',0,'agriculture',0,'mining',0)
  ) ORDER BY q.order_no)
  INTO v_players
  FROM (
    SELECT rm.user_id,rm.seat_no,coalesce(nullif(btrim(rm.display_name),''),'Pemain') AS display_name,
      row_number() OVER (ORDER BY random(),rm.seat_no)::integer AS order_no
    FROM public.room_members rm
    WHERE rm.room_id=p_room_id
  ) q;

  -- Digital adaptation: 40 stock cards + 20 Mutual Fund cards = 60 cards total.
  SELECT jsonb_agg(card ORDER BY random()) INTO v_action_deck
  FROM (
    SELECT jsonb_build_object(
      'id','action-'||s.id||'-'||a.id||'-'||copy_no,
      'type','action','title',a.title,'body',a.body,'sector',s.id,
      'sector_name',s.name,'action',a.id,'copy',copy_no,'accent',s.color
    ) AS card
    FROM (VALUES
      ('finance','Keuangan','#E18B32'),('consumer','Konsumer','#2E83B9'),
      ('agriculture','Agrikultur','#5B9B68'),('mining','Tambang','#C95D57')
    ) AS s(id,name,color)
    CROSS JOIN (VALUES
      ('info-bursa','Info Bursa','Intip kartu ekonomi teratas dari tiga sektor saham, lalu ambil 2 koin dari Bank.'),
      ('rumor','Rumor','Naikkan atau turunkan dua sektor masing-masing 1 poin, atau satu sektor 2 poin. Efek tidak memicu Crash atau Split.'),
      ('quickbuy','Quickbuy','Ambil dua kartu aksi lain yang tersedia dan simpan sebagai saham sesuai sektor pada kartu.'),
      ('trading-fee','Trading Fee','Bayar 1 koin untuk setiap saham pada sektor kartu yang kamu miliki, lalu jual satu jenis saham sektor.'),
      ('acquisition','Akuisisi','Ambil 1 saham sektor pada kartu dari pemain lain. Sahammu di sektor itu minimal sama dengan milik target.')
    ) AS a(id,title,body)
    CROSS JOIN generate_series(1,2) AS copy_no
    UNION ALL
    SELECT jsonb_build_object(
      'id','action-mutual-fund-'||a.id||'-'||copy_no,
      'type','action','title',a.title,'body',a.body,'sector','mutual_fund',
      'sector_name','Reksa Dana','action',a.id,'copy',copy_no,'accent','#278C86'
    ) AS card
    FROM (VALUES
      ('rumor','Rumor','Naikkan atau turunkan dua sektor masing-masing 1 poin, atau satu sektor 2 poin.'),
      ('quickbuy','Quickbuy','Ambil dua kartu aksi lain yang tersedia dan simpan sebagai saham sesuai sektor pada kartu.'),
      ('trading-fee','Trading Fee','Bayar 1 koin per unit Reksa Dana yang kamu miliki, lalu jual satu jenis saham sektor.'),
      ('acquisition','Akuisisi','Pilih satu sektor saham selain Reksa Dana untuk mengambil satu saham dari pemain lain.')
    ) AS a(id,title,body)
    CROSS JOIN generate_series(1,5) AS copy_no
  ) deck;

  -- Twenty-four regular cards plus six special cards form the 30-card economy pool.
  -- Six cards are left unused; four stacks of six are dealt for each game.
  SELECT jsonb_agg(card ORDER BY random()) INTO v_standard_economy
  FROM (
    SELECT jsonb_build_object(
      'id','movement-'||s.id||'-'||e.id,
      'name',e.name,'body',e.body,'effect','movement',
      'sector','STACK','delta',e.delta,'special',false,'color',s.color
    ) AS card
    FROM (VALUES
      ('finance','#E18B32'),('consumer','#2E83B9'),
      ('agriculture','#5B9B68'),('mining','#C95D57')
    ) AS s(id,color)
    CROSS JOIN (VALUES
      ('up1','Naik','Harga sektor ini naik 1 poin.',1),
      ('up2','Melaju','Harga sektor ini naik 2 poin.',2),
      ('up3','Boom','Harga sektor ini naik 3 poin.',3),
      ('down1','Anjlok','Harga sektor ini turun 1 poin.',-1),
      ('down2','Terjun','Harga sektor ini turun 2 poin.',-2),
      ('down3','Crash','Harga sektor ini turun 3 poin.',-3)
    ) AS e(id,name,body,delta)
  ) movement_cards;

  SELECT jsonb_agg(card ORDER BY random()) INTO v_special_economy
  FROM (
    SELECT jsonb_build_object(
      'id',e.id,'name',e.name,'body',e.body,'effect',e.effect,
      'sector',e.sector,'delta',e.delta,'special',true,'color','#7855A4'
    ) AS card
    FROM (VALUES
      ('special-issue','Penerbitan Saham Baru','Harga sektor ini turun 1 poin. Setiap pemilik saham mendapat 1 saham tambahan jika token split tersedia.','issue','STACK',-1),
      ('special-tax-amnesty','Tax Amnesty','Sektor ini naik 1 poin. Kenaikan dari kartu sektor lain mendapat tambahan 1 poin.','tax_amnesty','STACK',1),
      ('special-buyback','Buyback','Sektor ini naik 1 poin. Bank membeli semua saham sektor ini pada harga berjalan, lalu harga kembali ke 5.','buyback','STACK',1),
      ('special-extra-fee','Extra Fee','Semua pemain membayar 1 koin per saham sektor ini.','extra_fee','STACK',0),
      ('special-merger','Merger','Sektor ini mengikuti perubahan kartu ekonomi di tumpukan sebelah kanan; jika paling kanan, ikuti sebelah kiri.','merger','STACK',0),
      ('special-recession','Resesi','Sebelum kartu lain diproses, semua sektor di atas 5 turun 1 poin.','recession','ALL',-1),
      ('special-restructure','Restrukturisasi Ekonomi','Semua harga kembali ke 5 dan efek tiga kartu ekonomi lain dibatalkan.','restructure','ALL',0),
      ('special-stimulus','Stimulus Ekonomi','Setelah kartu lain diproses, semua sektor di bawah 5 naik 1 poin.','stimulus','ALL',1),
      ('special-road-tax','Pajak Jalan','Semua pemain membayar koin sesuai nomor urutan bermain.','road_tax','ALL',0),
      ('special-world-oil','World Oil Regulation','Harga Tambang naik 1 poin dan posisi kartu ditukar dengan kartu teratas tumpukan Tambang.','world_oil','mining',1),
      ('special-dividend','Dividen','Semua pemain menerima 1 koin per saham sektor ini.','dividend','STACK',0),
      ('special-sideways','Sideways','Harga sektor ini tidak berubah.','sideways','STACK',0)
    ) AS e(id,name,body,effect,sector,delta)
    ORDER BY random()
    LIMIT 6
  ) chosen_specials;

  SELECT jsonb_agg(card ORDER BY random()) INTO v_economy_deck
  FROM (
    SELECT value AS card FROM jsonb_array_elements(v_standard_economy)
    UNION ALL
    SELECT value AS card FROM jsonb_array_elements(v_special_economy)
  ) combined;

  FOREACH v_sector IN ARRAY ARRAY['finance','consumer','agriculture','mining']
  LOOP
    SELECT coalesce(jsonb_agg(
      CASE WHEN x.card->>'sector'='STACK'
        THEN jsonb_set(jsonb_set(x.card,'{sector}',to_jsonb(v_sector),true),
                       '{stack_sector}',to_jsonb(v_sector),true)
        ELSE jsonb_set(x.card,'{stack_sector}',to_jsonb(v_sector),true)
      END ORDER BY x.ord
    ),'[]'::jsonb)
    INTO v_stack
    FROM jsonb_array_elements(v_economy_deck) WITH ORDINALITY AS x(card,ord)
    WHERE x.ord > CASE v_sector
      WHEN 'finance' THEN 0 WHEN 'consumer' THEN 6
      WHEN 'agriculture' THEN 12 ELSE 18 END
    AND x.ord <= CASE v_sector
      WHEN 'finance' THEN 6 WHEN 'consumer' THEN 12
      WHEN 'agriculture' THEN 18 ELSE 24 END;
    v_economy_stacks := jsonb_set(v_economy_stacks,ARRAY[v_sector],v_stack,true);
  END LOOP;

  SELECT jsonb_agg(to_jsonb(p.sector) ORDER BY p.rnd)
  INTO v_mutual_fund_pair
  FROM (
    SELECT sector, random() AS rnd
    FROM unnest(ARRAY['finance','consumer','agriculture','mining']::text[]) AS x(sector)
    ORDER BY rnd
    LIMIT 2
  ) p;

  SELECT jsonb_agg(jsonb_build_object('id','order-card-'||gen_random_uuid()::text,'number',n::integer,'picked_by',NULL) ORDER BY random())
  INTO v_order_cards FROM generate_series(1,v_player_count) AS n;

  v_state := jsonb_build_object(
    'schema_version',3,'round',1,'phase','bidding','phase_status','awaiting_order_picks',
    'order_cards',v_order_cards,
    'players',v_players,
    'market',jsonb_build_object('finance',5,'consumer',5,'agriculture',5,'mining',5),
    'action_market','[]'::jsonb,'draft_turn_index',0,'sell_turn_index',0,
    'sell_order','[]'::jsonb,'info_bursa_last_users','[]'::jsonb,
    'last_economy','[]'::jsonb,'last_economy_effects','[]'::jsonb,
    'bidding_results','[]'::jsonb,'split_tokens_remaining',10,
    'mutual_fund_pair',v_mutual_fund_pair,
    'history',jsonb_build_array(jsonb_build_object('type','game_started','round',1,'at',now()))
  );

  INSERT INTO public.games(room_id,current_round,phase,active_user_id,state,version)
  VALUES(p_room_id,1,'bidding',NULL,v_state,1) RETURNING id INTO v_game_id;
  INSERT INTO private.game_engine_secrets(game_id,action_deck,economy_stacks,debt_cards_remaining)
  VALUES(v_game_id,v_action_deck,v_economy_stacks,5);
  INSERT INTO public.game_private_states(game_id,user_id,private_state)
  SELECT v_game_id,rm.user_id,jsonb_build_object('coins',15,'debt',0,'peek','[]'::jsonb)
  FROM public.room_members rm WHERE rm.room_id=p_room_id;
  UPDATE public.rooms SET status='in_progress',updated_at=now() WHERE id=p_room_id;
  INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
  VALUES(v_game_id,v_user_id,'game_started',jsonb_build_object('room_id',p_room_id,'player_count',v_player_count));

  RETURN jsonb_build_object(
    'game_id',v_game_id,'room_id',p_room_id,'phase','bidding','round',1,
    'player_count',v_player_count,'action_cards_per_round',v_player_count*2,
    'action_deck_count',jsonb_array_length(v_action_deck),'economy_cards_in_play',24
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION private.get_game_view_impl(p_room_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid(); v_game public.games%rowtype; v_private jsonb;
  v_bid integer; v_bid_count integer; v_player_count integer; v_submitted boolean;
  v_view_state jsonb; v_view_players jsonb; v_view_cards jsonb;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING errcode='28000'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.room_members WHERE room_id=p_room_id AND user_id=v_user_id) THEN
    RAISE EXCEPTION 'Not a room member' USING errcode='42501';
  END IF;
  SELECT * INTO v_game FROM public.games WHERE room_id=p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Game not found' USING errcode='P0002'; END IF;
  SELECT private_state INTO v_private FROM public.game_private_states
  WHERE game_id=v_game.id AND user_id=v_user_id;
  SELECT count(*)::integer INTO v_player_count FROM public.room_members WHERE room_id=p_room_id;
  SELECT count(*)::integer INTO v_bid_count FROM public.bidding_submissions
    WHERE game_id=v_game.id AND round_number=v_game.current_round;
  SELECT bid_amount INTO v_bid FROM public.bidding_submissions
    WHERE game_id=v_game.id AND round_number=v_game.current_round AND user_id=v_user_id;
  v_submitted:=FOUND;
  v_view_state:=v_game.state;
  IF v_game.state->>'phase_status'='awaiting_order_picks' THEN
    SELECT coalesce(jsonb_agg(CASE WHEN x.card->>'picked_by' IS NULL
      THEN jsonb_build_object('id',x.card->>'id','picked_by',NULL)
      ELSE x.card END ORDER BY x.ord),'[]'::jsonb)
    INTO v_view_cards FROM jsonb_array_elements(v_game.state->'order_cards') WITH ORDINALITY AS x(card,ord);
    v_view_state:=jsonb_set(v_view_state,'{order_cards}',v_view_cards,true);
    SELECT coalesce(jsonb_agg(CASE WHEN coalesce(p.value->>'order_card_id','')<>'' THEN p.value
      ELSE jsonb_set(jsonb_set(p.value,'{order_no}','null'::jsonb,true),'{order_card_number}','null'::jsonb,true) END ORDER BY p.ord),'[]'::jsonb)
    INTO v_view_players FROM jsonb_array_elements(v_game.state->'players') WITH ORDINALITY AS p(value,ord);
    v_view_state:=jsonb_set(v_view_state,'{players}',v_view_players,true);
  END IF;
  RETURN jsonb_build_object(
    'game_id',v_game.id,'room_id',v_game.room_id,
    'current_round',v_game.current_round,'phase',v_game.phase,
    'active_user_id',v_game.active_user_id,'version',v_game.version,
    'phase_deadline',v_game.phase_deadline,
    'state',v_view_state,'my_private_state',coalesce(v_private,'{}'::jsonb),
    'bidding',jsonb_build_object(
      'submitted',v_submitted,'my_bid',CASE WHEN v_submitted THEN v_bid ELSE NULL END,
      'submitted_count',v_bid_count,'player_count',v_player_count
    ),
    'events',coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id',e.id,
        'event_type',e.event_type,
        'actor_id',e.actor_id,
        'actor_name',coalesce(
          (SELECT p.value->>'display_name'
           FROM jsonb_array_elements(coalesce(v_game.state->'players','[]'::jsonb)) AS p(value)
           WHERE p.value->>'user_id'=e.actor_id::text),
          'Bank'
        ),
        'payload',e.payload,
        'created_at',e.created_at
      ) ORDER BY e.created_at DESC,e.id DESC)
      FROM (
        SELECT * FROM public.game_events
        WHERE game_id=v_game.id
        ORDER BY created_at DESC,id DESC
        LIMIT 30
      ) e
    ),'[]'::jsonb)
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION private.list_open_rooms_impl()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_user_id uuid:=auth.uid(); v_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING errcode='28000'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',q.id,'invite_code',q.invite_code,'host_name',q.host_name,
    'member_count',q.member_count,'max_players',q.max_players,'has_password',q.has_password,'created_at',q.created_at)
    ORDER BY q.created_at DESC),'[]'::jsonb) INTO v_result
  FROM (
    SELECT r.id,r.invite_code,coalesce(host.display_name,'Pemain') AS host_name,count(member.id)::integer AS member_count,
      r.max_players,r.created_at,EXISTS(SELECT 1 FROM private.room_credentials rc WHERE rc.room_id=r.id) AS has_password
    FROM public.rooms r
    LEFT JOIN public.room_members host ON host.room_id=r.id AND host.user_id=r.host_id
    LEFT JOIN public.room_members member ON member.room_id=r.id
    WHERE r.status='waiting'
    GROUP BY r.id,host.display_name
    ORDER BY r.created_at DESC LIMIT 50
  ) q;
  RETURN v_result;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_room_lobby(p_room_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE v_user_id uuid:=auth.uid(); v_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING errcode='28000'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.room_members WHERE room_id=p_room_id AND user_id=v_user_id) THEN RAISE EXCEPTION 'Not a room member' USING errcode='42501'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('user_id',rm.user_id,'display_name',coalesce(rm.display_name,'Pemain'),
    'avatar_url',NULL,'seat_no',rm.seat_no,'is_ready',rm.is_ready) ORDER BY rm.seat_no),'[]'::jsonb)
  INTO v_result FROM public.room_members rm WHERE rm.room_id=p_room_id;
  RETURN v_result;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.join_room_by_code_v2_impl(p_code text, p_password text, p_display_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_user_id uuid:=auth.uid(); v_room public.rooms%rowtype; v_existing public.room_members%rowtype;
  v_password_hash text; v_seat integer; v_count integer; v_supplied_hash text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING errcode='28000'; END IF;
  IF p_code IS NULL OR p_code !~ '^[A-Za-z0-9]{6}$' THEN RAISE EXCEPTION 'Kode room tidak valid.' USING errcode='22023'; END IF;
  IF p_display_name IS NULL OR char_length(btrim(p_display_name)) NOT BETWEEN 2 AND 24 THEN RAISE EXCEPTION 'Username harus terdiri dari 2 sampai 24 karakter.' USING errcode='22023'; END IF;
  SELECT * INTO v_room FROM public.rooms r WHERE r.invite_code=upper(p_code) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Room tidak ditemukan.' USING errcode='P0002'; END IF;
  SELECT rc.password_hash INTO v_password_hash FROM private.room_credentials rc WHERE rc.room_id=v_room.id;
  IF v_password_hash IS NOT NULL THEN
    IF p_password IS NULL THEN RAISE EXCEPTION 'Room ini membutuhkan password.' USING errcode='28P01'; END IF;
    IF left(v_password_hash,7)='sha256'||chr(36) THEN
      v_supplied_hash:='sha256'||chr(36)||encode(extensions.digest(convert_to(p_password,'UTF8'),'sha256'),'hex');
      IF v_supplied_hash IS DISTINCT FROM v_password_hash THEN RAISE EXCEPTION 'Password room salah.' USING errcode='28P01'; END IF;
    ELSIF extensions.crypt(p_password,v_password_hash) IS DISTINCT FROM v_password_hash THEN
      RAISE EXCEPTION 'Password room salah.' USING errcode='28P01';
    END IF;
  END IF;
  IF v_room.status<>'waiting' THEN RAISE EXCEPTION 'Room sudah tidak menerima pemain.' USING errcode='55000'; END IF;
  SELECT * INTO v_existing FROM public.room_members rm WHERE rm.room_id=v_room.id AND rm.user_id=v_user_id;
  IF FOUND THEN
    UPDATE public.room_members SET display_name=btrim(p_display_name) WHERE room_id=v_room.id AND user_id=v_user_id;
    SELECT count(*)::integer INTO v_count FROM public.room_members rm WHERE rm.room_id=v_room.id;
    RETURN jsonb_build_object('room_id',v_room.id,'seat_no',v_existing.seat_no,'member_count',v_count);
  END IF;
  SELECT count(*)::integer INTO v_count FROM public.room_members rm WHERE rm.room_id=v_room.id;
  IF v_count>=v_room.max_players THEN RAISE EXCEPTION 'Room sudah penuh.' USING errcode='54000'; END IF;
  SELECT seats.seat_no INTO v_seat FROM generate_series(1,v_room.max_players) AS seats(seat_no)
  WHERE NOT EXISTS(SELECT 1 FROM public.room_members rm WHERE rm.room_id=v_room.id AND rm.seat_no=seats.seat_no)
  ORDER BY seats.seat_no LIMIT 1;
  IF v_seat IS NULL THEN RAISE EXCEPTION 'Tidak ada kursi tersedia.' USING errcode='54000'; END IF;
  INSERT INTO public.room_members(room_id,user_id,seat_no,display_name) VALUES(v_room.id,v_user_id,v_seat,btrim(p_display_name));
  UPDATE public.rooms SET last_activity_at=now(),updated_at=now() WHERE id=v_room.id;
  RETURN jsonb_build_object('room_id',v_room.id,'seat_no',v_seat,'member_count',v_count+1);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.join_room_by_code_v2(p_code text, p_password text, p_display_name text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ SELECT private.join_room_by_code_v2_impl(p_code,p_password,p_display_name); $function$
;

CREATE OR REPLACE FUNCTION private.respond_debt_offer_impl(p_room_id uuid, p_accept boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid(); v_game public.games%rowtype; v_private jsonb; v_secret private.game_engine_secrets%rowtype;
  v_state jsonb; v_offers jsonb; v_status text; v_coins integer; v_pending integer; v_room public.rooms%rowtype;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING errcode='28000'; END IF;
  IF p_accept IS NULL THEN RAISE EXCEPTION 'Pilih terima atau tolak.' USING errcode='22023'; END IF;
  SELECT * INTO v_game FROM public.games WHERE room_id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Game not found' USING errcode='P0002'; END IF;
  IF v_game.phase<>'bidding' OR v_game.state->>'phase_status'<>'awaiting_debt_decisions' THEN RAISE EXCEPTION 'Penawaran utang sedang tidak dibuka.' USING errcode='55000'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.room_members WHERE room_id=p_room_id AND user_id=v_user_id) THEN RAISE EXCEPTION 'Not a room member' USING errcode='42501'; END IF;
  SELECT x.offer->>'status' INTO v_status FROM jsonb_array_elements(coalesce(v_game.state->'debt_offers','[]'::jsonb)) AS x(offer)
  WHERE x.offer->>'user_id'=v_user_id::text;
  IF v_status IS DISTINCT FROM 'pending' THEN RAISE EXCEPTION 'Penawaran utang ini sudah dijawab atau tidak tersedia.' USING errcode='55000'; END IF;
  v_state:=v_game.state;
  IF p_accept THEN
    SELECT private_state INTO v_private FROM public.game_private_states WHERE game_id=v_game.id AND user_id=v_user_id FOR UPDATE;
    IF v_private IS NULL THEN RAISE EXCEPTION 'Player wallet not found' USING errcode='P0002'; END IF;
    IF coalesce((v_private->>'debt')::integer,0)>0 THEN RAISE EXCEPTION 'Kamu sudah memiliki kartu utang.' USING errcode='55000'; END IF;
    SELECT * INTO v_secret FROM private.game_engine_secrets WHERE game_id=v_game.id FOR UPDATE;
    IF NOT FOUND OR v_secret.debt_cards_remaining<=0 THEN RAISE EXCEPTION 'Kartu utang Bank sudah habis.' USING errcode='55000'; END IF;
    v_coins:=coalesce((v_private->>'coins')::integer,0);
    v_private:=jsonb_set(v_private,'{coins}',to_jsonb(v_coins+10),true);
    v_private:=jsonb_set(v_private,'{debt}',to_jsonb(coalesce((v_private->>'debt')::integer,0)+1),true);
    UPDATE public.game_private_states SET private_state=v_private,updated_at=now() WHERE game_id=v_game.id AND user_id=v_user_id;
    UPDATE private.game_engine_secrets SET debt_cards_remaining=debt_cards_remaining-1,updated_at=now() WHERE game_id=v_game.id;
  END IF;
  SELECT coalesce(jsonb_agg(CASE WHEN x.offer->>'user_id'=v_user_id::text
    THEN jsonb_set(x.offer,'{status}',to_jsonb(CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END),true)
    ELSE x.offer END ORDER BY x.ord),'[]'::jsonb)
  INTO v_offers FROM jsonb_array_elements(coalesce(v_state->'debt_offers','[]'::jsonb)) WITH ORDINALITY AS x(offer,ord);
  v_state:=jsonb_set(v_state,'{debt_offers}',v_offers,true);
  SELECT count(*)::integer INTO v_pending FROM jsonb_array_elements(v_offers) AS x(offer) WHERE x.offer->>'status'='pending';
  IF v_pending=0 THEN
    SELECT * INTO v_room FROM public.rooms WHERE id=p_room_id;
    v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('awaiting_bids'::text),true);
    UPDATE public.games SET state=v_state,phase_deadline=now()+make_interval(secs=>coalesce(v_room.bidding_seconds,90)),
      version=version+1,updated_at=now() WHERE id=v_game.id;
  ELSE
    UPDATE public.games SET state=v_state,version=version+1,updated_at=now() WHERE id=v_game.id;
  END IF;
  INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
  VALUES(v_game.id,v_user_id,'debt_offer_decided',jsonb_build_object('accepted',p_accept,
    'coins_borrowed',CASE WHEN p_accept THEN 10 ELSE 0 END,'final_penalty',CASE WHEN p_accept THEN 13 ELSE 0 END));
  RETURN jsonb_build_object('ok',true,'accepted',p_accept,'coins_borrowed',CASE WHEN p_accept THEN 10 ELSE 0 END,
    'pending_count',v_pending,'phase_status',CASE WHEN v_pending=0 THEN 'awaiting_bids' ELSE 'awaiting_debt_decisions' END);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.respond_debt_offer(p_room_id uuid, p_accept boolean)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ SELECT private.respond_debt_offer_impl(p_room_id,p_accept); $function$
;

CREATE OR REPLACE FUNCTION private.resolve_economy_v4_impl(p_room_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid();
  v_game public.games%rowtype;
  v_room public.rooms%rowtype;
  v_secret private.game_engine_secrets%rowtype;
  v_state jsonb;
  v_players jsonb;
  v_market jsonb;
  v_stacks jsonb;
  v_revealed jsonb:='[]'::jsonb;
  v_last_economy jsonb:='[]'::jsonb;
  v_effects jsonb:='[]'::jsonb;
  v_card_effects jsonb;
  v_card jsonb;
  v_card_item jsonb;
  v_card_stack text;
  v_effect text;
  v_stack jsonb;
  v_stack_sector text;
  v_target_sector text;
  v_adjacent_sector text;
  v_adjacent_card jsonb;
  v_price_result jsonb;
  v_delta integer;
  v_split_remaining integer;
  v_tax_bonus integer:=0;
  v_has_restructure boolean:=false;
  v_world_oil_card jsonb;
  v_mining_stack jsonb;
  v_origin_stack jsonb;
  v_player jsonb;
  v_player_id uuid;
  v_private jsonb;
  v_coins integer;
  v_owned integer;
  v_tokens jsonb;
  v_token_count integer;
  v_order integer;
  v_done boolean;
  v_next_round integer;
  v_pair jsonb;
  v_mf_price integer;
  v_shares jsonb;
  v_stock_value integer;
  v_mf_value integer;
  v_penalty integer;
  v_score integer;
  v_scores jsonb:='[]'::jsonb;
  v_winner uuid;
  v_best_score integer:=-2147483648;
  v_final_order integer:=999;
  v_debt_offers jsonb:='[]'::jsonb;
  v_pending_debt_count integer:=0;
BEGIN
  IF v_user_id IS NULL AND current_setting('stocklab.internal_scheduler',true) IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Authentication required' USING errcode='28000';
  END IF;

  SELECT * INTO v_game
  FROM public.games
  WHERE room_id=p_room_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game not found' USING errcode='P0002';
  END IF;
  IF v_game.phase<>'economy' OR v_game.state->>'phase_status'<>'awaiting_economy' THEN
    RAISE EXCEPTION 'Economy phase is not ready' USING errcode='55000';
  END IF;
  SELECT * INTO v_room FROM public.rooms WHERE id=p_room_id;
  IF NOT FOUND OR (
    current_setting('stocklab.internal_scheduler',true) IS DISTINCT FROM 'true'
    AND v_room.host_id<>v_user_id
    AND (v_game.phase_deadline IS NULL OR v_game.phase_deadline>now())
  ) THEN
    RAISE EXCEPTION 'Only host can reveal economy cards before the phase timer expires' USING errcode='42501';
  END IF;

  SELECT * INTO v_secret
  FROM private.game_engine_secrets
  WHERE game_id=v_game.id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game deck is missing' USING errcode='P0002';
  END IF;

  v_state:=v_game.state;
  v_players:=v_state->'players';
  v_market:=v_state->'market';
  v_stacks:=v_secret.economy_stacks;
  v_split_remaining:=coalesce((v_state->>'split_tokens_remaining')::integer,10);

  -- Reveal exactly one card from each sector stack.
  FOREACH v_stack_sector IN ARRAY ARRAY['finance','consumer','agriculture','mining']
  LOOP
    v_stack:=coalesce(v_stacks->v_stack_sector,'[]'::jsonb);
    v_card:=v_stack->0;
    IF v_card IS NULL THEN
      RAISE EXCEPTION 'Economy stack % is empty unexpectedly',v_stack_sector USING errcode='55000';
    END IF;
    v_stacks:=jsonb_set(v_stacks,ARRAY[v_stack_sector],v_stack#-'{0}',true);
    v_card:=jsonb_set(v_card,'{stack_sector}',to_jsonb(v_stack_sector),true);
    v_revealed:=v_revealed||jsonb_build_array(v_card);
  END LOOP;

  SELECT count(*)::integer INTO v_tax_bonus
  FROM jsonb_array_elements(v_revealed) AS x(value)
  WHERE value->>'effect'='tax_amnesty';
  SELECT coalesce(bool_or(value->>'effect'='restructure'),false)
  INTO v_has_restructure
  FROM jsonb_array_elements(v_revealed) AS x(value);

  IF v_has_restructure THEN
    -- Restructure cancels all other effects in this economy reveal.
    v_market:=jsonb_build_object('finance',5,'consumer',5,'agriculture',5,'mining',5);
    v_effects:=jsonb_build_array(jsonb_build_object(
      'effect','restructure','message','Semua harga direset ke 5; efek ekonomi lain dibatalkan.'
    ));
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'stack_sector',value->>'stack_sector',
      'card',value,
      'effects',CASE WHEN value->>'effect'='restructure'
        THEN jsonb_build_array(jsonb_build_object(
          'message','Restrukturisasi: semua harga kembali ke 5 dan efek kartu ekonomi lain dibatalkan.'
        ))
        ELSE '[]'::jsonb END
    ) ORDER BY ord),'[]'::jsonb)
    INTO v_last_economy
    FROM jsonb_array_elements(v_revealed) WITH ORDINALITY AS x(value,ord);
  ELSE
    -- Recession is always resolved before the four cards.
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_revealed) AS x(value)
      WHERE value->>'effect'='recession'
    ) THEN
      FOREACH v_target_sector IN ARRAY ARRAY['finance','consumer','agriculture','mining']
      LOOP
        IF (v_market->>v_target_sector)::integer>5 THEN
          v_price_result:=private.apply_price_delta(
            v_players,v_market,v_target_sector,-1,true,v_split_remaining
          );
          v_players:=v_price_result->'players';
          v_market:=v_price_result->'market';
          v_split_remaining:=(v_price_result->>'split_tokens_remaining')::integer;
          v_effects:=v_effects||jsonb_build_array(jsonb_build_object(
            'effect','recession','sector',v_target_sector,
            'old_price',(v_price_result->>'old_price')::integer,
            'new_price',(v_price_result->>'new_price')::integer,
            'outcome',v_price_result->>'outcome'
          ));
        END IF;
      END LOOP;
    END IF;

    FOR v_card_item IN
      SELECT value FROM jsonb_array_elements(v_revealed)
      ORDER BY CASE value->>'stack_sector'
        WHEN 'finance' THEN 1 WHEN 'consumer' THEN 2
        WHEN 'agriculture' THEN 3 ELSE 4 END
    LOOP
      v_card:=v_card_item;
      v_card_stack:=v_card->>'stack_sector';
      v_effect:=v_card->>'effect';
      v_target_sector:=v_card->>'sector';
      v_delta:=coalesce((v_card->>'delta')::integer,0);
      v_card_effects:='[]'::jsonb;

      IF v_effect='movement' THEN
        IF v_delta>0 AND v_tax_bonus>0 THEN v_delta:=v_delta+v_tax_bonus; END IF;
        v_price_result:=private.apply_price_delta(
          v_players,v_market,v_card_stack,v_delta,true,v_split_remaining
        );
        v_players:=v_price_result->'players';
        v_market:=v_price_result->'market';
        v_split_remaining:=(v_price_result->>'split_tokens_remaining')::integer;
        v_card_effects:=v_card_effects||jsonb_build_array(jsonb_build_object(
          'sector',v_card_stack,
          'old_price',(v_price_result->>'old_price')::integer,
          'new_price',(v_price_result->>'new_price')::integer,
          'outcome',v_price_result->>'outcome'
        ));

      ELSIF v_effect='issue' THEN
        v_price_result:=private.apply_price_delta(
          v_players,v_market,v_card_stack,-1,true,v_split_remaining
        );
        v_players:=v_price_result->'players';
        v_market:=v_price_result->'market';
        v_split_remaining:=(v_price_result->>'split_tokens_remaining')::integer;

        IF v_price_result->>'outcome'='normal' THEN
          FOR v_player IN
            SELECT value
            FROM jsonb_array_elements(v_players) AS p(value)
            ORDER BY (value->>'order_no')::integer
          LOOP
            v_owned:=coalesce((v_player->'shares'->>v_card_stack)::integer,0);
            IF v_owned>0 AND v_split_remaining>0 THEN
              v_token_count:=coalesce((v_player->'split_tokens'->>v_card_stack)::integer,0);
              v_players:=(
                SELECT jsonb_agg(
                  CASE WHEN value->>'user_id'=v_player->>'user_id'
                    THEN jsonb_set(
                      jsonb_set(value,ARRAY['shares',v_card_stack],to_jsonb(v_owned+1),true),
                      ARRAY['split_tokens',v_card_stack],to_jsonb(v_token_count+1),true
                    )
                    ELSE value
                  END ORDER BY ord
                )
                FROM jsonb_array_elements(v_players) WITH ORDINALITY AS x(value,ord)
              );
              v_split_remaining:=v_split_remaining-1;
            END IF;
          END LOOP;
        END IF;
        v_card_effects:=v_card_effects||jsonb_build_array(jsonb_build_object(
          'sector',v_card_stack,
          'old_price',(v_price_result->>'old_price')::integer,
          'new_price',(v_price_result->>'new_price')::integer,
          'outcome',v_price_result->>'outcome',
          'message','Penerbitan saham baru: pemilik mendapat tambahan saham bila token tersedia.'
        ));

      ELSIF v_effect='tax_amnesty' THEN
        v_price_result:=private.apply_price_delta(
          v_players,v_market,v_card_stack,1,true,v_split_remaining
        );
        v_players:=v_price_result->'players';
        v_market:=v_price_result->'market';
        v_split_remaining:=(v_price_result->>'split_tokens_remaining')::integer;
        v_card_effects:=v_card_effects||jsonb_build_array(jsonb_build_object(
          'sector',v_card_stack,
          'old_price',(v_price_result->>'old_price')::integer,
          'new_price',(v_price_result->>'new_price')::integer,
          'outcome',v_price_result->>'outcome',
          'message','Tax Amnesty menambah dampak kenaikan harga.'
        ));

      ELSIF v_effect='buyback' THEN
        v_delta:=1+v_tax_bonus;
        v_price_result:=private.apply_price_delta(
          v_players,v_market,v_card_stack,v_delta,true,v_split_remaining
        );
        v_players:=v_price_result->'players';
        v_market:=v_price_result->'market';
        v_split_remaining:=(v_price_result->>'split_tokens_remaining')::integer;
        v_owned:= (v_market->>v_card_stack)::integer;

        FOR v_player IN SELECT value FROM jsonb_array_elements(v_players)
        LOOP
          v_player_id:=(v_player->>'user_id')::uuid;
          v_shares:=coalesce(v_player->'shares','{}'::jsonb);
          v_tokens:=coalesce(v_player->'split_tokens','{}'::jsonb);
          v_owned:=coalesce((v_shares->>v_card_stack)::integer,0);
          v_token_count:=coalesce((v_tokens->>v_card_stack)::integer,0);
          IF v_owned>0 OR v_token_count>0 THEN
            SELECT private_state INTO v_private
            FROM public.game_private_states
            WHERE game_id=v_game.id AND user_id=v_player_id
            FOR UPDATE;
            v_coins:=coalesce((v_private->>'coins')::integer,0);
            v_private:=jsonb_set(v_private,'{coins}',
              to_jsonb(v_coins+v_owned*(v_market->>v_card_stack)::integer),true);
            UPDATE public.game_private_states
            SET private_state=v_private,updated_at=now()
            WHERE game_id=v_game.id AND user_id=v_player_id;

            v_split_remaining:=least(10,v_split_remaining+v_token_count);
            v_players:=(
              SELECT jsonb_agg(
                CASE WHEN value->>'user_id'=v_player_id::text
                  THEN jsonb_set(
                    jsonb_set(value,ARRAY['shares',v_card_stack],to_jsonb(0),true),
                    ARRAY['split_tokens',v_card_stack],to_jsonb(0),true
                  )
                  ELSE value
                END ORDER BY ord
              )
              FROM jsonb_array_elements(v_players) WITH ORDINALITY AS x(value,ord)
            );
          END IF;
        END LOOP;
        v_market:=jsonb_set(v_market,ARRAY[v_card_stack],to_jsonb(5),true);
        v_card_effects:=v_card_effects||jsonb_build_array(jsonb_build_object(
          'sector',v_card_stack,'old_price',(v_price_result->>'old_price')::integer,
          'new_price',5,'outcome',v_price_result->>'outcome',
          'message','Bank membeli semua saham sektor ini dan harga direset ke 5.'
        ));

      ELSIF v_effect='extra_fee' THEN
        FOR v_player IN SELECT value FROM jsonb_array_elements(v_players)
        LOOP
          v_player_id:=(v_player->>'user_id')::uuid;
          v_owned:=coalesce((v_player->'shares'->>v_card_stack)::integer,0);
          IF v_owned>0 THEN
            UPDATE public.game_private_states
            SET private_state=jsonb_set(
              private_state,'{coins}',
              to_jsonb(coalesce((private_state->>'coins')::integer,0)-v_owned),true
            ),
            updated_at=now()
            WHERE game_id=v_game.id AND user_id=v_player_id;
          END IF;
        END LOOP;
        v_card_effects:=v_card_effects||jsonb_build_array(jsonb_build_object(
          'sector',v_card_stack,'message','Setiap pemain membayar 1 koin per saham sektor ini.'
        ));

      ELSIF v_effect='merger' THEN
        v_adjacent_sector:=CASE v_card_stack
          WHEN 'finance' THEN 'consumer'
          WHEN 'consumer' THEN 'agriculture'
          WHEN 'agriculture' THEN 'mining'
          ELSE 'agriculture'
        END;
        SELECT value INTO v_adjacent_card
        FROM jsonb_array_elements(v_revealed) AS x(value)
        WHERE value->>'stack_sector'=v_adjacent_sector;
        v_delta:=coalesce((v_adjacent_card->>'delta')::integer,0);
        IF v_delta>0 AND v_tax_bonus>0 THEN v_delta:=v_delta+v_tax_bonus; END IF;
        IF v_delta<>0 THEN
          v_price_result:=private.apply_price_delta(
            v_players,v_market,v_card_stack,v_delta,true,v_split_remaining
          );
          v_players:=v_price_result->'players';
          v_market:=v_price_result->'market';
          v_split_remaining:=(v_price_result->>'split_tokens_remaining')::integer;
          v_card_effects:=v_card_effects||jsonb_build_array(jsonb_build_object(
            'sector',v_card_stack,
            'old_price',(v_price_result->>'old_price')::integer,
            'new_price',(v_price_result->>'new_price')::integer,
            'outcome',v_price_result->>'outcome',
            'message','Merger mengikuti pergerakan tumpukan sebelah kanan.'
          ));
        END IF;

      ELSIF v_effect='dividend' THEN
        FOR v_player IN SELECT value FROM jsonb_array_elements(v_players)
        LOOP
          v_player_id:=(v_player->>'user_id')::uuid;
          v_owned:=coalesce((v_player->'shares'->>v_card_stack)::integer,0);
          IF v_owned>0 THEN
            UPDATE public.game_private_states
            SET private_state=jsonb_set(
              private_state,'{coins}',
              to_jsonb(coalesce((private_state->>'coins')::integer,0)+v_owned),true
            ),
            updated_at=now()
            WHERE game_id=v_game.id AND user_id=v_player_id;
          END IF;
        END LOOP;
        v_card_effects:=v_card_effects||jsonb_build_array(jsonb_build_object(
          'sector',v_card_stack,'message','Setiap pemain menerima 1 koin per saham sektor ini.'
        ));

      ELSIF v_effect='road_tax' THEN
        FOR v_player IN SELECT value FROM jsonb_array_elements(v_players)
        LOOP
          v_player_id:=(v_player->>'user_id')::uuid;
          v_order:=(v_player->>'order_no')::integer;
          UPDATE public.game_private_states
          SET private_state=jsonb_set(
            private_state,'{coins}',
            to_jsonb(coalesce((private_state->>'coins')::integer,0)-v_order),true
          ),
          updated_at=now()
          WHERE game_id=v_game.id AND user_id=v_player_id;
        END LOOP;
        v_card_effects:=v_card_effects||jsonb_build_array(jsonb_build_object(
          'message','Setiap pemain membayar koin sesuai nomor urutan bermain.'
        ));

      ELSIF v_effect='world_oil' THEN
        v_price_result:=private.apply_price_delta(
          v_players,v_market,'mining',1+v_tax_bonus,true,v_split_remaining
        );
        v_players:=v_price_result->'players';
        v_market:=v_price_result->'market';
        v_split_remaining:=(v_price_result->>'split_tokens_remaining')::integer;
        IF v_card_stack<>'mining' THEN
          v_mining_stack:=coalesce(v_stacks->'mining','[]'::jsonb);
          IF jsonb_array_length(v_mining_stack)>0 THEN
            v_world_oil_card:=v_mining_stack->0;
            v_origin_stack:=coalesce(v_stacks->v_card_stack,'[]'::jsonb);
            v_origin_stack:=jsonb_build_array(v_world_oil_card)||v_origin_stack;
            v_mining_stack:=(v_mining_stack#-'{0}')||jsonb_build_array(v_card);
            v_stacks:=jsonb_set(v_stacks,ARRAY[v_card_stack],v_origin_stack,true);
            v_stacks:=jsonb_set(v_stacks,ARRAY['mining'],v_mining_stack,true);
          END IF;
        END IF;
        v_card_effects:=v_card_effects||jsonb_build_array(jsonb_build_object(
          'sector','mining',
          'old_price',(v_price_result->>'old_price')::integer,
          'new_price',(v_price_result->>'new_price')::integer,
          'outcome',v_price_result->>'outcome',
          'message','World Oil Regulation menaikkan harga Tambang dan menukar kartu teratas.'
        ));

      ELSIF v_effect='stimulus' THEN
        v_card_effects:=v_card_effects||jsonb_build_array(jsonb_build_object(
          'message','Stimulus diterapkan setelah seluruh kartu ekonomi.'
        ));

      ELSIF v_effect='recession' THEN
        v_card_effects:=v_card_effects||jsonb_build_array(jsonb_build_object(
          'message','Resesi diterapkan sebelum seluruh kartu ekonomi.'
        ));

      ELSIF v_effect='restructure' THEN
        NULL;

      ELSIF v_effect='sideways' THEN
        v_card_effects:=v_card_effects||jsonb_build_array(jsonb_build_object(
          'sector',v_card_stack,'message','Harga sektor ini tidak berubah.'
        ));

      ELSE
        RAISE EXCEPTION 'Unknown economy card effect: %',v_effect USING errcode='22023';
      END IF;

      v_last_economy:=v_last_economy||jsonb_build_array(jsonb_build_object(
        'stack_sector',v_card_stack,'card',v_card,'effects',v_card_effects
      ));
      v_effects:=v_effects||v_card_effects;
    END LOOP;

    -- Stimulus is always applied after the sector cards.
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_revealed) AS x(value)
      WHERE value->>'effect'='stimulus'
    ) THEN
      FOREACH v_target_sector IN ARRAY ARRAY['finance','consumer','agriculture','mining']
      LOOP
        IF (v_market->>v_target_sector)::integer<5 THEN
          v_price_result:=private.apply_price_delta(
            v_players,v_market,v_target_sector,1,true,v_split_remaining
          );
          v_players:=v_price_result->'players';
          v_market:=v_price_result->'market';
          v_split_remaining:=(v_price_result->>'split_tokens_remaining')::integer;
          v_effects:=v_effects||jsonb_build_array(jsonb_build_object(
            'sector',v_target_sector,
            'old_price',(v_price_result->>'old_price')::integer,
            'new_price',(v_price_result->>'new_price')::integer,
            'outcome',v_price_result->>'outcome',
            'message','Stimulus menaikkan sektor yang masih di bawah 5.'
          ));
        END IF;
      END LOOP;
    END IF;
  END IF;

  UPDATE private.game_engine_secrets
  SET economy_stacks=v_stacks,updated_at=now()
  WHERE game_id=v_game.id;

  SELECT bool_and(jsonb_array_length(v_stacks->s.sector)=0)
  INTO v_done
  FROM unnest(ARRAY['finance','consumer','agriculture','mining']) AS s(sector);

  v_state:=jsonb_set(v_state,'{players}',v_players,true);
  v_state:=jsonb_set(v_state,'{market}',v_market,true);
  v_state:=jsonb_set(v_state,'{split_tokens_remaining}',to_jsonb(v_split_remaining),true);
  v_state:=jsonb_set(v_state,'{last_economy}',v_last_economy,true);
  v_state:=jsonb_set(v_state,'{last_economy_effects}',v_effects,true);
  v_state:=jsonb_set(v_state,'{info_bursa_last_users}','[]'::jsonb,true);
  v_state:=jsonb_set(v_state,'{sell_order}','[]'::jsonb,true);
  v_state:=jsonb_set(v_state,'{history}',coalesce(v_state->'history','[]'::jsonb)||
    jsonb_build_array(jsonb_build_object(
      'type','economy_revealed','round',v_game.current_round,
      'cards',v_last_economy,'effects',v_effects,'at',now()
    )),true);

  -- A public economy reveal consumes private peeks from all players.
  UPDATE public.game_private_states
  SET private_state=jsonb_set(private_state,'{peek}','[]'::jsonb,true),
      updated_at=now()
  WHERE game_id=v_game.id;

  IF v_done THEN
    v_pair:=coalesce(v_state->'mutual_fund_pair',jsonb_build_array('consumer','agriculture'));
    v_mf_price:=floor((
      (v_market->>(v_pair->>0))::numeric+
      (v_market->>(v_pair->>1))::numeric
    )/2)::integer;

    FOR v_player IN
      SELECT value FROM jsonb_array_elements(v_players) AS p(value)
      ORDER BY (value->>'order_no')::integer
    LOOP
      SELECT private_state INTO v_private
      FROM public.game_private_states
      WHERE game_id=v_game.id AND user_id=(v_player->>'user_id')::uuid;
      v_coins:=coalesce((v_private->>'coins')::integer,0);
      v_shares:=v_player->'shares';
      v_stock_value:=
        coalesce((v_shares->>'finance')::integer,0)*(v_market->>'finance')::integer+
        coalesce((v_shares->>'consumer')::integer,0)*(v_market->>'consumer')::integer+
        coalesce((v_shares->>'agriculture')::integer,0)*(v_market->>'agriculture')::integer+
        coalesce((v_shares->>'mining')::integer,0)*(v_market->>'mining')::integer;
      v_mf_value:=coalesce((v_shares->>'mutual_fund')::integer,0)*v_mf_price;
      v_penalty:=13*coalesce((v_private->>'debt')::integer,0);
      v_score:=v_coins+v_stock_value+v_mf_value-v_penalty;
      v_order:=(v_player->>'order_no')::integer;
      v_scores:=v_scores||jsonb_build_array(jsonb_build_object(
        'user_id',v_player->>'user_id','display_name',v_player->>'display_name',
        'order_no',v_order,'coins',v_coins,'stock_value',v_stock_value,
        'mutual_fund_value',v_mf_value,'debt_penalty',v_penalty,'total_assets',v_score
      ));
      IF v_score>v_best_score OR (v_score=v_best_score AND v_order<v_final_order) THEN
        v_best_score:=v_score;
        v_final_order:=v_order;
        v_winner:=(v_player->>'user_id')::uuid;
      END IF;
    END LOOP;

    v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('finished'::text),true);
    v_state:=jsonb_set(v_state,'{final_scores}',v_scores,true);
    v_state:=jsonb_set(v_state,'{winner_user_id}',to_jsonb(v_winner),true);
    UPDATE public.games SET phase='finished',active_user_id=NULL,state=v_state,
      version=version+1,updated_at=now() WHERE id=v_game.id;
    UPDATE public.rooms SET status='finished',updated_at=now() WHERE id=p_room_id;
    INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
    VALUES(v_game.id,v_user_id,'game_finished',jsonb_build_object(
      'winner_user_id',v_winner,'scores',v_scores
    ));
    RETURN jsonb_build_object('ok',true,'finished',true,
      'winner_user_id',v_winner,'final_scores',v_scores,'effects',v_effects);
  END IF;

  v_next_round:=v_game.current_round+1;
  WITH player_debts AS (
    SELECT p.value AS player,coalesce((gps.private_state->>'debt')::integer,0) AS debt_count,
      row_number() OVER (ORDER BY (p.value->>'order_no')::integer) AS offer_rank
    FROM jsonb_array_elements(v_players) AS p(value)
    LEFT JOIN public.game_private_states gps ON gps.game_id=v_game.id AND gps.user_id=(p.value->>'user_id')::uuid
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('user_id',player->>'user_id',
    'status',CASE WHEN debt_count>0 THEN 'already_taken'
      WHEN offer_rank<=v_secret.debt_cards_remaining THEN 'pending' ELSE 'unavailable' END
  ) ORDER BY (player->>'order_no')::integer),'[]'::jsonb),
  count(*) FILTER(WHERE debt_count=0 AND offer_rank<=v_secret.debt_cards_remaining)::integer
  INTO v_debt_offers,v_pending_debt_count FROM player_debts;

  v_state:=jsonb_set(v_state,'{round}',to_jsonb(v_next_round),true);
  v_state:=jsonb_set(v_state,'{phase_status}',
    to_jsonb(CASE WHEN v_pending_debt_count>0 THEN 'awaiting_debt_decisions' ELSE 'awaiting_bids' END),true);
  v_state:=jsonb_set(v_state,'{debt_offers}',v_debt_offers,true);
  v_state:=jsonb_set(v_state,'{action_market}','[]'::jsonb,true);
  v_state:=jsonb_set(v_state,'{draft_turn_index}',to_jsonb(0),true);
  v_state:=jsonb_set(v_state,'{sell_turn_index}',to_jsonb(0),true);
  UPDATE public.games SET current_round=v_next_round,phase='bidding',active_user_id=NULL,
    state=v_state,version=version+1,updated_at=now() WHERE id=v_game.id;
  INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
  VALUES(v_game.id,v_user_id,'economy_revealed',jsonb_build_object(
    'round',v_game.current_round,'cards',v_last_economy,'effects',v_effects
  ));
  RETURN jsonb_build_object('ok',true,'finished',false,'next_round',v_next_round,
    'last_economy',v_last_economy,'effects',v_effects);
END;
$function$
;

CREATE OR REPLACE FUNCTION private.advance_expired_turn_impl(p_room_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid();
  v_game public.games%rowtype;
  v_secret private.game_engine_secrets%rowtype;
  v_state jsonb;
  v_players jsonb;
  v_results jsonb;
  v_market jsonb;
  v_remaining_deck jsonb;
  v_card jsonb;
  v_remaining_cards jsonb;
  v_player_count integer;
  v_card_count integer;
  v_next_index integer;
  v_next_user uuid;
  v_order jsonb;
  v_sell_index integer;
  v_result jsonb;
  v_attempt integer; v_violates boolean; v_same_type boolean;
BEGIN
  IF v_user_id IS NULL AND current_setting('stocklab.internal_scheduler',true) IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Authentication required' USING errcode='28000';
  END IF;
  IF v_user_id IS NOT NULL AND NOT EXISTS(
    SELECT 1 FROM public.room_members WHERE room_id=p_room_id AND user_id=v_user_id
  ) AND current_setting('stocklab.internal_scheduler',true) IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Not a room member' USING errcode='42501';
  END IF;
  SELECT * INTO v_game FROM public.games WHERE room_id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Game not found' USING errcode='P0002'; END IF;
  IF v_game.phase='finished' OR v_game.phase_deadline IS NULL OR v_game.phase_deadline>now() THEN
    RETURN jsonb_build_object('advanced',false,'phase',v_game.phase,'deadline',v_game.phase_deadline);
  END IF;

  PERFORM set_config('stocklab.auto_timeout','true',true);
  v_state:=v_game.state;
  v_players:=coalesce(v_state->'players','[]'::jsonb);
  v_player_count:=jsonb_array_length(v_players);

  IF v_game.phase='bidding' AND v_state->>'phase_status'='awaiting_debt_decisions' THEN
    v_state:=jsonb_set(v_state,'{debt_offers}',(
      SELECT coalesce(jsonb_agg(CASE WHEN x.offer->>'status'='pending'
        THEN jsonb_set(x.offer,'{status}',to_jsonb('declined'::text),true) ELSE x.offer END ORDER BY x.ord),'[]'::jsonb)
      FROM jsonb_array_elements(coalesce(v_state->'debt_offers','[]'::jsonb)) WITH ORDINALITY AS x(offer,ord)
    ),true);
    v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('awaiting_bids'::text),true);
    v_state:=jsonb_set(v_state,'{history}',coalesce(v_state->'history','[]'::jsonb)||
      jsonb_build_array(jsonb_build_object('type','debt_offer_timeout','round',v_game.current_round,'at',now())),true);
    UPDATE public.games SET state=v_state,
      phase_deadline=now()+make_interval(secs=>coalesce((SELECT bidding_seconds FROM public.rooms WHERE id=p_room_id),90)),
      version=version+1,updated_at=now() WHERE id=v_game.id;
    INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
    VALUES(v_game.id,NULL,'debt_offer_timeout',jsonb_build_object('round',v_game.current_round));
    RETURN jsonb_build_object('advanced',true,'phase','bidding','reason','debt_offer_timeout');
  END IF;

  IF v_game.phase='bidding' THEN
    INSERT INTO public.bidding_submissions(game_id,round_number,user_id,bid_amount,submitted_at)
    SELECT v_game.id,v_game.current_round,(p.value->>'user_id')::uuid,0,now()
    FROM jsonb_array_elements(v_players) AS p(value)
    WHERE NOT EXISTS(
      SELECT 1 FROM public.bidding_submissions b
      WHERE b.game_id=v_game.id AND b.round_number=v_game.current_round
        AND b.user_id=(p.value->>'user_id')::uuid
    );

    UPDATE public.game_private_states gps
    SET private_state=jsonb_set(gps.private_state,'{coins}',
      to_jsonb((gps.private_state->>'coins')::integer-b.bid_amount),true),
      updated_at=now()
    FROM public.bidding_submissions b
    WHERE b.game_id=v_game.id AND b.round_number=v_game.current_round
      AND gps.game_id=v_game.id AND gps.user_id=b.user_id;

    SELECT
      jsonb_agg(jsonb_set(p.player,'{order_no}',to_jsonb(p.new_order),true) ORDER BY p.new_order),
      jsonb_agg(jsonb_build_object(
        'user_id',p.player->>'user_id','display_name',p.player->>'display_name',
        'bid_amount',p.bid_amount,'order_no',p.new_order
      ) ORDER BY p.new_order)
    INTO v_players,v_results
    FROM (
      SELECT x.value AS player,b.bid_amount,
        row_number() OVER(ORDER BY b.bid_amount DESC,coalesce((x.value->>'order_card_number')::integer,(x.value->>'order_no')::integer) ASC)::integer AS new_order
      FROM jsonb_array_elements(v_state->'players') AS x(value)
      JOIN public.bidding_submissions b
        ON b.game_id=v_game.id AND b.round_number=v_game.current_round
       AND b.user_id=(x.value->>'user_id')::uuid
    ) p;

    SELECT value->>'user_id' INTO v_next_user
    FROM jsonb_array_elements(v_players) AS x(value)
    WHERE (value->>'order_no')::integer=1;

    SELECT * INTO v_secret FROM private.game_engine_secrets WHERE game_id=v_game.id FOR UPDATE;
    v_card_count:=v_player_count*2;
    IF jsonb_array_length(v_secret.action_deck)<v_card_count THEN
      RAISE EXCEPTION 'Action deck is exhausted' USING errcode='55000';
    END IF;
    v_attempt:=0;
    LOOP
      v_attempt:=v_attempt+1;
      SELECT coalesce(jsonb_agg(x.card ORDER BY x.ord),'[]'::jsonb) INTO v_market
      FROM jsonb_array_elements(v_secret.action_deck) WITH ORDINALITY AS x(card,ord)
      WHERE x.ord<=v_card_count;
      IF jsonb_array_length(v_market)<>v_card_count THEN
        RAISE EXCEPTION 'Action deck is exhausted' USING errcode='55000';
      END IF;
      SELECT count(*) FILTER (WHERE x.card->>'action'='quickbuy')>=3
      INTO v_violates FROM jsonb_array_elements(v_market) AS x(card);
      IF v_player_count IN (4,5) THEN
        SELECT EXISTS(
          SELECT 1 FROM jsonb_array_elements(v_market) AS x(card)
          GROUP BY x.card->>'sector',x.card->>'action'
          HAVING count(*)>=v_player_count
        ) INTO v_same_type;
        v_violates:=v_violates OR v_same_type;
      END IF;
      EXIT WHEN NOT v_violates;
      IF v_attempt>=100 THEN
        RAISE EXCEPTION 'Could not draw a valid opening action market after 100 shuffles' USING errcode='55000';
      END IF;
      SELECT coalesce(jsonb_agg(x.card ORDER BY random()),'[]'::jsonb)
      INTO v_secret.action_deck FROM jsonb_array_elements(v_secret.action_deck) AS x(card);
    END LOOP;
    SELECT coalesce(jsonb_agg(x.card ORDER BY x.ord),'[]'::jsonb) INTO v_remaining_deck
    FROM jsonb_array_elements(v_secret.action_deck) WITH ORDINALITY AS x(card,ord)
    WHERE x.ord>v_card_count;
    UPDATE private.game_engine_secrets SET action_deck=v_remaining_deck,updated_at=now()
    WHERE game_id=v_game.id;

    v_state:=jsonb_set(v_state,'{players}',v_players,true);
    v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('drafting'::text),true);
    v_state:=jsonb_set(v_state,'{action_market}',v_market,true);
    v_state:=jsonb_set(v_state,'{draft_turn_index}',to_jsonb(0),true);
    v_state:=jsonb_set(v_state,'{bidding_results}',coalesce(v_results,'[]'::jsonb),true);
    v_state:=jsonb_set(v_state,'{history}',coalesce(v_state->'history','[]'::jsonb)||
      jsonb_build_array(jsonb_build_object('type','bids_auto_resolved','round',v_game.current_round,'at',now())),true);
    UPDATE public.games SET phase='action',active_user_id=v_next_user,state=v_state,
      version=version+1,updated_at=now() WHERE id=v_game.id;
    INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
    VALUES(v_game.id,NULL,'bids_auto_resolved',jsonb_build_object('round',v_game.current_round,'results',v_results));
    RETURN jsonb_build_object('advanced',true,'phase','action','reason','bidding_timeout');

  ELSIF v_game.phase='action' THEN
    v_card:=v_state->'action_market'->0;
    IF v_card IS NULL THEN
      RAISE EXCEPTION 'No action card is available to auto-pick' USING errcode='55000';
    END IF;
    v_players:=private.change_player_share(v_players,v_game.active_user_id,v_card->>'sector',1);
    v_remaining_cards:=v_state->'action_market' #- '{0}';
    v_state:=jsonb_set(v_state,'{players}',v_players,true);
    v_state:=jsonb_set(v_state,'{action_market}',v_remaining_cards,true);
    v_state:=jsonb_set(v_state,'{history}',coalesce(v_state->'history','[]'::jsonb)||
      jsonb_build_array(jsonb_build_object(
        'type','action_auto_kept','user_id',v_game.active_user_id,'card_title',v_card->>'title','at',now()
      )),true);

    IF jsonb_array_length(v_remaining_cards)=0 THEN
      SELECT value->>'user_id' INTO v_next_user
      FROM jsonb_array_elements(v_players) AS x(value)
      WHERE (value->>'order_no')::integer=1;
      v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('selling'::text),true);
      v_state:=jsonb_set(v_state,'{sell_turn_index}',to_jsonb(0),true);
      UPDATE public.games SET phase='sell',active_user_id=v_next_user,state=v_state,
        version=version+1,updated_at=now() WHERE id=v_game.id;
      INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
      VALUES(v_game.id,NULL,'action_timeout',jsonb_build_object('auto_kept_card',v_card->>'title','phase','sell'));
      RETURN jsonb_build_object('advanced',true,'phase','sell','reason','action_timeout');
    END IF;

    v_next_index:=coalesce((v_state->>'draft_turn_index')::integer,0)+1;
    SELECT value->>'user_id' INTO v_next_user
    FROM jsonb_array_elements(v_players) AS x(value)
    WHERE (value->>'order_no')::integer=((v_next_index%v_player_count)+1);
    v_state:=jsonb_set(v_state,'{draft_turn_index}',to_jsonb(v_next_index),true);
    UPDATE public.games SET active_user_id=v_next_user,state=v_state,
      version=version+1,updated_at=now() WHERE id=v_game.id;
    INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
    VALUES(v_game.id,NULL,'action_timeout',jsonb_build_object('auto_kept_card',v_card->>'title','next_active_user_id',v_next_user));
    RETURN jsonb_build_object('advanced',true,'phase','action','reason','action_timeout','next_active_user_id',v_next_user);

  ELSIF v_game.phase='sell' THEN
    v_order:=coalesce(v_state->'sell_order','[]'::jsonb);
    IF jsonb_typeof(v_order)<>'array' OR jsonb_array_length(v_order)<>v_player_count THEN
      SELECT coalesce(jsonb_agg(to_jsonb(x.value->>'user_id') ORDER BY (x.value->>'order_no')::integer),'[]'::jsonb)
      INTO v_order FROM jsonb_array_elements(v_players) AS x(value);
    END IF;
    v_sell_index:=coalesce((v_state->>'sell_turn_index')::integer,0)+1;
    v_state:=jsonb_set(v_state,'{sell_order}',v_order,true);
    v_state:=jsonb_set(v_state,'{sell_turn_index}',to_jsonb(v_sell_index),true);
    v_state:=jsonb_set(v_state,'{history}',coalesce(v_state->'history','[]'::jsonb)||
      jsonb_build_array(jsonb_build_object('type','sell_auto_pass','user_id',v_game.active_user_id,'at',now())),true);

    IF v_sell_index>=jsonb_array_length(v_order) THEN
      v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('awaiting_economy'::text),true);
      UPDATE public.games SET phase='economy',active_user_id=NULL,state=v_state,
        version=version+1,updated_at=now() WHERE id=v_game.id;
      INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
      VALUES(v_game.id,NULL,'sell_timeout',jsonb_build_object('phase','economy'));
      RETURN jsonb_build_object('advanced',true,'phase','economy','reason','sell_timeout');
    END IF;

    v_next_user:=(v_order->>v_sell_index)::uuid;
    UPDATE public.games SET active_user_id=v_next_user,state=v_state,
      version=version+1,updated_at=now() WHERE id=v_game.id;
    INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
    VALUES(v_game.id,NULL,'sell_timeout',jsonb_build_object('next_active_user_id',v_next_user));
    RETURN jsonb_build_object('advanced',true,'phase','sell','reason','sell_timeout','next_active_user_id',v_next_user);

  ELSIF v_game.phase='economy' THEN
    v_result:=private.resolve_economy_v4_impl(p_room_id);
    RETURN jsonb_build_object('advanced',true,'phase','economy','reason','economy_timeout','result',v_result);
  END IF;

  RETURN jsonb_build_object('advanced',false,'phase',v_game.phase);
END;
$function$
;

GRANT USAGE ON SCHEMA private TO authenticated;
REVOKE ALL ON FUNCTION public.join_room_by_code_v2(text,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.respond_debt_offer(uuid,boolean) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.join_room_by_code_v2_impl(text,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.respond_debt_offer_impl(uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.join_room_by_code_v2_impl(text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION private.respond_debt_offer_impl(uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.join_room_by_code_v2(text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.respond_debt_offer(uuid,boolean) TO authenticated;
