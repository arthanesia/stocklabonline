do $patch$
declare
  v_def text;
  v_old text;
  v_new text;
begin
  v_def := pg_get_functiondef('private.perform_action_card_impl(uuid,text,text,jsonb)'::regprocedure);

  v_old := '          v_price_change:=private.apply_price_delta(v_players,v_market,v_s1,v_delta,false,v_split_remaining);';
  v_new := $new$
          IF (coalesce((v_market->>v_s1)::integer,5)+v_delta)<1
             OR (coalesce((v_market->>v_s1)::integer,5)+v_delta)>9 THEN
            RAISE EXCEPTION 'Rumor tidak dapat menggeser sektor % sebesar % poin dari harga %; batas harga adalah 1–9.',
              v_s1,v_delta,coalesce((v_market->>v_s1)::integer,5)
              USING errcode='22023';
          END IF;
          v_price_change:=private.apply_price_delta(v_players,v_market,v_s1,v_delta,false,v_split_remaining);$new$;
  if position(v_old in v_def)=0 then raise exception 'Rumor sector A movement not found'; end if;
  v_def := replace(v_def,v_old,v_new);

  v_old := '          v_price_change:=private.apply_price_delta(v_players,v_market,v_s2,v_delta,false,v_split_remaining);';
  v_new := $new$
          IF (coalesce((v_market->>v_s2)::integer,5)+v_delta)<1
             OR (coalesce((v_market->>v_s2)::integer,5)+v_delta)>9 THEN
            RAISE EXCEPTION 'Rumor tidak dapat menggeser sektor % sebesar % poin dari harga %; batas harga adalah 1–9.',
              v_s2,v_delta,coalesce((v_market->>v_s2)::integer,5)
              USING errcode='22023';
          END IF;
          v_price_change:=private.apply_price_delta(v_players,v_market,v_s2,v_delta,false,v_split_remaining);$new$;
  if position(v_old in v_def)=0 then raise exception 'Rumor sector B movement not found'; end if;
  v_def := replace(v_def,v_old,v_new);
  execute v_def;
end
$patch$;
