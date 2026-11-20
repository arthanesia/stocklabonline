create index if not exists game_events_game_created_idx
  on public.game_events (game_id, created_at desc, id desc);

do $patch$
declare
  v_def text;
  v_old text;
  v_new text;
begin
  -- Return the latest public table activity to every room member.
  v_def := pg_get_functiondef('private.get_game_view_impl(uuid)'::regprocedure);
  v_old := $old$
    'bidding',jsonb_build_object(
      'submitted',v_submitted,'my_bid',CASE WHEN v_submitted THEN v_bid ELSE NULL END,
      'submitted_count',v_bid_count,'player_count',v_player_count
    )
  );$old$;
  v_new := $new$
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
          (SELECT pr.display_name FROM public.profiles pr WHERE pr.id=e.actor_id),
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
  );$new$;
  if position(v_old in v_def)=0 then
    raise exception 'Could not find get_game_view_impl return block to patch';
  end if;
  v_def := replace(v_def,v_old,v_new);
  execute v_def;

  -- Enrich action events with the actual choices and effects made by the player.
  v_def := pg_get_functiondef('private.perform_action_card_impl(uuid,text,text,jsonb)'::regprocedure);
  v_old := $old$
  INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
  VALUES(v_game.id,v_user_id,'action_card_used',jsonb_build_object(
    'card_id',p_card_id,'mode',p_mode,'action',v_action,'sector',v_sector
  ));$old$;
  v_new := $new$
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
  ));$new$;
  if position(v_old in v_def)=0 then
    raise exception 'Could not find perform_action_card_impl event insert to patch';
  end if;
  v_def := replace(v_def,v_old,v_new);
  execute v_def;

  -- Record unit price and proceeds for normal sell-phase sales.
  v_def := pg_get_functiondef('private.complete_sell_turn_impl(uuid,text,integer)'::regprocedure);
  v_old := $old$
  INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
  VALUES(v_game.id,v_user_id,'sell_turn',jsonb_build_object('sector',p_sector,'quantity',p_quantity));$old$;
  v_new := $new$
  INSERT INTO public.game_events(game_id,actor_id,event_type,payload)
  VALUES(v_game.id,v_user_id,'sell_turn',jsonb_build_object(
    'sector',p_sector,
    'quantity',p_quantity,
    'unit_price',v_price,
    'coins_earned',coalesce(p_quantity,0)*coalesce(v_price,0)
  ));$new$;
  if position(v_old in v_def)=0 then
    raise exception 'Could not find complete_sell_turn_impl event insert to patch';
  end if;
  v_def := replace(v_def,v_old,v_new);
  execute v_def;
end
$patch$;
