CREATE OR REPLACE FUNCTION private.prepare_action_market_impl(p_game_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_state jsonb; v_secret private.game_engine_secrets%rowtype;
 v_player_count integer; v_card_count integer; v_current_count integer;
 v_market jsonb; v_remaining_deck jsonb; v_attempt integer:=0;
 v_violates boolean; v_same_type boolean;
BEGIN
 SELECT state INTO v_state FROM public.games WHERE id=p_game_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Game not found' USING errcode='P0002'; END IF;
 v_player_count:=jsonb_array_length(coalesce(v_state->'players','[]'::jsonb));
 v_card_count:=v_player_count*2;
 IF v_player_count NOT BETWEEN 3 AND 5 THEN RAISE EXCEPTION 'Game needs 3 to 5 players' USING errcode='22023'; END IF;
 v_current_count:=jsonb_array_length(coalesce(v_state->'action_market','[]'::jsonb));
 IF v_current_count=v_card_count THEN RETURN v_state->'action_market'; END IF;
 IF v_current_count>0 THEN RAISE EXCEPTION 'Action market is partially prepared (% of % cards)',v_current_count,v_card_count USING errcode='55000'; END IF;
 SELECT * INTO v_secret FROM private.game_engine_secrets WHERE game_id=p_game_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Game deck is missing' USING errcode='P0002'; END IF;
 IF jsonb_array_length(coalesce(v_secret.action_deck,'[]'::jsonb))<v_card_count THEN RAISE EXCEPTION 'Action deck is exhausted' USING errcode='55000'; END IF;
 LOOP
  v_attempt:=v_attempt+1;
  SELECT coalesce(jsonb_agg(x.card ORDER BY x.ord),'[]'::jsonb) INTO v_market
  FROM jsonb_array_elements(v_secret.action_deck) WITH ORDINALITY AS x(card,ord) WHERE x.ord<=v_card_count;
  SELECT count(*) FILTER(WHERE x.card->>'action'='quickbuy')>=3 INTO v_violates
  FROM jsonb_array_elements(v_market) AS x(card);
  v_violates:=coalesce(v_violates,false);
  IF v_player_count IN (4,5) THEN
   SELECT EXISTS(
    SELECT 1 FROM jsonb_array_elements(v_market) AS x(card)
    GROUP BY x.card->>'sector',x.card->>'action' HAVING count(*)>=v_player_count
   ) INTO v_same_type;
   v_violates:=v_violates OR coalesce(v_same_type,false);
  END IF;
  EXIT WHEN NOT v_violates;
  IF v_attempt>=100 THEN RAISE EXCEPTION 'Could not draw a valid action market after 100 shuffles' USING errcode='55000'; END IF;
  SELECT coalesce(jsonb_agg(x.card ORDER BY random()),'[]'::jsonb) INTO v_secret.action_deck
  FROM jsonb_array_elements(v_secret.action_deck) AS x(card);
 END LOOP;
 SELECT coalesce(jsonb_agg(x.card ORDER BY x.ord),'[]'::jsonb) INTO v_remaining_deck
 FROM jsonb_array_elements(v_secret.action_deck) WITH ORDINALITY AS x(card,ord) WHERE x.ord>v_card_count;
 UPDATE private.game_engine_secrets SET action_deck=v_remaining_deck,updated_at=now() WHERE game_id=p_game_id;
 RETURN v_market;
END;
$function$
;

REVOKE ALL ON FUNCTION private.prepare_action_market_impl(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.resolve_bidding_impl(p_room_id uuid, p_actor_id uuid DEFAULT NULL::uuid, p_was_timeout boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_game public.games%rowtype; v_room public.rooms%rowtype; v_state jsonb;
 v_players jsonb; v_order_cards jsonb; v_results jsonb;
 v_player_count integer; v_submitted_count integer; v_market_count integer;
 v_first_user uuid; v_auto_ids jsonb;
BEGIN
 SELECT * INTO v_game FROM public.games WHERE room_id=p_room_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Game not found' USING errcode='P0002'; END IF;
 IF v_game.phase<>'bidding' OR v_game.state->>'phase_status' NOT IN ('awaiting_bids','collecting_bids') THEN
  RAISE EXCEPTION 'Bidding is not open' USING errcode='55000';
 END IF;
 v_state:=v_game.state;
 v_player_count:=jsonb_array_length(coalesce(v_state->'players','[]'::jsonb));
 v_market_count:=jsonb_array_length(coalesce(v_state->'action_market','[]'::jsonb));
 IF v_market_count<>v_player_count*2 THEN RAISE EXCEPTION 'Action cards must be revealed before bidding (% of % cards available)',v_market_count,v_player_count*2 USING errcode='55000'; END IF;
 SELECT count(*)::integer INTO v_submitted_count FROM public.bidding_submissions
 WHERE game_id=v_game.id AND round_number=v_game.current_round;
 IF v_submitted_count<>v_player_count THEN RAISE EXCEPTION 'Waiting for every player to submit a bid' USING errcode='55000'; END IF;
 IF EXISTS(SELECT 1 FROM public.bidding_submissions WHERE game_id=v_game.id AND round_number=v_game.current_round AND bid_amount<1)
 THEN RAISE EXCEPTION 'Every bid must be at least 1 coin' USING errcode='22023'; END IF;
 UPDATE public.game_private_states gps
 SET private_state=jsonb_set(gps.private_state,'{coins}',to_jsonb(coalesce((gps.private_state->>'coins')::integer,0)-b.bid_amount),true),
     updated_at=now()
 FROM public.bidding_submissions b
 WHERE b.game_id=v_game.id AND b.round_number=v_game.current_round AND gps.game_id=v_game.id AND gps.user_id=b.user_id;
 v_auto_ids:=coalesce(v_state->'bidding_auto_user_ids','[]'::jsonb);
 WITH ranked AS (
  SELECT p.value AS player,b.bid_amount,
   coalesce((p.value->>'order_card_number')::integer,(p.value->>'order_no')::integer) AS previous_card_number,
   row_number() OVER(ORDER BY b.bid_amount DESC,coalesce((p.value->>'order_card_number')::integer,(p.value->>'order_no')::integer) ASC)::integer AS new_order
  FROM jsonb_array_elements(v_state->'players') AS p(value)
  JOIN public.bidding_submissions b ON b.game_id=v_game.id AND b.round_number=v_game.current_round AND b.user_id=(p.value->>'user_id')::uuid
 ), mapped AS (
  SELECT r.*,(SELECT c.value->>'id' FROM jsonb_array_elements(coalesce(v_state->'order_cards','[]'::jsonb)) AS c(value)
    WHERE (c.value->>'number')::integer=r.new_order LIMIT 1) AS new_card_id
  FROM ranked r
 )
 SELECT
  coalesce(jsonb_agg(jsonb_set(jsonb_set(jsonb_set(m.player,'{order_no}',to_jsonb(m.new_order),true),
    '{order_card_number}',to_jsonb(m.new_order),true),
    '{order_card_id}',to_jsonb(coalesce(m.new_card_id,m.player->>'order_card_id')),true) ORDER BY m.new_order),'[]'::jsonb),
  coalesce(jsonb_agg(jsonb_build_object('user_id',m.player->>'user_id','display_name',m.player->>'display_name',
    'bid_amount',m.bid_amount,'previous_order_card_number',m.previous_card_number,
    'order_no',m.new_order,'new_order',m.new_order,'automatic',coalesce(v_auto_ids ? (m.player->>'user_id'),false)
  ) ORDER BY m.new_order),'[]'::jsonb)
 INTO v_players,v_results FROM mapped m;
 SELECT coalesce(jsonb_agg(jsonb_set(c.value,'{picked_by}',to_jsonb(p.value->>'user_id'),true) ORDER BY c.ord),'[]'::jsonb)
 INTO v_order_cards
 FROM jsonb_array_elements(coalesce(v_state->'order_cards','[]'::jsonb)) WITH ORDINALITY AS c(value,ord)
 LEFT JOIN jsonb_array_elements(v_players) AS p(value)
 ON (p.value->>'order_no')::integer=(c.value->>'number')::integer;
 SELECT value->>'user_id' INTO v_first_user FROM jsonb_array_elements(v_players) AS p(value)
 WHERE (value->>'order_no')::integer=1;
 v_state:=jsonb_set(v_state,'{players}',v_players,true);
 v_state:=jsonb_set(v_state,'{order_cards}',v_order_cards,true);
 v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('drafting'::text),true);
 v_state:=jsonb_set(v_state,'{draft_turn_index}',to_jsonb(0),true);
 v_state:=jsonb_set(v_state,'{bidding_results}',v_results,true);
 v_state:=jsonb_set(v_state,'{bidding_auto_user_ids}','[]'::jsonb,true);
 v_state:=jsonb_set(v_state,'{quickbuy_skip_user_ids}','[]'::jsonb,true);
 v_state:=jsonb_set(v_state,'{history}',coalesce(v_state->'history','[]'::jsonb)||
  jsonb_build_array(jsonb_build_object('type',CASE WHEN p_was_timeout THEN 'bids_auto_resolved' ELSE 'bids_revealed' END,
  'round',v_game.current_round,'results',v_results,'at',now())),true);
 SELECT * INTO v_room FROM public.rooms WHERE id=p_room_id;
 UPDATE public.games SET phase='action',active_user_id=v_first_user,
  phase_deadline=now()+make_interval(secs=>coalesce(v_room.turn_seconds,45)),
  state=v_state,version=version+1,updated_at=now() WHERE id=v_game.id;
 INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
 VALUES(v_game.id,p_actor_id,CASE WHEN p_was_timeout THEN 'bids_auto_resolved' ELSE 'bids_revealed' END,
  jsonb_build_object('round',v_game.current_round,'results',v_results,'order_cards',v_order_cards));
 RETURN jsonb_build_object('resolved',true,'phase','action','active_user_id',v_first_user,
  'bidding_results',v_results,'action_market',v_state->'action_market','order_cards',v_order_cards,
  'automatic_timeout',p_was_timeout);
END;
$function$
;

REVOKE ALL ON FUNCTION private.resolve_bidding_impl(uuid,uuid,boolean) FROM PUBLIC,anon,authenticated;

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
  v_market jsonb;
  v_bid_seconds integer;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING errcode='28000';
  END IF;
  SELECT * INTO v_game FROM public.games WHERE room_id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game not found' USING errcode='P0002';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.room_members
    WHERE room_id=p_room_id AND user_id=v_user_id
  ) THEN
    RAISE EXCEPTION 'Not a room member' USING errcode='42501';
  END IF;
  IF v_game.phase<>'bidding' OR v_game.state->>'phase_status'<>'awaiting_order_picks' THEN
    RAISE EXCEPTION 'Order-card draw is not open' USING errcode='55000';
  END IF;
  SELECT value INTO v_player
  FROM jsonb_array_elements(v_game.state->'players') AS p(value)
  WHERE value->>'user_id'=v_user_id::text;
  IF v_player IS NULL THEN
    RAISE EXCEPTION 'Player is not in this game' USING errcode='42501';
  END IF;
  IF coalesce(v_player->>'order_card_id','')<>'' THEN
    RAISE EXCEPTION 'Kamu sudah mengambil kartu urutan.' USING errcode='55000';
  END IF;
  SELECT value INTO v_card
  FROM jsonb_array_elements(v_game.state->'order_cards') AS c(value)
  WHERE value->>'id'=p_card_id;
  IF v_card IS NULL THEN
    RAISE EXCEPTION 'Kartu urutan tidak ditemukan.' USING errcode='P0002';
  END IF;
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
        jsonb_set(
          jsonb_set(p.value,'{order_no}',to_jsonb(v_order_no),true),
          '{order_card_number}',to_jsonb(v_order_no),true
        ),
        '{order_card_id}',to_jsonb(p_card_id),true
      )
    ELSE p.value END ORDER BY p.ord
  ),'[]'::jsonb)
  INTO v_players
  FROM jsonb_array_elements(v_game.state->'players') WITH ORDINALITY AS p(value,ord);

  SELECT coalesce(jsonb_agg(
    CASE WHEN c.value->>'id'=p_card_id THEN
      jsonb_set(c.value,'{picked_by}',to_jsonb(v_user_id::text),true)
    ELSE c.value END ORDER BY c.ord
  ),'[]'::jsonb)
  INTO v_cards
  FROM jsonb_array_elements(v_game.state->'order_cards') WITH ORDINALITY AS c(value,ord);

  SELECT count(*)::integer INTO v_picked_count
  FROM jsonb_array_elements(v_cards) AS c(value)
  WHERE value->>'picked_by' IS NOT NULL;
  v_state:=jsonb_set(v_game.state,'{players}',v_players,true);
  v_state:=jsonb_set(v_state,'{order_cards}',v_cards,true);
  IF v_picked_count>=v_player_count THEN
    v_market:=private.prepare_action_market_impl(v_game.id);
    v_state:=jsonb_set(v_state,'{action_market}',v_market,true);
    v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('awaiting_bids'::text),true);
    v_state:=jsonb_set(v_state,'{bidding_results}','[]'::jsonb,true);
    v_state:=jsonb_set(v_state,'{bidding_auto_user_ids}','[]'::jsonb,true);
    SELECT bidding_seconds INTO v_bid_seconds FROM public.rooms WHERE id=p_room_id;
  END IF;
  v_state:=jsonb_set(v_state,'{history}',
    coalesce(v_state->'history','[]'::jsonb)||
    jsonb_build_array(jsonb_build_object(
      'type','order_card_revealed','round',v_game.current_round,
      'user_id',v_user_id,'order_no',v_order_no,'at',now()
    )),true);
  UPDATE public.games
  SET state=v_state,
      phase_deadline=CASE WHEN v_picked_count>=v_player_count THEN now()+make_interval(secs=>coalesce(v_bid_seconds,90)) ELSE phase_deadline END,
      version=version+1,updated_at=now()
  WHERE id=v_game.id;
  INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
  VALUES(v_game.id,v_user_id,'order_card_revealed',jsonb_build_object(
    'card_id',p_card_id,'order_no',v_order_no,
    'picked_count',v_picked_count,'player_count',v_player_count
  ));
  RETURN jsonb_build_object(
    'ok',true,'order_no',v_order_no,
    'picked_count',v_picked_count,'player_count',v_player_count,
    'phase_status',v_state->>'phase_status'
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION private.submit_bid_impl(p_room_id uuid, p_bid_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_user_id uuid:=auth.uid(); v_game public.games%rowtype; v_private jsonb; v_state jsonb;
 v_coins integer; v_player_count integer; v_submitted_count integer; v_result jsonb;
BEGIN
 IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING errcode='28000'; END IF;
 SELECT * INTO v_game FROM public.games WHERE room_id=p_room_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Game not found' USING errcode='P0002'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.room_members WHERE room_id=p_room_id AND user_id=v_user_id) THEN
  RAISE EXCEPTION 'Not a room member' USING errcode='42501';
 END IF;
 IF v_game.phase<>'bidding' OR v_game.state->>'phase_status' NOT IN ('awaiting_bids','collecting_bids') THEN RAISE EXCEPTION 'Bidding is not open' USING errcode='55000'; END IF;
 IF p_bid_amount IS NULL OR p_bid_amount<1 THEN RAISE EXCEPTION 'Bid must be at least 1 coin' USING errcode='22023'; END IF;
 SELECT private_state INTO v_private FROM public.game_private_states WHERE game_id=v_game.id AND user_id=v_user_id FOR UPDATE;
 v_coins:=coalesce((v_private->>'coins')::integer,0);
 IF p_bid_amount>v_coins THEN RAISE EXCEPTION 'Bid exceeds your available coins' USING errcode='22023'; END IF;
 INSERT INTO public.bidding_submissions(game_id,round_number,user_id,bid_amount,submitted_at)
 VALUES(v_game.id,v_game.current_round,v_user_id,p_bid_amount,now())
 ON CONFLICT(game_id,round_number,user_id) DO UPDATE SET bid_amount=excluded.bid_amount,submitted_at=now();
 SELECT count(*)::integer INTO v_submitted_count FROM public.bidding_submissions
 WHERE game_id=v_game.id AND round_number=v_game.current_round;
 v_player_count:=jsonb_array_length(coalesce(v_game.state->'players','[]'::jsonb));
 v_state:=v_game.state;
 IF v_submitted_count<v_player_count THEN
  v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('collecting_bids'::text),true);
  UPDATE public.games SET state=v_state,version=version+1,updated_at=now() WHERE id=v_game.id;
  RETURN jsonb_build_object('resolved',false,'submitted_count',v_submitted_count,'player_count',v_player_count);
 END IF;
 v_result:=private.resolve_bidding_impl(p_room_id,v_user_id,false);
 RETURN v_result;
END;
$function$
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
  v_action_market jsonb;
  v_economy_remaining jsonb;
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
  v_action_market:=private.prepare_action_market_impl(v_game.id);
  v_economy_remaining:=jsonb_build_object(
    'finance',jsonb_array_length(coalesce(v_stacks->'finance','[]'::jsonb)),
    'consumer',jsonb_array_length(coalesce(v_stacks->'consumer','[]'::jsonb)),
    'agriculture',jsonb_array_length(coalesce(v_stacks->'agriculture','[]'::jsonb)),
    'mining',jsonb_array_length(coalesce(v_stacks->'mining','[]'::jsonb))
  );
  WITH player_debts AS (
    SELECT p.value AS player,coalesce((gps.private_state->>'debt')::integer,0) AS debt_count,
      row_number() OVER (
        PARTITION BY (coalesce((gps.private_state->>'debt')::integer,0)=0)
        ORDER BY (p.value->>'order_no')::integer
      ) AS offer_rank
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
  v_state:=jsonb_set(v_state,'{action_market}',v_action_market,true);
  v_state:=jsonb_set(v_state,'{bidding_results}','[]'::jsonb,true);
  v_state:=jsonb_set(v_state,'{bidding_auto_user_ids}','[]'::jsonb,true);
  v_state:=jsonb_set(v_state,'{info_bursa_public}','[]'::jsonb,true);
  v_state:=jsonb_set(v_state,'{economy_remaining}',v_economy_remaining,true);
  v_state:=jsonb_set(v_state,'{draft_turn_index}',to_jsonb(0),true);
  v_state:=jsonb_set(v_state,'{sell_turn_index}',to_jsonb(0),true);
  UPDATE public.games SET current_round=v_next_round,phase='bidding',active_user_id=NULL,
    phase_deadline=now()+make_interval(secs=>CASE WHEN v_pending_debt_count>0
      THEN coalesce(v_room.turn_seconds,45) ELSE coalesce(v_room.bidding_seconds,90) END),
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
  v_auto_users jsonb;
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
    IF v_state->>'phase_status' NOT IN ('awaiting_bids','collecting_bids') THEN
      RETURN jsonb_build_object('advanced',false,'phase',v_game.phase,'reason','bidding_not_open');
    END IF;
    SELECT coalesce(jsonb_agg(to_jsonb(p.value->>'user_id') ORDER BY p.ord),'[]'::jsonb)
    INTO v_auto_users
    FROM jsonb_array_elements(v_players) WITH ORDINALITY AS p(value,ord)
    WHERE NOT EXISTS(
      SELECT 1 FROM public.bidding_submissions b
      WHERE b.game_id=v_game.id AND b.round_number=v_game.current_round
        AND b.user_id=(p.value->>'user_id')::uuid
    );
    INSERT INTO public.bidding_submissions(game_id,round_number,user_id,bid_amount,submitted_at)
    SELECT v_game.id,v_game.current_round,(p.value->>'user_id')::uuid,1,now()
    FROM jsonb_array_elements(v_players) AS p(value)
    WHERE NOT EXISTS(
      SELECT 1 FROM public.bidding_submissions b
      WHERE b.game_id=v_game.id AND b.round_number=v_game.current_round
        AND b.user_id=(p.value->>'user_id')::uuid
    );
    v_state:=jsonb_set(v_state,'{bidding_auto_user_ids}',v_auto_users,true);
    UPDATE public.games SET state=v_state,version=version+1,updated_at=now() WHERE id=v_game.id;
    v_result:=private.resolve_bidding_impl(p_room_id,NULL,true);
    RETURN jsonb_build_object('advanced',true,'phase','action','reason','bidding_timeout','result',v_result);

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
  v_info_public jsonb;
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
    v_info_public:=coalesce(v_state->'info_bursa_public','[]'::jsonb);
    v_info_public:=v_info_public||jsonb_build_array(jsonb_build_object(
      'user_id',v_user_id::text,'round',v_after.current_round,
      'sectors',jsonb_build_array(p_choice->>'sector_a',p_choice->>'sector_b',p_choice->>'sector_c')
    ));
    v_state:=jsonb_set(v_state,'{info_bursa_public}',v_info_public,true);
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
;