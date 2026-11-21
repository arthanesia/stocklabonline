-- Info Bursa now reveals exactly two selected sectors to the acting player.
-- Peek card payloads remain in private game state and are never copied to shared state.
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
  v_quickbuy_skip_ids jsonb;
  v_skip_count integer:=0;
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
    IF v_action='trading-fee' THEN
      -- The saved Trading Fee card becomes one more unit in its printed sector.
      v_fee:=coalesce((v_player->'shares'->>v_sector)::integer,0)+1;
      IF v_coins<v_fee THEN
        RAISE EXCEPTION 'Saldo tidak cukup untuk menyimpan Trading Fee. Pajak sektor % adalah % koin; saldo kamu % koin.',
          v_sector,v_fee,v_coins USING errcode='22023';
      END IF;
      v_private:=jsonb_set(v_private,'{coins}',to_jsonb(v_coins-v_fee),true);
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
        IF v_s1 NOT IN ('finance','consumer','agriculture','mining')
          OR v_s2 NOT IN ('finance','consumer','agriculture','mining')
          OR v_s1=v_s2 THEN
          RAISE EXCEPTION 'Pilih tepat dua sektor saham yang berbeda untuk diintip.' USING errcode='22023';
        END IF;
        SELECT * INTO v_secret FROM private.game_engine_secrets WHERE game_id=v_game.id;
        v_private:=jsonb_set(v_private,'{peek}',jsonb_build_array(
          jsonb_build_object('sector',v_s1,'card',v_secret.economy_stacks->v_s1->0),
          jsonb_build_object('sector',v_s2,'card',v_secret.economy_stacks->v_s2->0)
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

          IF (coalesce((v_market->>v_s1)::integer,5)+v_delta)<1
             OR (coalesce((v_market->>v_s1)::integer,5)+v_delta)>9 THEN
            RAISE EXCEPTION 'Rumor tidak dapat menggeser sektor % sebesar % poin dari harga %; batas harga adalah 1–9.',
              v_s1,v_delta,coalesce((v_market->>v_s1)::integer,5)
              USING errcode='22023';
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

          IF (coalesce((v_market->>v_s1)::integer,5)+v_delta)<1
             OR (coalesce((v_market->>v_s1)::integer,5)+v_delta)>9 THEN
            RAISE EXCEPTION 'Rumor tidak dapat menggeser sektor % sebesar % poin dari harga %; batas harga adalah 1–9.',
              v_s1,v_delta,coalesce((v_market->>v_s1)::integer,5)
              USING errcode='22023';
          END IF;
          v_price_change:=private.apply_price_delta(v_players,v_market,v_s1,v_delta,false,v_split_remaining);
          v_players:=v_price_change->'players';
          v_market:=v_price_change->'market';
          v_delta:=(v_choice->>'delta_b')::integer;
          IF v_delta NOT IN (-1,1) THEN RAISE EXCEPTION 'Each Rumor move must be +1 or -1' USING errcode='22023'; END IF;

          IF (coalesce((v_market->>v_s2)::integer,5)+v_delta)<1
             OR (coalesce((v_market->>v_s2)::integer,5)+v_delta)>9 THEN
            RAISE EXCEPTION 'Rumor tidak dapat menggeser sektor % sebesar % poin dari harga %; batas harga adalah 1–9.',
              v_s2,v_delta,coalesce((v_market->>v_s2)::integer,5)
              USING errcode='22023';
          END IF;
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
        IF v_sell_sector NOT IN ('finance','consumer','agriculture','mining')
          OR v_quantity IS NULL OR v_quantity<1 THEN
          RAISE EXCEPTION 'Choose a share type and quantity to sell' USING errcode='22023';
        END IF;
        SELECT value INTO v_player
        FROM jsonb_array_elements(v_players) AS p(value)
        WHERE value->>'user_id'=v_user_id::text;
        IF v_quantity>coalesce((v_player->'shares'->>v_sell_sector)::integer,0) THEN
          RAISE EXCEPTION 'You do not own that many units' USING errcode='22023';
        END IF;
        v_sale_price:=(v_market->>v_sell_sector)::integer;
        v_players:=private.change_player_share(v_players,v_user_id,v_sell_sector,-v_quantity);
        v_private:=jsonb_set(v_private,'{coins}',to_jsonb(v_coins-v_fee+v_quantity*v_sale_price),true);

      WHEN 'acquisition' THEN
        v_target_id:=nullif(btrim(v_choice->>'target_user_id'),'')::uuid;
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
          RAISE EXCEPTION 'Akuisisi gagal. Target memegang % saham, kamu memegang %. Jumlah yang sama diperbolehkan.',
            v_target_shares,v_actor_shares USING errcode='22023';
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

  -- Quickbuy consumes two extra cards. If cards remain, the activator forfeits
  -- their next scheduled pick; the turn advances to the next eligible player.
  IF v_action='quickbuy' AND jsonb_array_length(v_remaining_cards)>0 THEN
    v_quickbuy_skip_ids:=coalesce(v_state->'quickbuy_skip_user_ids','[]'::jsonb);
    IF NOT (v_quickbuy_skip_ids ? v_user_id::text) THEN
      v_quickbuy_skip_ids:=v_quickbuy_skip_ids||jsonb_build_array(v_user_id::text);
      v_state:=jsonb_set(v_state,'{quickbuy_skip_user_ids}',v_quickbuy_skip_ids,true);
    END IF;
  END IF;

  IF jsonb_array_length(v_remaining_cards)=0 THEN
    SELECT value->>'user_id' INTO v_next_user
    FROM jsonb_array_elements(v_players) AS p(value)
    WHERE (value->>'order_no')::integer=1;
    v_state:=jsonb_set(v_state,'{quickbuy_skip_user_ids}','[]'::jsonb,true);
    v_state:=jsonb_set(v_state,'{phase_status}',to_jsonb('selling'::text),true);
    v_state:=jsonb_set(v_state,'{sell_turn_index}',to_jsonb(0),true);
    UPDATE public.games SET phase='sell',active_user_id=v_next_user,state=v_state,
      version=version+1,updated_at=now() WHERE id=v_game.id;
  ELSE
    LOOP
      SELECT value->>'user_id' INTO v_next_user
      FROM jsonb_array_elements(v_players) AS p(value)
      WHERE (value->>'order_no')::integer=((v_next_index%v_player_count)+1);
      EXIT WHEN v_next_user IS NULL;
      EXIT WHEN NOT (coalesce(v_state->'quickbuy_skip_user_ids','[]'::jsonb) ? v_next_user::text);

      SELECT coalesce(jsonb_agg(x.value ORDER BY x.ord),'[]'::jsonb)
      INTO v_quickbuy_skip_ids
      FROM jsonb_array_elements(coalesce(v_state->'quickbuy_skip_user_ids','[]'::jsonb))
        WITH ORDINALITY AS x(value,ord)
      WHERE x.value#>>'{}'<>v_next_user::text;
      v_state:=jsonb_set(v_state,'{quickbuy_skip_user_ids}',v_quickbuy_skip_ids,true);
      v_next_index:=v_next_index+1;
      v_skip_count:=v_skip_count+1;
      EXIT WHEN v_skip_count>=v_player_count;
    END LOOP;

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
    'card_id',p_card_id,
    'card_title',v_card->>'title',
    'mode',p_mode,
    'action',v_action,
    'sector',v_sector,
    'choice',CASE WHEN p_mode='activate' THEN p_choice ELSE '{}'::jsonb END,
    'fee_paid',CASE WHEN v_action='trading-fee' THEN v_fee ELSE NULL END,
    'fee_units',CASE WHEN v_action='trading-fee' THEN v_fee ELSE NULL END,
    'sell_sector',CASE WHEN v_action='trading-fee' THEN v_sell_sector ELSE NULL END,
    'sell_quantity',CASE WHEN v_action='trading-fee' THEN v_quantity ELSE NULL END,
    'sale_unit_price',CASE WHEN v_action='trading-fee' THEN v_sale_price ELSE NULL END,
    'sale_proceeds',CASE WHEN v_action='trading-fee' THEN v_quantity*v_sale_price ELSE NULL END,
    'target_user_id',CASE WHEN v_action='acquisition' THEN v_target_id::text ELSE NULL END,
    'target_display_name',CASE WHEN v_action='acquisition' THEN v_target_player->>'display_name' ELSE NULL END,
    'target_sector',CASE WHEN v_action='acquisition' THEN v_target_sector ELSE NULL END,
    'quickbuy_cards',(
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'title',x.card->>'title','sector',x.card->>'sector'
      ) ORDER BY x.ord),'[]'::jsonb)
      FROM jsonb_array_elements(coalesce(v_game.state->'action_market','[]'::jsonb))
        WITH ORDINALITY AS x(card,ord)
      WHERE x.card->>'id'=ANY(v_extra_ids)
    ),
    'skipped_next_turn',v_action='quickbuy' AND jsonb_array_length(v_remaining_cards)>0,
    'price_changes',(
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'sector',p.key,
        'old_price',(v_game.state->'market'->>p.key)::integer,
        'new_price',(p.value#>>'{}')::integer
      ) ORDER BY p.key),'[]'::jsonb)
      FROM jsonb_each(coalesce(v_market,'{}'::jsonb)) AS p(key,value)
      WHERE (v_game.state->'market'->>p.key)::integer
        IS DISTINCT FROM (p.value#>>'{}')::integer
    )
  ));
  RETURN jsonb_build_object(
    'ok',true,'remaining_action_cards',jsonb_array_length(v_remaining_cards),
    'next_active_user_id',v_next_user,
    'phase',CASE WHEN jsonb_array_length(v_remaining_cards)=0 THEN 'sell' ELSE 'action' END
  );
END;
$function$;

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
      'sectors',jsonb_build_array(p_choice->>'sector_a',p_choice->>'sector_b')
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
$function$;
