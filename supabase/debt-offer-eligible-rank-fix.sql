-- Correctly rank only players who have not accepted debt when allocating available debt cards.
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
