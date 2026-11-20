-- Disable the former debt RPC that flipped one share directly.
REVOKE ALL ON FUNCTION public.take_debt(uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.take_debt_impl(uuid,text) FROM PUBLIC,anon,authenticated;