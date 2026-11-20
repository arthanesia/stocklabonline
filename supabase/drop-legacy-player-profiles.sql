-- Remove the legacy persistent player profile table; active room names live in room_members.
DROP TABLE IF EXISTS public.profiles;