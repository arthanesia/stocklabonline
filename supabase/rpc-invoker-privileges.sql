CREATE OR REPLACE FUNCTION public.join_room_by_code_v2(p_code text,p_password text,p_display_name text)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path TO ''
AS $function$
  SELECT private.join_room_by_code_v2_impl(p_code,p_password,p_display_name);
$function$;

CREATE OR REPLACE FUNCTION public.respond_debt_offer(p_room_id uuid,p_accept boolean)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path TO ''
AS $function$
  SELECT private.respond_debt_offer_impl(p_room_id,p_accept);
$function$;

REVOKE ALL ON FUNCTION public.join_room_by_code_v2(text,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.respond_debt_offer(uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.join_room_by_code_v2(text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.respond_debt_offer(uuid,boolean) TO authenticated;