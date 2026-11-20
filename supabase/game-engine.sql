-- StockLab Online gameplay engine patch
-- Apply AFTER supabase/schema.sql on a fresh project.
-- Decks and special-card effects are digital community adaptations, not verified official deck scans.
-- Function bodies are snapshotted from the active Supabase project on 2026-11-20.

CREATE SCHEMA IF NOT EXISTS private;

CREATE TABLE IF NOT EXISTS private.game_engine_secrets (
  game_id uuid PRIMARY KEY REFERENCES public.games(id) ON DELETE CASCADE,
  action_deck jsonb NOT NULL DEFAULT '[]'::jsonb,
  economy_stacks jsonb NOT NULL DEFAULT '{}'::jsonb,
  debt_cards_remaining integer NOT NULL DEFAULT 5 CHECK (debt_cards_remaining >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE private.game_engine_secrets ENABLE ROW LEVEL SECURITY;
REVOKE ALL PRIVILEGES ON TABLE private.game_engine_secrets FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON TABLE private.game_engine_secrets IS
  'Private StockLab action/economy decks and debt supply. Never exposed to browser clients.';

CREATE OR REPLACE FUNCTION private.change_player_share(p_players jsonb, p_user_id uuid, p_sector text, p_delta integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE v_out jsonb := '[]'::jsonb; v_item jsonb; v_shares jsonb; v_count integer;
BEGIN
  IF p_sector NOT IN ('finance','consumer','agriculture','mining','mutual_fund') THEN
    RAISE EXCEPTION 'Unknown share sector' USING errcode='22023';
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_players)
  LOOP
    IF v_item->>'user_id'=p_user_id::text THEN
      v_shares:=coalesce(v_item->'shares','{}'::jsonb);
      v_count:=greatest(0,coalesce((v_shares->>p_sector)::integer,0)+p_delta);
      v_shares:=jsonb_set(v_shares,ARRAY[p_sector],to_jsonb(v_count),true);
      v_item:=jsonb_set(v_item,'{shares}',v_shares,true);
    END IF;
    v_out:=v_out||jsonb_build_array(v_item);
  END LOOP;
  RETURN v_out;
END;
$function$


CREATE OR REPLACE FUNCTION private.apply_price_delta(p_players jsonb, p_market jsonb, p_sector text, p_delta integer, p_trigger_extremes boolean, p_split_tokens_remaining integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
  v_price integer; v_next integer; v_market jsonb:=p_market;
  v_players jsonb:='[]'::jsonb; v_player jsonb; v_shares jsonb; v_tokens jsonb;
  v_share_count integer; v_token_count integer; v_remaining integer:=p_split_tokens_remaining;
  v_outcome text:='normal';
BEGIN
  IF p_sector NOT IN ('finance','consumer','agriculture','mining') THEN
    RAISE EXCEPTION 'Unknown stock sector' USING errcode='22023';
  END IF;
  v_price:=coalesce((p_market->>p_sector)::integer,5);
  v_next:=v_price+p_delta;

  IF NOT p_trigger_extremes THEN
    v_next:=greatest(1,least(9,v_next));
  ELSIF v_next<1 THEN
    v_outcome:='stock_crash';
    FOR v_player IN SELECT value FROM jsonb_array_elements(p_players)
    LOOP
      v_shares:=coalesce(v_player->'shares','{}'::jsonb);
      v_tokens:=coalesce(v_player->'split_tokens','{}'::jsonb);
      v_token_count:=coalesce((v_tokens->>p_sector)::integer,0);
      v_remaining:=least(10,v_remaining+v_token_count);
      v_shares:=jsonb_set(v_shares,ARRAY[p_sector],to_jsonb(0),true);
      v_tokens:=jsonb_set(v_tokens,ARRAY[p_sector],to_jsonb(0),true);
      v_player:=jsonb_set(v_player,'{shares}',v_shares,true);
      v_player:=jsonb_set(v_player,'{split_tokens}',v_tokens,true);
      v_players:=v_players||jsonb_build_array(v_player);
    END LOOP;
    v_market:=jsonb_set(v_market,ARRAY[p_sector],to_jsonb(5),true);
    RETURN jsonb_build_object('players',v_players,'market',v_market,
      'split_tokens_remaining',v_remaining,'outcome',v_outcome,'old_price',v_price,'new_price',5);
  ELSIF v_next>9 THEN
    v_outcome:='stock_split';
    FOR v_player IN
      SELECT value FROM jsonb_array_elements(p_players) ORDER BY (value->>'order_no')::integer
    LOOP
      v_shares:=coalesce(v_player->'shares','{}'::jsonb);
      v_tokens:=coalesce(v_player->'split_tokens','{}'::jsonb);
      v_share_count:=coalesce((v_shares->>p_sector)::integer,0);
      IF v_share_count>0 AND v_remaining>0 THEN
        v_shares:=jsonb_set(v_shares,ARRAY[p_sector],to_jsonb(v_share_count+1),true);
        v_token_count:=coalesce((v_tokens->>p_sector)::integer,0);
        v_tokens:=jsonb_set(v_tokens,ARRAY[p_sector],to_jsonb(v_token_count+1),true);
        v_remaining:=v_remaining-1;
        v_player:=jsonb_set(v_player,'{shares}',v_shares,true);
        v_player:=jsonb_set(v_player,'{split_tokens}',v_tokens,true);
      END IF;
      v_players:=v_players||jsonb_build_array(v_player);
    END LOOP;
    v_market:=jsonb_set(v_market,ARRAY[p_sector],to_jsonb(5),true);
    RETURN jsonb_build_object('players',v_players,'market',v_market,
      'split_tokens_remaining',v_remaining,'outcome',v_outcome,'old_price',v_price,'new_price',5);
  END IF;

  v_market:=jsonb_set(v_market,ARRAY[p_sector],to_jsonb(v_next),true);
  RETURN jsonb_build_object('players',p_players,'market',v_market,
    'split_tokens_remaining',v_remaining,'outcome',v_outcome,'old_price',v_price,'new_price',v_next);
END;
$function$


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
  IF v_player_count NOT BETWEEN 2 AND 5 THEN
    RAISE EXCEPTION 'Room needs 2 to 5 players' USING errcode='22023';
  END IF;
  IF EXISTS(SELECT 1 FROM public.room_members WHERE room_id=p_room_id AND is_ready IS NOT TRUE) THEN
    RAISE EXCEPTION 'All players must be ready' USING errcode='55000';
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'user_id',q.user_id,'display_name',q.display_name,'seat_no',q.seat_no,
    'is_host',q.user_id=v_room.host_id,'order_no',q.order_no,
    'shares',jsonb_build_object('finance',0,'consumer',0,'agriculture',0,'mining',0,'mutual_fund',0),
    'split_tokens',jsonb_build_object('finance',0,'consumer',0,'agriculture',0,'mining',0)
  ) ORDER BY q.order_no)
  INTO v_players
  FROM (
    SELECT rm.user_id,rm.seat_no,coalesce(nullif(btrim(p.display_name),''),'Pemain') AS display_name,
      row_number() OVER (ORDER BY random(),rm.seat_no)::integer AS order_no
    FROM public.room_members rm LEFT JOIN public.profiles p ON p.id=rm.user_id
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
      ('trading-fee','Trading Fee','Bayar 1 koin per lembar dari jenis saham pada kartu ini, lalu jual satu jenis saham atau Reksa Dana.'),
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
      ('trading-fee','Trading Fee','Bayar 1 koin per unit Reksa Dana yang dimiliki, lalu jual satu jenis saham atau Reksa Dana.'),
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

  v_state := jsonb_build_object(
    'schema_version',3,'round',1,'phase','bidding','phase_status','awaiting_bids',
    'players',v_players,
    'market',jsonb_build_object('finance',5,'consumer',5,'agriculture',5,'mining',5),
    'action_market','[]'::jsonb,'draft_turn_index',0,'sell_turn_index',0,
    'sell_order','[]'::jsonb,'info_bursa_last_users','[]'::jsonb,
    'last_economy','[]'::jsonb,'last_economy_effects','[]'::jsonb,
    'bidding_results','[]'::jsonb,'split_tokens_remaining',10,
    'mutual_fund_pair',jsonb_build_array('consumer','agriculture'),
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


CREATE OR REPLACE FUNCTION public.start_game(p_room_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ SELECT private.start_game_impl(p_room_id); $function$


CREATE OR REPLACE FUNCTION private.get_game_view_impl(p_room_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid(); v_game public.games%rowtype; v_private jsonb;
  v_bid integer; v_bid_count integer; v_player_count integer; v_submitted boolean;
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
  RETURN jsonb_build_object(
    'game_id',v_game.id,'room_id',v_game.room_id,
    'current_round',v_game.current_round,'phase',v_game.phase,
    'active_user_id',v_game.active_user_id,'version',v_game.version,
    'state',v_game.state,'my_private_state',coalesce(v_private,'{}'::jsonb),
    'bidding',jsonb_build_object(
      'submitted',v_submitted,'my_bid',CASE WHEN v_submitted THEN v_bid ELSE NULL END,
      'submitted_count',v_bid_count,'player_count',v_player_count
    )
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.get_game_view(p_room_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ SELECT private.get_game_view_impl(p_room_id); $function$


CREATE OR REPLACE FUNCTION private.submit_bid_impl(p_room_id uuid, p_bid_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid(); v_game public.games%rowtype;
  v_secret private.game_engine_secrets%rowtype; v_private jsonb; v_state jsonb;
  v_players jsonb; v_results jsonb; v_market jsonb; v_remaining_deck jsonb;
  v_player_count integer; v_submitted_count integer; v_coins integer;
  v_card_count integer; v_first_user uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING errcode='28000'; END IF;
  SELECT * INTO v_game FROM public.games WHERE room_id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Game not found' USING errcode='P0002'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.room_members WHERE room_id=p_room_id AND user_id=v_user_id) THEN
    RAISE EXCEPTION 'Not a room member' USING errcode='42501';
  END IF;
  IF v_game.phase<>'bidding' OR v_game.state->>'phase_status' NOT IN ('awaiting_bids','collecting_bids') THEN
    RAISE EXCEPTION 'Bidding is not open' USING errcode='55000';
  END IF;
  IF p_bid_amount IS NULL OR p_bid_amount<1 THEN RAISE EXCEPTION 'Bid must be at least 1 coin' USING errcode='22023'; END IF;
  SELECT private_state INTO v_private FROM public.game_private_states
  WHERE game_id=v_game.id AND user_id=v_user_id FOR UPDATE;
  v_coins:=coalesce((v_private->>'coins')::integer,0);
  IF p_bid_amount>v_coins THEN RAISE EXCEPTION 'Bid exceeds your available coins' USING errcode='22023'; END IF;

  INSERT INTO public.bidding_submissions(game_id,round_number,user_id,bid_amount,submitted_at)
  VALUES(v_game.id,v_game.current_round,v_user_id,p_bid_amount,now())
  ON CONFLICT(game_id,round_number,user_id)
  DO UPDATE SET bid_amount=excluded.bid_amount,submitted_at=now();

  SELECT count(*)::integer INTO v_submitted_count FROM public.bidding_submissions
  WHERE game_id=v_game.id AND round_number=v_game.current_round;
  v_player_count:=jsonb_array_length(v_game.state->'players');
  v_state:=v_game.state;

  IF v_submitted_count<v_player_count THEN
    v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('collecting_bids'::text),true);
    UPDATE public.games SET state=v_state,version=version+1,updated_at=now() WHERE id=v_game.id;
    RETURN jsonb_build_object('resolved',false,'submitted_count',v_submitted_count,'player_count',v_player_count);
  END IF;

  UPDATE public.game_private_states gps
  SET private_state=jsonb_set(gps.private_state,'{coins}',
    to_jsonb((gps.private_state->>'coins')::integer-b.bid_amount),true),
    updated_at=now()
  FROM public.bidding_submissions b
  WHERE b.game_id=v_game.id AND b.round_number=v_game.current_round
    AND gps.game_id=v_game.id AND gps.user_id=b.user_id;

  SELECT jsonb_agg(jsonb_set(r.player,'{order_no}',to_jsonb(r.new_order),true) ORDER BY r.new_order),
         jsonb_agg(jsonb_build_object(
           'user_id',r.player->>'user_id','display_name',r.player->>'display_name',
           'bid_amount',r.bid_amount,'order_no',r.new_order
         ) ORDER BY r.new_order)
  INTO v_players,v_results
  FROM (
    SELECT p.value AS player,b.bid_amount,
      row_number() OVER(ORDER BY b.bid_amount DESC,(p.value->>'order_no')::integer ASC)::integer AS new_order
    FROM jsonb_array_elements(v_state->'players') AS p(value)
    JOIN public.bidding_submissions b
      ON b.game_id=v_game.id AND b.round_number=v_game.current_round
      AND b.user_id=(p.value->>'user_id')::uuid
  ) r;

  SELECT value->>'user_id' INTO v_first_user
  FROM jsonb_array_elements(v_players) AS p(value)
  WHERE (value->>'order_no')::integer=1;

  SELECT * INTO v_secret FROM private.game_engine_secrets WHERE game_id=v_game.id FOR UPDATE;
  v_card_count:=v_player_count*2;
  SELECT coalesce(jsonb_agg(x.card ORDER BY x.ord),'[]'::jsonb) INTO v_market
  FROM jsonb_array_elements(v_secret.action_deck) WITH ORDINALITY AS x(card,ord)
  WHERE x.ord<=v_card_count;
  SELECT coalesce(jsonb_agg(x.card ORDER BY x.ord),'[]'::jsonb) INTO v_remaining_deck
  FROM jsonb_array_elements(v_secret.action_deck) WITH ORDINALITY AS x(card,ord)
  WHERE x.ord>v_card_count;
  IF jsonb_array_length(v_market)<>v_card_count THEN
    RAISE EXCEPTION 'Action deck is exhausted' USING errcode='55000';
  END IF;
  UPDATE private.game_engine_secrets SET action_deck=v_remaining_deck,updated_at=now()
  WHERE game_id=v_game.id;

  v_state:=jsonb_set(v_state,'{players}',v_players,true);
  v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('drafting'::text),true);
  v_state:=jsonb_set(v_state,'{action_market}',v_market,true);
  v_state:=jsonb_set(v_state,'{draft_turn_index}',to_jsonb(0),true);
  v_state:=jsonb_set(v_state,'{bidding_results}',v_results,true);
  v_state:=jsonb_set(v_state,'{history}',coalesce(v_state->'history','[]'::jsonb)||
    jsonb_build_array(jsonb_build_object('type','bids_revealed','round',v_game.current_round,'at',now())),true);

  UPDATE public.games SET phase='action',active_user_id=v_first_user,state=v_state,
    version=version+1,updated_at=now() WHERE id=v_game.id;
  INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
  VALUES(v_game.id,v_user_id,'bids_revealed',jsonb_build_object('round',v_game.current_round,'results',v_results));
  RETURN jsonb_build_object('resolved',true,'phase','action','active_user_id',v_first_user,
    'bidding_results',v_results,'action_market',v_market);
END;
$function$


CREATE OR REPLACE FUNCTION private.submit_bid_v2_impl(p_room_id uuid, p_bid_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid();
  v_game public.games%rowtype;
  v_existing boolean;
  v_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING errcode='28000';
  END IF;
  SELECT * INTO v_game
  FROM public.games
  WHERE room_id=p_room_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game not found' USING errcode='P0002';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.room_members
    WHERE room_id=p_room_id AND user_id=v_user_id
  ) THEN
    RAISE EXCEPTION 'Not a room member' USING errcode='42501';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM public.bidding_submissions
    WHERE game_id=v_game.id
      AND round_number=v_game.current_round
      AND user_id=v_user_id
  ) INTO v_existing;
  IF v_existing THEN
    RAISE EXCEPTION 'Your bid is already locked and cannot be changed' USING errcode='55000';
  END IF;
  v_result:=private.submit_bid_impl(p_room_id,p_bid_amount);
  RETURN v_result;
END;
$function$


CREATE OR REPLACE FUNCTION public.submit_bid(p_room_id uuid, p_bid_amount integer)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ SELECT private.submit_bid_v2_impl(p_room_id,p_bid_amount); $function$


CREATE OR REPLACE FUNCTION private.perform_action_card_impl(p_room_id uuid, p_card_id text, p_mode text, p_choice jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid();
  v_game public.games%rowtype;
  v_state jsonb;
  v_card jsonb;
  v_players jsonb;
  v_player jsonb;
  v_target_player jsonb;
  v_secret private.game_engine_secrets%rowtype;
  v_private jsonb;
  v_sector text;
  v_action text;
  v_choice jsonb:=coalesce(p_choice,'{}'::jsonb);
  v_coins integer;
  v_fee integer;
  v_sell_sector text;
  v_quantity integer;
  v_sale_price integer;
  v_target_id uuid;
  v_target_sector text;
  v_actor_shares integer;
  v_target_shares integer;
  v_market jsonb;
  v_price_change jsonb;
  v_s1 text;
  v_s2 text;
  v_s3 text;
  v_mode text;
  v_delta integer;
  v_split_remaining integer;
  v_player_count integer;
  v_next_index integer;
  v_next_user uuid;
  v_remaining_cards jsonb;
  v_extra_ids text[]:=ARRAY[]::text[];
  v_extra_card jsonb;
  v_extra_sector text;
  v_pair jsonb;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING errcode='28000'; END IF;
  SELECT * INTO v_game FROM public.games WHERE room_id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Game not found' USING errcode='P0002'; END IF;
  IF v_game.phase<>'action' OR v_game.state->>'phase_status'<>'drafting' THEN
    RAISE EXCEPTION 'Action phase is not open' USING errcode='55000';
  END IF;
  IF v_game.active_user_id IS DISTINCT FROM v_user_id THEN
    RAISE EXCEPTION 'It is not your turn' USING errcode='42501';
  END IF;
  IF p_mode NOT IN ('keep','activate') THEN
    RAISE EXCEPTION 'Choose keep or activate' USING errcode='22023';
  END IF;

  v_state:=v_game.state;
  v_players:=v_state->'players';
  v_market:=v_state->'market';
  SELECT value INTO v_card
  FROM jsonb_array_elements(v_state->'action_market') AS c(value)
  WHERE value->>'id'=p_card_id;
  IF v_card IS NULL THEN RAISE EXCEPTION 'That card is no longer available' USING errcode='P0002'; END IF;

  v_sector:=v_card->>'sector';
  v_action:=v_card->>'action';
  SELECT value INTO v_player
  FROM jsonb_array_elements(v_players) AS p(value)
  WHERE value->>'user_id'=v_user_id::text;
  IF v_player IS NULL THEN RAISE EXCEPTION 'Player is not in this game' USING errcode='42501'; END IF;
  SELECT private_state INTO v_private
  FROM public.game_private_states
  WHERE game_id=v_game.id AND user_id=v_user_id FOR UPDATE;
  v_coins:=coalesce((v_private->>'coins')::integer,0);

  IF p_mode='keep' THEN
    IF v_sector NOT IN ('finance','consumer','agriculture','mining','mutual_fund') THEN
      RAISE EXCEPTION 'Card cannot be kept as an investment unit' USING errcode='22023';
    END IF;
    v_players:=private.change_player_share(v_players,v_user_id,v_sector,1);
  ELSE
    CASE v_action
      WHEN 'info-bursa' THEN
        IF v_sector='mutual_fund' THEN
          RAISE EXCEPTION 'Info Bursa is not available on a Mutual Fund card' USING errcode='22023';
        END IF;
        v_s1:=v_choice->>'sector_a';
        v_s2:=v_choice->>'sector_b';
        v_s3:=v_choice->>'sector_c';
        IF v_s1 NOT IN ('finance','consumer','agriculture','mining')
          OR v_s2 NOT IN ('finance','consumer','agriculture','mining')
          OR v_s3 NOT IN ('finance','consumer','agriculture','mining')
          OR v_s1=v_s2 OR v_s1=v_s3 OR v_s2=v_s3 THEN
          RAISE EXCEPTION 'Choose three different stock sectors to inspect' USING errcode='22023';
        END IF;
        SELECT * INTO v_secret FROM private.game_engine_secrets WHERE game_id=v_game.id;
        v_private:=jsonb_set(v_private,'{peek}',jsonb_build_array(
          jsonb_build_object('sector',v_s1,'card',v_secret.economy_stacks->v_s1->0),
          jsonb_build_object('sector',v_s2,'card',v_secret.economy_stacks->v_s2->0),
          jsonb_build_object('sector',v_s3,'card',v_secret.economy_stacks->v_s3->0)
        ),true);
        v_private:=jsonb_set(v_private,'{coins}',to_jsonb(v_coins+2),true);

      WHEN 'rumor' THEN
        v_mode:=v_choice->>'mode';
        v_market:=v_state->'market';
        v_split_remaining:=coalesce((v_state->>'split_tokens_remaining')::integer,10);
        IF v_mode='single' THEN
          v_s1:=v_choice->>'sector';
          v_delta:=(v_choice->>'delta')::integer;
          IF v_s1 NOT IN ('finance','consumer','agriculture','mining') OR v_delta NOT IN (-2,2) THEN
            RAISE EXCEPTION 'Rumor must move one sector by +2 or -2' USING errcode='22023';
          END IF;
          v_price_change:=private.apply_price_delta(v_players,v_market,v_s1,v_delta,false,v_split_remaining);
          v_players:=v_price_change->'players';
          v_market:=v_price_change->'market';
        ELSIF v_mode='double' THEN
          v_s1:=v_choice->>'sector_a';
          v_s2:=v_choice->>'sector_b';
          IF v_s1 NOT IN ('finance','consumer','agriculture','mining')
            OR v_s2 NOT IN ('finance','consumer','agriculture','mining') OR v_s1=v_s2 THEN
            RAISE EXCEPTION 'Rumor requires two different sectors' USING errcode='22023';
          END IF;
          v_delta:=(v_choice->>'delta_a')::integer;
          IF v_delta NOT IN (-1,1) THEN RAISE EXCEPTION 'Each Rumor move must be +1 or -1' USING errcode='22023'; END IF;
          v_price_change:=private.apply_price_delta(v_players,v_market,v_s1,v_delta,false,v_split_remaining);
          v_players:=v_price_change->'players';
          v_market:=v_price_change->'market';
          v_delta:=(v_choice->>'delta_b')::integer;
          IF v_delta NOT IN (-1,1) THEN RAISE EXCEPTION 'Each Rumor move must be +1 or -1' USING errcode='22023'; END IF;
          v_price_change:=private.apply_price_delta(v_players,v_market,v_s2,v_delta,false,v_split_remaining);
          v_players:=v_price_change->'players';
          v_market:=v_price_change->'market';
        ELSE
          RAISE EXCEPTION 'Unknown Rumor option' USING errcode='22023';
        END IF;
        v_state:=jsonb_set(v_state,'{market}',v_market,true);
        v_state:=jsonb_set(v_state,'{split_tokens_remaining}',to_jsonb(v_split_remaining),true);

      WHEN 'quickbuy' THEN
        IF jsonb_typeof(v_choice->'card_ids') IS DISTINCT FROM 'array'
          OR jsonb_array_length(v_choice->'card_ids')<>2 THEN
          RAISE EXCEPTION 'Quickbuy requires exactly two other cards to keep' USING errcode='22023';
        END IF;
        SELECT array_agg(value) INTO v_extra_ids
        FROM jsonb_array_elements_text(v_choice->'card_ids');
        IF cardinality(v_extra_ids)<>2 OR v_extra_ids[1]=v_extra_ids[2] OR p_card_id=ANY(v_extra_ids) THEN
          RAISE EXCEPTION 'Choose two different cards other than Quickbuy' USING errcode='22023';
        END IF;
        FOR v_extra_card IN
          SELECT value
          FROM jsonb_array_elements(v_state->'action_market') AS c(value)
          WHERE value->>'id'=ANY(v_extra_ids)
        LOOP
          v_extra_sector:=v_extra_card->>'sector';
          IF v_extra_sector NOT IN ('finance','consumer','agriculture','mining','mutual_fund') THEN
            RAISE EXCEPTION 'Quickbuy selected an invalid card' USING errcode='22023';
          END IF;
          v_players:=private.change_player_share(v_players,v_user_id,v_extra_sector,1);
        END LOOP;
        IF (SELECT count(*) FROM jsonb_array_elements(v_state->'action_market') AS c(value)
            WHERE value->>'id'=ANY(v_extra_ids))<>2 THEN
          RAISE EXCEPTION 'One or more Quickbuy cards are no longer available' USING errcode='P0002';
        END IF;

      WHEN 'trading-fee' THEN
        v_fee:=coalesce((v_player->'shares'->>v_sector)::integer,0);
        IF v_coins<v_fee THEN
          RAISE EXCEPTION 'Not enough coins to pay Trading Fee (% coins)',v_fee USING errcode='22023';
        END IF;
        v_sell_sector:=v_choice->>'sell_sector';
        v_quantity:=(v_choice->>'quantity')::integer;
        IF v_sell_sector NOT IN ('finance','consumer','agriculture','mining','mutual_fund')
          OR v_quantity IS NULL OR v_quantity<1 THEN
          RAISE EXCEPTION 'Choose a share type and quantity to sell' USING errcode='22023';
        END IF;
        SELECT value INTO v_player
        FROM jsonb_array_elements(v_players) AS p(value)
        WHERE value->>'user_id'=v_user_id::text;
        IF v_quantity>coalesce((v_player->'shares'->>v_sell_sector)::integer,0) THEN
          RAISE EXCEPTION 'You do not own that many units' USING errcode='22023';
        END IF;
        IF v_sell_sector='mutual_fund' THEN
          v_pair:=coalesce(v_state->'mutual_fund_pair',jsonb_build_array('consumer','agriculture'));
          v_sale_price:=floor((
            (v_market->>(v_pair->>0))::numeric+(v_market->>(v_pair->>1))::numeric
          )/2)::integer;
        ELSE
          v_sale_price:=(v_market->>v_sell_sector)::integer;
        END IF;
        v_players:=private.change_player_share(v_players,v_user_id,v_sell_sector,-v_quantity);
        v_private:=jsonb_set(v_private,'{coins}',to_jsonb(v_coins-v_fee+v_quantity*v_sale_price),true);

      WHEN 'acquisition' THEN
        v_target_id:=(v_choice->>'target_user_id')::uuid;
        v_target_sector:=CASE WHEN v_sector='mutual_fund'
          THEN v_choice->>'target_sector' ELSE v_sector END;
        IF v_target_sector NOT IN ('finance','consumer','agriculture','mining') THEN
          RAISE EXCEPTION 'Acquisition cannot target Mutual Fund; choose a stock sector' USING errcode='22023';
        END IF;
        IF v_target_id IS NULL OR v_target_id=v_user_id THEN
          RAISE EXCEPTION 'Choose another player' USING errcode='22023';
        END IF;
        SELECT value INTO v_target_player
        FROM jsonb_array_elements(v_players) AS p(value)
        WHERE value->>'user_id'=v_target_id::text;
        IF v_target_player IS NULL THEN RAISE EXCEPTION 'Target player not found' USING errcode='22023'; END IF;
        SELECT value INTO v_player
        FROM jsonb_array_elements(v_players) AS p(value)
        WHERE value->>'user_id'=v_user_id::text;
        v_actor_shares:=coalesce((v_player->'shares'->>v_target_sector)::integer,0);
        v_target_shares:=coalesce((v_target_player->'shares'->>v_target_sector)::integer,0);
        IF v_target_shares<1 OR v_actor_shares<v_target_shares THEN
          RAISE EXCEPTION 'Your holdings must be at least as large as the target holdings' USING errcode='22023';
        END IF;
        v_sale_price:=(v_market->>v_target_sector)::integer;
        v_players:=private.change_player_share(v_players,v_target_id,v_target_sector,-1);
        v_players:=private.change_player_share(v_players,v_user_id,v_target_sector,1);
        UPDATE public.game_private_states
        SET private_state=jsonb_set(private_state,'{coins}',
          to_jsonb((private_state->>'coins')::integer+floor(v_sale_price::numeric/2)::integer),true),
          updated_at=now()
        WHERE game_id=v_game.id AND user_id=v_target_id;

      ELSE
        RAISE EXCEPTION 'Unsupported action card' USING errcode='22023';
    END CASE;
  END IF;

  SELECT coalesce(jsonb_agg(x.card ORDER BY x.ord),'[]'::jsonb)
  INTO v_remaining_cards
  FROM jsonb_array_elements(v_state->'action_market') WITH ORDINALITY AS x(card,ord)
  WHERE x.card->>'id'<>p_card_id
    AND NOT (x.card->>'id'=ANY(v_extra_ids));
  v_state:=jsonb_set(v_state,'{players}',v_players,true);
  v_state:=jsonb_set(v_state,'{action_market}',v_remaining_cards,true);
  v_state:=jsonb_set(v_state,'{history}',coalesce(v_state->'history','[]'::jsonb)||
    jsonb_build_array(jsonb_build_object(
      'type','action_card','round',v_game.current_round,'user_id',v_user_id,
      'card_title',v_card->>'title','sector',v_sector,'mode',p_mode,
      'quickbuy_card_ids',to_jsonb(v_extra_ids),'at',now()
    )),true);

  v_player_count:=jsonb_array_length(v_players);
  v_next_index:=coalesce((v_state->>'draft_turn_index')::integer,0)+1;
  IF jsonb_array_length(v_remaining_cards)=0 THEN
    SELECT value->>'user_id' INTO v_next_user
    FROM jsonb_array_elements(v_players) AS p(value)
    WHERE (value->>'order_no')::integer=1;
    v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('selling'::text),true);
    v_state:=jsonb_set(v_state,'{sell_turn_index}',to_jsonb(0),true);
    UPDATE public.games SET phase='sell',active_user_id=v_next_user,state=v_state,
      version=version+1,updated_at=now() WHERE id=v_game.id;
  ELSE
    SELECT value->>'user_id' INTO v_next_user
    FROM jsonb_array_elements(v_players) AS p(value)
    WHERE (value->>'order_no')::integer=((v_next_index%v_player_count)+1);
    v_state:=jsonb_set(v_state,'{draft_turn_index}',to_jsonb(v_next_index),true);
    UPDATE public.games SET state=v_state,active_user_id=v_next_user,
      version=version+1,updated_at=now() WHERE id=v_game.id;
  END IF;

  UPDATE public.game_private_states SET private_state=v_private,updated_at=now()
  WHERE game_id=v_game.id AND user_id=v_user_id;
  INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
  VALUES(v_game.id,v_user_id,'action_card_used',jsonb_build_object(
    'card_id',p_card_id,'mode',p_mode,'action',v_action,'sector',v_sector
  ));
  RETURN jsonb_build_object(
    'ok',true,'remaining_action_cards',jsonb_array_length(v_remaining_cards),
    'next_active_user_id',v_next_user,
    'phase',CASE WHEN jsonb_array_length(v_remaining_cards)=0 THEN 'sell' ELSE 'action' END
  );
END;
$function$


CREATE OR REPLACE FUNCTION private.perform_action_card_v2_impl(p_room_id uuid, p_card_id text, p_mode text, p_choice jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid();
  v_before public.games%rowtype;
  v_after public.games%rowtype;
  v_card jsonb;
  v_state jsonb;
  v_players jsonb;
  v_result jsonb;
  v_sector text;
  v_info_users jsonb;
  v_sell_order jsonb;
  v_first_user uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING errcode='28000';
  END IF;
  SELECT * INTO v_before FROM public.games WHERE room_id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game not found' USING errcode='P0002';
  END IF;
  IF v_before.active_user_id IS DISTINCT FROM v_user_id THEN
    RAISE EXCEPTION 'It is not your turn' USING errcode='42501';
  END IF;
  SELECT value INTO v_card
  FROM jsonb_array_elements(v_before.state->'action_market') AS c(value)
  WHERE value->>'id'=p_card_id;
  IF v_card IS NULL THEN
    RAISE EXCEPTION 'That card is no longer available' USING errcode='P0002';
  END IF;
  v_sector:=v_card->>'sector';

  -- The existing engine resolves the chosen card and advances the draft turn atomically.
  v_result:=private.perform_action_card_impl(p_room_id,p_card_id,p_mode,p_choice);

  SELECT * INTO v_after FROM public.games WHERE room_id=p_room_id FOR UPDATE;
  v_state:=v_after.state;

  -- Some competition guides allow a stored action card to become a mutual fund unit.
  IF p_mode='keep' AND v_sector='mutual_fund' AND coalesce(p_choice->>'keep_as','stock')='mutual_fund' THEN
    v_players:=private.change_player_share(v_state->'players',v_user_id,v_sector,-1);
    v_players:=private.change_player_share(v_players,v_user_id,'mutual_fund',1);
    v_state:=jsonb_set(v_state,'{players}',v_players,true);
  END IF;

  -- Info Bursa users take their sell decision after the normal order.
  IF p_mode='activate' AND v_card->>'action'='info-bursa' THEN
    v_info_users:=coalesce(v_state->'info_bursa_last_users','[]'::jsonb);
    IF NOT (v_info_users ? v_user_id::text) THEN
      v_info_users:=v_info_users || jsonb_build_array(v_user_id::text);
    END IF;
    v_state:=jsonb_set(v_state,'{info_bursa_last_users}',v_info_users,true);
  END IF;

  -- When the last action card is picked, lock the sell order with Info Bursa players last.
  IF v_after.phase='sell' AND v_state->>'phase_status'='selling' THEN
    SELECT coalesce(jsonb_agg(to_jsonb(q.user_id) ORDER BY q.is_info_bursa,q.order_no),'[]'::jsonb)
    INTO v_sell_order
    FROM (
      SELECT
        p.value->>'user_id' AS user_id,
        (p.value->>'order_no')::integer AS order_no,
        CASE WHEN coalesce(v_state->'info_bursa_last_users','[]'::jsonb) ? (p.value->>'user_id')
          THEN 1 ELSE 0 END AS is_info_bursa
      FROM jsonb_array_elements(v_state->'players') AS p(value)
    ) q;
    v_state:=jsonb_set(v_state,'{sell_order}',v_sell_order,true);
    v_first_user:=(v_sell_order->>0)::uuid;
    UPDATE public.games
    SET state=v_state,active_user_id=v_first_user,version=version+1,updated_at=now()
    WHERE id=v_after.id;
  ELSIF v_state IS DISTINCT FROM v_after.state THEN
    UPDATE public.games
    SET state=v_state,version=version+1,updated_at=now()
    WHERE id=v_after.id;
  END IF;

  RETURN v_result;
END;
$function$


CREATE OR REPLACE FUNCTION public.perform_action_card(p_room_id uuid, p_card_id text, p_mode text, p_choice jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ SELECT private.perform_action_card_v2_impl(p_room_id,p_card_id,p_mode,p_choice); $function$


CREATE OR REPLACE FUNCTION private.complete_sell_turn_impl(p_room_id uuid, p_sector text, p_quantity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid();
  v_game public.games%rowtype;
  v_state jsonb;
  v_players jsonb;
  v_player jsonb;
  v_shares jsonb;
  v_private jsonb;
  v_coins integer;
  v_count integer;
  v_price integer;
  v_next_index integer;
  v_next_user uuid;
  v_phase text:='sell';
  v_pair jsonb;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING errcode='28000'; END IF;
  SELECT * INTO v_game FROM public.games WHERE room_id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Game not found' USING errcode='P0002'; END IF;
  IF v_game.phase<>'sell' OR v_game.state->>'phase_status'<>'selling' THEN
    RAISE EXCEPTION 'Selling phase is not open' USING errcode='55000';
  END IF;
  IF v_game.active_user_id IS DISTINCT FROM v_user_id THEN
    RAISE EXCEPTION 'It is not your sell turn' USING errcode='42501';
  END IF;
  IF p_quantity IS NULL OR p_quantity<0 THEN RAISE EXCEPTION 'Invalid quantity' USING errcode='22023'; END IF;

  v_state:=v_game.state;
  v_players:=v_state->'players';
  SELECT value INTO v_player FROM jsonb_array_elements(v_players) AS p(value)
  WHERE value->>'user_id'=v_user_id::text;
  IF v_player IS NULL THEN RAISE EXCEPTION 'Player is not in the game' USING errcode='42501'; END IF;
  v_shares:=v_player->'shares';
  SELECT private_state INTO v_private FROM public.game_private_states
  WHERE game_id=v_game.id AND user_id=v_user_id FOR UPDATE;
  v_coins:=coalesce((v_private->>'coins')::integer,0);

  IF p_quantity=0 THEN
    IF p_sector IS NOT NULL THEN RAISE EXCEPTION 'Choose no sector when passing' USING errcode='22023'; END IF;
  ELSE
    IF p_sector NOT IN ('finance','consumer','agriculture','mining','mutual_fund') THEN
      RAISE EXCEPTION 'Choose a valid stock or Mutual Fund type' USING errcode='22023';
    END IF;
    v_count:=coalesce((v_shares->>p_sector)::integer,0);
    IF p_quantity>v_count THEN RAISE EXCEPTION 'You do not own that many units' USING errcode='22023'; END IF;
    IF p_sector='mutual_fund' THEN
      v_pair:=coalesce(v_state->'mutual_fund_pair',jsonb_build_array('consumer','agriculture'));
      v_price:=floor((
        (v_state->'market'->>(v_pair->>0))::numeric+
        (v_state->'market'->>(v_pair->>1))::numeric
      )/2)::integer;
    ELSE
      v_price:=(v_state->'market'->>p_sector)::integer;
    END IF;
    v_players:=private.change_player_share(v_players,v_user_id,p_sector,-p_quantity);
    v_private:=jsonb_set(v_private,'{coins}',to_jsonb(v_coins+p_quantity*v_price),true);
    UPDATE public.game_private_states SET private_state=v_private,updated_at=now()
    WHERE game_id=v_game.id AND user_id=v_user_id;
  END IF;

  v_next_index:=coalesce((v_state->>'sell_turn_index')::integer,0)+1;
  v_count:=jsonb_array_length(v_players);
  IF v_next_index>=v_count THEN
    v_phase:='economy';
    v_next_user:=NULL;
    v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('awaiting_economy'::text),true);
  ELSE
    IF jsonb_typeof(v_state->'sell_order')='array'
      AND jsonb_array_length(v_state->'sell_order')=v_count THEN
      v_next_user:=(v_state->'sell_order'->>v_next_index)::uuid;
    ELSE
      SELECT value->>'user_id' INTO v_next_user
      FROM jsonb_array_elements(v_players) AS p(value)
      WHERE (value->>'order_no')::integer=v_next_index+1;
    END IF;
  END IF;

  v_state:=jsonb_set(v_state,'{players}',v_players,true);
  v_state:=jsonb_set(v_state,'{sell_turn_index}',to_jsonb(v_next_index),true);
  v_state:=jsonb_set(v_state,'{history}',coalesce(v_state->'history','[]'::jsonb)||
    jsonb_build_array(jsonb_build_object(
      'type','sell_turn','round',v_game.current_round,'user_id',v_user_id,
      'sector',p_sector,'quantity',p_quantity,'at',now()
    )),true);
  UPDATE public.games SET phase=v_phase,active_user_id=v_next_user,state=v_state,
    version=version+1,updated_at=now() WHERE id=v_game.id;
  INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
  VALUES(v_game.id,v_user_id,'sell_turn',jsonb_build_object('sector',p_sector,'quantity',p_quantity));
  RETURN jsonb_build_object('ok',true,'phase',v_phase,'next_active_user_id',v_next_user);
END;
$function$


CREATE OR REPLACE FUNCTION private.complete_sell_turn_v2_impl(p_room_id uuid, p_sector text, p_quantity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid();
  v_before public.games%rowtype;
  v_after public.games%rowtype;
  v_order jsonb;
  v_index integer;
  v_next_user uuid;
  v_result jsonb;
  v_state jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING errcode='28000';
  END IF;
  SELECT * INTO v_before FROM public.games WHERE room_id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game not found' USING errcode='P0002';
  END IF;
  IF v_before.active_user_id IS DISTINCT FROM v_user_id THEN
    RAISE EXCEPTION 'It is not your sell turn' USING errcode='42501';
  END IF;
  v_result:=private.complete_sell_turn_impl(p_room_id,p_sector,p_quantity);
  SELECT * INTO v_after FROM public.games WHERE room_id=p_room_id FOR UPDATE;
  IF v_after.phase='sell' THEN
    v_state:=v_after.state;
    v_order:=coalesce(v_state->'sell_order','[]'::jsonb);
    IF jsonb_array_length(v_order)=0 THEN
      SELECT coalesce(jsonb_agg(to_jsonb(q.user_id) ORDER BY q.order_no),'[]'::jsonb)
      INTO v_order
      FROM (
        SELECT value->>'user_id' AS user_id,(value->>'order_no')::integer AS order_no
        FROM jsonb_array_elements(v_state->'players') AS p(value)
      ) q;
      v_state:=jsonb_set(v_state,'{sell_order}',v_order,true);
    END IF;
    v_index:=coalesce((v_state->>'sell_turn_index')::integer,0);
    IF v_index<jsonb_array_length(v_order) THEN
      v_next_user:=(v_order->>(v_index))::uuid;
      UPDATE public.games
      SET state=v_state,active_user_id=v_next_user,version=version+1,updated_at=now()
      WHERE id=v_after.id;
    END IF;
  END IF;
  RETURN v_result;
END;
$function$


CREATE OR REPLACE FUNCTION public.complete_sell_turn(p_room_id uuid, p_sector text, p_quantity integer)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ SELECT private.complete_sell_turn_v2_impl(p_room_id,p_sector,p_quantity); $function$


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
BEGIN
  IF v_user_id IS NULL THEN
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
  IF NOT FOUND OR v_room.host_id<>v_user_id THEN
    RAISE EXCEPTION 'Only host can reveal economy cards' USING errcode='42501';
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
  v_state:=jsonb_set(v_state,'{round}',to_jsonb(v_next_round),true);
  v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('awaiting_bids'::text),true);
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


CREATE OR REPLACE FUNCTION public.resolve_economy(p_room_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  SELECT private.resolve_economy_v4_impl(p_room_id);
$function$


CREATE OR REPLACE FUNCTION private.take_debt_impl(p_room_id uuid, p_sector text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid();
  v_game public.games%rowtype;
  v_state jsonb;
  v_players jsonb;
  v_player jsonb;
  v_tokens jsonb;
  v_private jsonb;
  v_shares integer;
  v_token_count integer;
  v_coins integer;
  v_debt integer;
  v_secret private.game_engine_secrets%rowtype;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING errcode='28000';
  END IF;
  IF p_sector NOT IN ('finance','consumer','agriculture','mining') THEN
    RAISE EXCEPTION 'Choose one stock sector to flip' USING errcode='22023';
  END IF;

  SELECT * INTO v_game
  FROM public.games
  WHERE room_id=p_room_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game not found' USING errcode='P0002';
  END IF;
  IF v_game.phase='finished' THEN
    RAISE EXCEPTION 'Game is finished' USING errcode='55000';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.room_members
    WHERE room_id=p_room_id AND user_id=v_user_id
  ) THEN
    RAISE EXCEPTION 'Not a room member' USING errcode='42501';
  END IF;

  SELECT private_state INTO v_private
  FROM public.game_private_states
  WHERE game_id=v_game.id AND user_id=v_user_id
  FOR UPDATE;
  IF v_private IS NULL THEN
    RAISE EXCEPTION 'Player wallet not found' USING errcode='P0002';
  END IF;
  v_coins:=coalesce((v_private->>'coins')::integer,0);
  v_debt:=coalesce((v_private->>'debt')::integer,0);
  IF v_debt>=1 THEN
    RAISE EXCEPTION 'Each player can use at most one debt card' USING errcode='55000';
  END IF;

  SELECT * INTO v_secret
  FROM private.game_engine_secrets
  WHERE game_id=v_game.id
  FOR UPDATE;
  IF NOT FOUND OR v_secret.debt_cards_remaining<=0 THEN
    RAISE EXCEPTION 'No debt cards remain' USING errcode='55000';
  END IF;

  v_state:=v_game.state;
  v_players:=v_state->'players';
  SELECT value INTO v_player
  FROM jsonb_array_elements(v_players) AS p(value)
  WHERE value->>'user_id'=v_user_id::text;
  IF v_player IS NULL THEN
    RAISE EXCEPTION 'Player not found in game state' USING errcode='42501';
  END IF;

  v_shares:=coalesce((v_player->'shares'->>p_sector)::integer,0);
  IF v_shares<1 THEN
    RAISE EXCEPTION 'You must own at least one share in the chosen sector' USING errcode='22023';
  END IF;

  v_tokens:=coalesce(v_player->'split_tokens','{}'::jsonb);
  v_token_count:=coalesce((v_tokens->>p_sector)::integer,0);
  v_players:=private.change_player_share(v_players,v_user_id,p_sector,-1);
  IF v_token_count>0 THEN
    v_tokens:=jsonb_set(v_tokens,ARRAY[p_sector],to_jsonb(v_token_count-1),true);
    v_players:=(
      SELECT jsonb_agg(
        CASE WHEN value->>'user_id'=v_user_id::text
          THEN jsonb_set(value,'{split_tokens}',v_tokens,true)
          ELSE value
        END ORDER BY ord
      )
      FROM jsonb_array_elements(v_players) WITH ORDINALITY AS x(value,ord)
    );
    v_state:=jsonb_set(
      v_state,'{split_tokens_remaining}',
      to_jsonb(least(10,coalesce((v_state->>'split_tokens_remaining')::integer,0)+1)),true
    );
  END IF;

  v_private:=jsonb_set(v_private,'{coins}',to_jsonb(v_coins+10),true);
  v_private:=jsonb_set(v_private,'{debt}',to_jsonb(v_debt+1),true);
  UPDATE public.game_private_states
  SET private_state=v_private,updated_at=now()
  WHERE game_id=v_game.id AND user_id=v_user_id;

  v_state:=jsonb_set(v_state,'{players}',v_players,true);
  v_state:=jsonb_set(v_state,'{history}',coalesce(v_state->'history','[]'::jsonb)||
    jsonb_build_array(jsonb_build_object(
      'type','debt_taken','user_id',v_user_id,'flipped_sector',p_sector,'at',now()
    )),true);
  UPDATE public.games
  SET state=v_state,version=version+1,updated_at=now()
  WHERE id=v_game.id;

  UPDATE private.game_engine_secrets
  SET debt_cards_remaining=debt_cards_remaining-1,updated_at=now()
  WHERE game_id=v_game.id;

  INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
  VALUES(v_game.id,v_user_id,'debt_taken',jsonb_build_object(
    'flipped_sector',p_sector,'coins_borrowed',10,'repayment',13
  ));

  RETURN jsonb_build_object(
    'ok',true,'coins',v_coins+10,'debt',v_debt+1,
    'flipped_sector',p_sector,'repayment',13
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.take_debt(p_room_id uuid, p_sector text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  SELECT private.take_debt_impl(p_room_id,p_sector);
$function$


CREATE OR REPLACE FUNCTION private.leave_room_impl(p_room_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid:=auth.uid();
  v_host_id uuid;
  v_status text;
  v_members integer;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING errcode='28000';
  END IF;

  SELECT host_id,status INTO v_host_id,v_status
  FROM public.rooms
  WHERE id=p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Room not found' USING errcode='P0002';
  END IF;

  IF v_status NOT IN ('waiting','finished') THEN
    RAISE EXCEPTION 'Cannot leave a game while it is in progress' USING errcode='55000';
  END IF;

  IF NOT EXISTS(
    SELECT 1 FROM public.room_members
    WHERE room_id=p_room_id AND user_id=v_user_id
  ) THEN
    RAISE EXCEPTION 'You are not a member of this room' USING errcode='42501';
  END IF;

  IF v_status='finished' THEN
    DELETE FROM public.room_members
    WHERE room_id=p_room_id AND user_id=v_user_id;
    RETURN jsonb_build_object('deleted_room',false,'left_finished_room',true);
  END IF;

  SELECT count(*) INTO v_members
  FROM public.room_members
  WHERE room_id=p_room_id;

  IF v_host_id=v_user_id AND v_members>1 THEN
    RAISE EXCEPTION 'Host cannot leave while other players remain. Ask everyone to leave first.' USING errcode='55000';
  END IF;

  IF v_host_id=v_user_id THEN
    DELETE FROM public.rooms WHERE id=p_room_id;
    RETURN jsonb_build_object('deleted_room',true,'left_finished_room',false);
  END IF;

  DELETE FROM public.room_members
  WHERE room_id=p_room_id AND user_id=v_user_id;

  RETURN jsonb_build_object('deleted_room',false,'left_finished_room',false);
END;
$function$


CREATE OR REPLACE FUNCTION public.leave_room(p_room_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select private.leave_room_impl(p_room_id);
$function$



-- Explicitly deny direct browser table access to the hidden deck store.
REVOKE ALL PRIVILEGES ON TABLE private.game_engine_secrets FROM PUBLIC,anon,authenticated;

-- Only authenticated room users can invoke the public game API.
GRANT USAGE ON SCHEMA private TO authenticated;

REVOKE ALL ON FUNCTION private.change_player_share(jsonb,uuid,text,integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.apply_price_delta(jsonb,jsonb,text,integer,boolean,integer) FROM PUBLIC,anon,authenticated;

REVOKE ALL ON FUNCTION private.start_game_impl(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.start_game_impl(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.start_game(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.start_game(uuid) TO authenticated;

REVOKE ALL ON FUNCTION private.get_game_view_impl(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.get_game_view_impl(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_game_view(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_game_view(uuid) TO authenticated;

REVOKE ALL ON FUNCTION private.submit_bid_impl(uuid,integer) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.submit_bid_v2_impl(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.submit_bid_impl(uuid,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION private.submit_bid_v2_impl(uuid,integer) TO authenticated;
REVOKE ALL ON FUNCTION public.submit_bid(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.submit_bid(uuid,integer) TO authenticated;

REVOKE ALL ON FUNCTION private.perform_action_card_impl(uuid,text,text,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.perform_action_card_v2_impl(uuid,text,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.perform_action_card_impl(uuid,text,text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION private.perform_action_card_v2_impl(uuid,text,text,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.perform_action_card(uuid,text,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.perform_action_card(uuid,text,text,jsonb) TO authenticated;

REVOKE ALL ON FUNCTION private.complete_sell_turn_impl(uuid,text,integer) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.complete_sell_turn_v2_impl(uuid,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.complete_sell_turn_impl(uuid,text,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION private.complete_sell_turn_v2_impl(uuid,text,integer) TO authenticated;
REVOKE ALL ON FUNCTION public.complete_sell_turn(uuid,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.complete_sell_turn(uuid,text,integer) TO authenticated;

REVOKE ALL ON FUNCTION private.resolve_economy_v4_impl(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.resolve_economy_v4_impl(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.resolve_economy(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.resolve_economy(uuid) TO authenticated;

REVOKE ALL ON FUNCTION private.take_debt_impl(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.take_debt_impl(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.take_debt(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.take_debt(uuid,text) TO authenticated;

REVOKE ALL ON FUNCTION private.leave_room_impl(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.leave_room_impl(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.leave_room(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.leave_room(uuid) TO authenticated;
