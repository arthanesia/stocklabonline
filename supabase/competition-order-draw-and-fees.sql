-- Align the digital game with the I-VEST StockLab competition booklet.
-- Run after game-engine.sql, room-passwords.sql, room-game-settings.sql,
-- tabletop-activity-feed.sql and rumor-price-boundaries.sql.

DO $patch$
DECLARE
  v_def text;
BEGIN
  -- A. Start with one shuffled, face-down order card per player.
  SELECT pg_get_functiondef('private.start_game_impl(uuid)'::regprocedure) INTO v_def;
  v_def := replace(v_def,
    '  v_mutual_fund_pair jsonb;' || E'\nBEGIN',
    '  v_mutual_fund_pair jsonb;' || E'\n  v_order_cards jsonb;' || E'\nBEGIN');
  v_def := replace(v_def,
    '  v_state := jsonb_build_object(',
    '  SELECT jsonb_agg(jsonb_build_object(''id'',''order-card-''||n::text,''number'',n::integer,''picked_by'',NULL) ORDER BY random())' || E'\n' ||
    '  INTO v_order_cards FROM generate_series(1,v_player_count) AS n;' || E'\n\n' ||
    '  v_state := jsonb_build_object(');
  v_def := replace(v_def,
    '''phase_status'',''awaiting_bids'',' || E'\n    ' || '''players'',v_players,',
    '''phase_status'',''awaiting_order_picks'',' || E'\n    ' || '''order_cards'',v_order_cards,' || E'\n    ' || '''players'',v_players,');
  v_def := replace(v_def, 'v_player_count NOT BETWEEN 2 AND 5', 'v_player_count NOT BETWEEN 3 AND 5');
  IF position('v_order_cards jsonb' in v_def)=0
     OR position('awaiting_order_picks' in v_def)=0
     OR position('order_cards'',v_order_cards' in v_def)=0
     OR position('v_player_count NOT BETWEEN 3 AND 5' in v_def)=0 THEN
    RAISE EXCEPTION 'start_game_impl patch incomplete';
  END IF;
  EXECUTE v_def;

  -- B. New rooms also follow the 3–5 player table size.
  SELECT pg_get_functiondef('private.create_room_impl(text,integer,text,integer,integer,integer)'::regprocedure) INTO v_def;
  v_def := replace(v_def, 'p_max_players NOT BETWEEN 2 AND 5', 'p_max_players NOT BETWEEN 3 AND 5');
  v_def := replace(v_def, 'Room capacity must be between 2 and 5', 'Room capacity must be between 3 and 5');
  IF position('p_max_players NOT BETWEEN 3 AND 5' in v_def)=0 THEN
    RAISE EXCEPTION 'create_room_impl patch incomplete';
  END IF;
  EXECUTE v_def;

  -- C. Do not disclose unpicked order-card numbers through the shared game view.
  SELECT pg_get_functiondef('private.get_game_view_impl(uuid)'::regprocedure) INTO v_def;
  v_def := replace(v_def,
    '  v_bid integer; v_bid_count integer; v_player_count integer; v_submitted boolean;',
    '  v_bid integer; v_bid_count integer; v_player_count integer; v_submitted boolean;' || E'\n' ||
    '  v_view_state jsonb; v_view_players jsonb; v_view_cards jsonb;');
  v_def := replace(v_def,
    '  RETURN jsonb_build_object(',
    '  v_view_state:=v_game.state;' || E'\n' ||
    '  IF v_game.state->>''phase_status''=''awaiting_order_picks'' THEN' || E'\n' ||
    '    SELECT coalesce(jsonb_agg(CASE WHEN x.card->>''picked_by'' IS NULL' || E'\n' ||
    '      THEN jsonb_build_object(''id'',x.card->>''id'',''picked_by'',NULL)' || E'\n' ||
    '      ELSE x.card END ORDER BY x.ord),''[]''::jsonb)' || E'\n' ||
    '    INTO v_view_cards FROM jsonb_array_elements(v_game.state->''order_cards'') WITH ORDINALITY AS x(card,ord);' || E'\n' ||
    '    v_view_state:=jsonb_set(v_view_state,''{order_cards}'',v_view_cards,true);' || E'\n' ||
    '    SELECT coalesce(jsonb_agg(CASE WHEN coalesce(p.value->>''order_card_id'','''')<>'''' THEN p.value' || E'\n' ||
    '      ELSE jsonb_set(p.value,''{order_no}'',''null''::jsonb,true) END ORDER BY p.ord),''[]''::jsonb)' || E'\n' ||
    '    INTO v_view_players FROM jsonb_array_elements(v_game.state->''players'') WITH ORDINALITY AS p(value,ord);' || E'\n' ||
    '    v_view_state:=jsonb_set(v_view_state,''{players}'',v_view_players,true);' || E'\n' ||
    '  END IF;' || E'\n' ||
    '  RETURN jsonb_build_object(');
  v_def := replace(v_def, '''state'',v_game.state,', '''state'',v_view_state,');
  IF position('v_view_state' in v_def)=0 OR position('awaiting_order_picks' in v_def)=0 THEN
    RAISE EXCEPTION 'get_game_view_impl patch incomplete';
  END IF;
  EXECUTE v_def;

  -- D. Keep/activate Trading Fee charges only the printed sector.
  SELECT pg_get_functiondef('private.perform_action_card_impl(uuid,text,text,jsonb)'::regprocedure) INTO v_def;
  v_def := replace(v_def,
$old$  IF p_mode='keep' THEN
    IF v_sector NOT IN ('finance','consumer','agriculture','mining','mutual_fund') THEN
      RAISE EXCEPTION 'Card cannot be kept as an investment unit' USING errcode='22023';
    END IF;
    v_players:=private.change_player_share(v_players,v_user_id,v_sector,1);
  ELSE$old$,
$new$  IF p_mode='keep' THEN
    IF v_sector NOT IN ('finance','consumer','agriculture','mining','mutual_fund') THEN
      RAISE EXCEPTION 'Card cannot be kept as an investment unit' USING errcode='22023';
    END IF;
    IF v_action='trading-fee' THEN
      v_fee:=coalesce((v_player->'shares'->>v_sector)::integer,0)+1;
      IF v_coins<v_fee THEN
        RAISE EXCEPTION 'Saldo tidak cukup untuk menyimpan Trading Fee. Pajak sektor % adalah % koin; saldo kamu % koin.',
          v_sector,v_fee,v_coins USING errcode='22023';
      END IF;
      v_private:=jsonb_set(v_private,'{coins}',to_jsonb(v_coins-v_fee),true);
    END IF;
    v_players:=private.change_player_share(v_players,v_user_id,v_sector,1);
  ELSE$new$);
  v_def := replace(v_def,
$old$        IF v_sector='mutual_fund' THEN
          v_fee:=coalesce((v_player->'shares'->>'mutual_fund')::integer,0);
        ELSE
          v_fee:=
            coalesce((v_player->'shares'->>'finance')::integer,0)+
            coalesce((v_player->'shares'->>'consumer')::integer,0)+
            coalesce((v_player->'shares'->>'agriculture')::integer,0)+
            coalesce((v_player->'shares'->>'mining')::integer,0);
        END IF;$old$,
$new$        v_fee:=coalesce((v_player->'shares'->>v_sector)::integer,0);$new$);
  v_def := replace(v_def,
    'v_target_id:=(v_choice->>''target_user_id'')::uuid;',
    'v_target_id:=nullif(btrim(v_choice->>''target_user_id''),'''')::uuid;');
  v_def := replace(v_def,
$old$        IF v_target_shares<1 OR v_actor_shares<v_target_shares THEN
          RAISE EXCEPTION 'Your holdings must be at least as large as the target holdings' USING errcode='22023';
        END IF;$old$,
$new$        IF v_target_shares<1 OR v_actor_shares<v_target_shares THEN
          RAISE EXCEPTION 'Akuisisi gagal. Target memegang % saham, kamu memegang %. Jumlah yang sama diperbolehkan.',
            v_target_shares,v_actor_shares USING errcode='22023';
        END IF;$new$);
  IF position('v_coins-v_fee' in v_def)=0 OR
     position('v_fee:=coalesce((v_player->''shares''->>v_sector)::integer,0)' in v_def)=0 OR
     position('Jumlah yang sama diperbolehkan' in v_def)=0 THEN
    RAISE EXCEPTION 'perform_action_card_impl patch incomplete';
  END IF;
  EXECUTE v_def;

  -- E. Mutual Fund cannot be sold in the normal sell phase.
  SELECT pg_get_functiondef('private.complete_sell_turn_impl(uuid,text,integer)'::regprocedure) INTO v_def;
  v_def := replace(v_def,
    'p_sector NOT IN (''finance'',''consumer'',''agriculture'',''mining'',''mutual_fund'')',
    'p_sector NOT IN (''finance'',''consumer'',''agriculture'',''mining'')');
  v_def := replace(v_def,
$old$    IF p_sector='mutual_fund' THEN
      v_pair:=coalesce(v_state->'mutual_fund_pair',jsonb_build_array('consumer','agriculture'));
      v_price:=floor((
        (v_state->'market'->>(v_pair->>0))::numeric+
        (v_state->'market'->>(v_pair->>1))::numeric
      )/2)::integer;
    ELSE
      v_price:=(v_state->'market'->>p_sector)::integer;
    END IF;$old$,
$new$    v_price:=(v_state->'market'->>p_sector)::integer;$new$);
  IF position('p_sector NOT IN (''finance'',''consumer'',''agriculture'',''mining'')' in v_def)=0
     OR position('IF p_sector=''mutual_fund'' THEN' in v_def)>0 THEN
    RAISE EXCEPTION 'complete_sell_turn_impl patch incomplete';
  END IF;
  EXECUTE v_def;
END
$patch$;

-- F. Pick one face-down card. Selection is serialized by locking the game row.
CREATE OR REPLACE FUNCTION private.choose_order_card_impl(p_room_id uuid, p_card_id text)
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
  v_player jsonb;
  v_players jsonb;
  v_cards jsonb;
  v_order_no integer;
  v_picked_count integer;
  v_player_count integer;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING errcode='28000';
  END IF;
  SELECT * INTO v_game FROM public.games WHERE room_id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Game not found' USING errcode='P0002'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.room_members WHERE room_id=p_room_id AND user_id=v_user_id) THEN
    RAISE EXCEPTION 'Not a room member' USING errcode='42501';
  END IF;
  IF v_game.phase<>'bidding' OR v_game.state->>'phase_status'<>'awaiting_order_picks' THEN
    RAISE EXCEPTION 'Order-card draw is not open' USING errcode='55000';
  END IF;
  SELECT value INTO v_player
  FROM jsonb_array_elements(v_game.state->'players') AS p(value)
  WHERE value->>'user_id'=v_user_id::text;
  IF v_player IS NULL THEN RAISE EXCEPTION 'Player is not in this game' USING errcode='42501'; END IF;
  IF coalesce(v_player->>'order_card_id','')<>'' THEN
    RAISE EXCEPTION 'Kamu sudah mengambil kartu urutan.' USING errcode='55000';
  END IF;
  SELECT value INTO v_card
  FROM jsonb_array_elements(v_game.state->'order_cards') AS c(value)
  WHERE value->>'id'=p_card_id;
  IF v_card IS NULL THEN RAISE EXCEPTION 'Kartu urutan tidak ditemukan.' USING errcode='P0002'; END IF;
  IF v_card->>'picked_by' IS NOT NULL THEN
    RAISE EXCEPTION 'Kartu urutan itu sudah diambil pemain lain.' USING errcode='55000';
  END IF;
  v_order_no:=(v_card->>'number')::integer;
  v_player_count:=jsonb_array_length(v_game.state->'players');
  IF v_order_no NOT BETWEEN 1 AND v_player_count THEN
    RAISE EXCEPTION 'Nomor kartu urutan tidak valid.' USING errcode='22023';
  END IF;

  SELECT coalesce(jsonb_agg(
    CASE WHEN p.value->>'user_id'=v_user_id::text THEN
      jsonb_set(
        jsonb_set(p.value,'{order_no}',to_jsonb(v_order_no),true),
        '{order_card_id}',to_jsonb(p_card_id),true
      )
    ELSE p.value END ORDER BY p.ord
  ),'[]'::jsonb) INTO v_players
  FROM jsonb_array_elements(v_game.state->'players') WITH ORDINALITY AS p(value,ord);

  SELECT coalesce(jsonb_agg(
    CASE WHEN c.value->>'id'=p_card_id THEN
      jsonb_set(c.value,'{picked_by}',to_jsonb(v_user_id::text),true)
    ELSE c.value END ORDER BY c.ord
  ),'[]'::jsonb) INTO v_cards
  FROM jsonb_array_elements(v_game.state->'order_cards') WITH ORDINALITY AS c(value,ord);

  SELECT count(*)::integer INTO v_picked_count
  FROM jsonb_array_elements(v_cards) AS c(value)
  WHERE value->>'picked_by' IS NOT NULL;
  v_state:=jsonb_set(v_game.state,'{players}',v_players,true);
  v_state:=jsonb_set(v_state,'{order_cards}',v_cards,true);
  IF v_picked_count>=v_player_count THEN
    v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('awaiting_bids'::text),true);
  END IF;
  v_state:=jsonb_set(v_state,'{history}',
    coalesce(v_state->'history','[]'::jsonb)||
    jsonb_build_array(jsonb_build_object('type','order_card_revealed','round',v_game.current_round,
      'user_id',v_user_id,'order_no',v_order_no,'at',now())),true);
  UPDATE public.games
  SET state=v_state,version=version+1,updated_at=now()
  WHERE id=v_game.id;
  INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
  VALUES(v_game.id,v_user_id,'order_card_revealed',jsonb_build_object(
    'card_id',p_card_id,'order_no',v_order_no,
    'picked_count',v_picked_count,'player_count',v_player_count
  ));
  RETURN jsonb_build_object('ok',true,'order_no',v_order_no,
    'picked_count',v_picked_count,'player_count',v_player_count,
    'phase_status',v_state->>'phase_status');
END;
$function$;

CREATE OR REPLACE FUNCTION public.choose_order_card(p_room_id uuid, p_card_id text)
RETURNS jsonb
LANGUAGE sql
SET search_path TO ''
AS $function$
  SELECT private.choose_order_card_impl(p_room_id,p_card_id);
$function$;


-- G. Reconcile the opening action-card market with the competition's reshuffle rules.
DO $market_patch$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('private.start_game_impl(uuid)'::regprocedure) INTO v_def;
  v_def:=replace(v_def,'Room needs 2 to 5 players','Room needs 3 to 5 players');
  EXECUTE v_def;

  SELECT pg_get_functiondef('private.submit_bid_impl(uuid,integer)'::regprocedure) INTO v_def;
  v_def:=replace(v_def,
    '  v_card_count integer; v_first_user uuid;',
    '  v_card_count integer; v_first_user uuid; v_attempt integer; v_violates boolean; v_same_type boolean;');
  v_def:=replace(v_def,
$old$  SELECT coalesce(jsonb_agg(x.card ORDER BY x.ord),'[]'::jsonb) INTO v_market
  FROM jsonb_array_elements(v_secret.action_deck) WITH ORDINALITY AS x(card,ord)
  WHERE x.ord<=v_card_count;
  SELECT coalesce(jsonb_agg(x.card ORDER BY x.ord),'[]'::jsonb) INTO v_remaining_deck
  FROM jsonb_array_elements(v_secret.action_deck) WITH ORDINALITY AS x(card,ord)
  WHERE x.ord>v_card_count;
  IF jsonb_array_length(v_market)<>v_card_count THEN
    RAISE EXCEPTION 'Action deck is exhausted' USING errcode='55000';
  END IF;$old$,
$new$  IF jsonb_array_length(v_secret.action_deck)<v_card_count THEN
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
  WHERE x.ord>v_card_count;$new$);
  IF position('v_attempt integer' in v_def)=0
     OR position('Could not draw a valid opening action market' in v_def)=0
     OR position('GROUP BY x.card->>''sector'',x.card->>''action''' in v_def)=0 THEN
    RAISE EXCEPTION 'submit_bid_impl reshuffle patch incomplete';
  END IF;
  EXECUTE v_def;
END
$market_patch$;


-- H. Trading Fee may sell ordinary sector shares only, never Mutual Fund before endgame.
DO $trading_fee_sale_guard$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef('private.perform_action_card_impl(uuid,text,text,jsonb)'::regprocedure) INTO v_def;
  v_def:=replace(v_def,
    'v_sell_sector NOT IN (''finance'',''consumer'',''agriculture'',''mining'',''mutual_fund'')',
    'v_sell_sector NOT IN (''finance'',''consumer'',''agriculture'',''mining'')');
  v_def:=replace(v_def,
$old$        IF v_sell_sector='mutual_fund' THEN
          v_pair:=coalesce(v_state->'mutual_fund_pair',jsonb_build_array('consumer','agriculture'));
          v_sale_price:=floor((
            (v_market->>(v_pair->>0))::numeric+(v_market->>(v_pair->>1))::numeric
          )/2)::integer;
        ELSE
          v_sale_price:=(v_market->>v_sell_sector)::integer;
        END IF;$old$,
$new$        v_sale_price:=(v_market->>v_sell_sector)::integer;$new$);
  v_def:=replace(v_def,
    'Bayar 1 koin untuk setiap saham sektor yang kamu miliki, lalu jual satu jenis saham atau Reksa Dana.',
    'Bayar 1 koin untuk setiap saham pada sektor kartu yang kamu miliki, lalu jual satu jenis saham sektor.');
  v_def:=replace(v_def,
    'Bayar 1 koin per unit Reksa Dana yang dimiliki, lalu jual satu jenis saham atau Reksa Dana.',
    'Bayar 1 koin per unit Reksa Dana yang kamu miliki, lalu jual satu jenis saham sektor.');
  IF position('v_sell_sector NOT IN (''finance'',''consumer'',''agriculture'',''mining'')' in v_def)=0
     OR position('IF v_sell_sector=''mutual_fund'' THEN' in v_def)>0 THEN
    RAISE EXCEPTION 'Trading Fee Mutual Fund sell guard patch incomplete';
  END IF;
  EXECUTE v_def;

  SELECT pg_get_functiondef('private.start_game_impl(uuid)'::regprocedure) INTO v_def;
  v_def:=replace(v_def,'Room needs 2 to 5 players','Room needs 3 to 5 players');
  v_def:=replace(v_def,
    'Bayar 1 koin untuk setiap saham sektor yang kamu miliki, lalu jual satu jenis saham atau Reksa Dana.',
    'Bayar 1 koin untuk setiap saham pada sektor kartu yang kamu miliki, lalu jual satu jenis saham sektor.');
  v_def:=replace(v_def,
    'Bayar 1 koin per unit Reksa Dana yang dimiliki, lalu jual satu jenis saham atau Reksa Dana.',
    'Bayar 1 koin per unit Reksa Dana yang kamu miliki, lalu jual satu jenis saham sektor.');
  EXECUTE v_def;
END
$trading_fee_sale_guard$;
