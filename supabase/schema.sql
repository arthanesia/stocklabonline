-- StockLab Online database foundation
-- PostgreSQL 17 / Supabase
-- Apply to a fresh project. Public tables use RLS; client game-state writes are intentionally not granted yet.

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 2 and 24),
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  invite_code text not null unique check (invite_code ~ '^[A-Z0-9]{6}$'),
  host_id uuid not null references auth.users(id) on delete restrict,
  status text not null default 'waiting' check (status in ('waiting','in_progress','finished')),
  max_players smallint not null default 5 check (max_players between 2 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.room_members (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  seat_no smallint not null check (seat_no between 1 and 5),
  is_ready boolean not null default false,
  joined_at timestamptz not null default now(),
  unique (room_id, user_id),
  unique (room_id, seat_no)
);
create index room_members_user_id_idx on public.room_members(user_id);

create table public.games (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null unique references public.rooms(id) on delete cascade,
  current_round integer not null default 1 check (current_round >= 1),
  phase text not null default 'bidding' check (phase in ('bidding','action','sell','economy','finished')),
  active_user_id uuid references auth.users(id) on delete set null,
  state jsonb not null default '{}'::jsonb,
  version bigint not null default 0 check (version >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.game_events (
  id bigint generated always as identity primary key,
  game_id uuid not null references public.games(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  event_type text not null check (char_length(event_type) between 1 and 60),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index game_events_game_id_id_idx on public.game_events(game_id, id);
create index rooms_host_id_idx on public.rooms(host_id);
create index games_active_user_id_idx on public.games(active_user_id);
create index game_events_actor_id_idx on public.game_events(actor_id);

alter table public.profiles enable row level security;
alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.games enable row level security;
alter table public.game_events enable row level security;

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.is_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
  select auth.uid() is not null
    and exists (
      select 1 from public.room_members rm
      where rm.room_id = p_room_id and rm.user_id = auth.uid()
    );
$$;
revoke all on function private.is_room_member(uuid) from public, anon;
grant execute on function private.is_room_member(uuid) to authenticated;

create policy "profiles_select_own_or_room_member" on public.profiles
for select to authenticated
using (
  id = (select auth.uid())
  or exists (
    select 1 from public.room_members rm
    where rm.user_id = profiles.id and private.is_room_member(rm.room_id)
  )
);
create policy "profiles_insert_own" on public.profiles
for insert to authenticated with check ((select auth.uid()) = id);
create policy "profiles_update_own" on public.profiles
for update to authenticated using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

create policy "rooms_select_host_or_member" on public.rooms
for select to authenticated
using (
  host_id = (select auth.uid())
  or exists (
    select 1 from public.room_members rm
    where rm.room_id = rooms.id and rm.user_id = (select auth.uid())
  )
);
create policy "rooms_insert_as_host" on public.rooms
for insert to authenticated with check (host_id = (select auth.uid()) and status = 'waiting');
create policy "rooms_delete_by_host_while_waiting" on public.rooms
for delete to authenticated
using (host_id = (select auth.uid()) and status = 'waiting');

create policy "room_members_select_room_members" on public.room_members
for select to authenticated using (private.is_room_member(room_id));
create policy "room_members_insert_host_self" on public.room_members
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.rooms r
    where r.id = room_members.room_id and r.host_id = (select auth.uid())
  )
);
create policy "room_members_update_ready_self" on public.room_members
for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

create policy "games_select_room_members" on public.games
for select to authenticated
using (private.is_room_member(room_id));
create policy "game_events_select_room_members" on public.game_events
for select to authenticated
using (
  exists (
    select 1 from public.games g
    where g.id = game_events.game_id and private.is_room_member(g.room_id)
  )
);

grant usage on schema public to authenticated;
revoke all privileges on all tables in schema public from public, anon, authenticated;
revoke all privileges on all sequences in schema public from public, anon, authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, delete on public.rooms to authenticated;
grant select, insert on public.room_members to authenticated;
grant update (is_ready) on public.room_members to authenticated;
grant select on public.games, public.game_events to authenticated;

create or replace function private.join_room_by_code_impl(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_existing public.room_members%rowtype;
  v_seat integer;
  v_count integer;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if p_code is null or p_code !~ '^[A-Za-z0-9]{6}$' then
    raise exception 'Invalid room code' using errcode = '22023';
  end if;

  select * into v_room
  from public.rooms r
  where r.invite_code = upper(p_code)
  for update;

  if not found then
    raise exception 'Room not found' using errcode = 'P0002';
  end if;
  if v_room.status <> 'waiting' then
    raise exception 'Room is not accepting players' using errcode = '55000';
  end if;

  select * into v_existing
  from public.room_members rm
  where rm.room_id = v_room.id and rm.user_id = v_user_id;

  if found then
    select count(*) into v_count from public.room_members rm where rm.room_id = v_room.id;
    return jsonb_build_object('room_id', v_room.id, 'seat_no', v_existing.seat_no, 'member_count', v_count);
  end if;

  select count(*) into v_count
  from public.room_members rm
  where rm.room_id = v_room.id;

  if v_count >= v_room.max_players then
    raise exception 'Room is full' using errcode = '54000';
  end if;

  select seats.seat_no into v_seat
  from generate_series(1, v_room.max_players) as seats(seat_no)
  where not exists (
    select 1 from public.room_members rm
    where rm.room_id = v_room.id and rm.seat_no = seats.seat_no
  )
  order by seats.seat_no
  limit 1;

  if v_seat is null then
    raise exception 'No available seat' using errcode = '54000';
  end if;

  insert into public.room_members(room_id, user_id, seat_no)
  values (v_room.id, v_user_id, v_seat);

  return jsonb_build_object('room_id', v_room.id, 'seat_no', v_seat, 'member_count', v_count + 1);
end;
$$;
revoke all on function private.join_room_by_code_impl(text) from public, anon;
grant execute on function private.join_room_by_code_impl(text) to authenticated;

create or replace function public.join_room_by_code(p_code text)
returns jsonb
language sql
security invoker
set search_path = pg_catalog, public, private, auth
as $$
  select private.join_room_by_code_impl(p_code);
$$;
revoke all on function public.join_room_by_code(text) from public, anon;
grant execute on function public.join_room_by_code(text) to authenticated;

create or replace function public.get_room_lobby(p_room_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if not exists (
    select 1 from public.room_members rm
    where rm.room_id = p_room_id and rm.user_id = v_user_id
  ) then
    raise exception 'Not a room member' using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id', rm.user_id,
        'display_name', coalesce(p.display_name, 'Pemain'),
        'avatar_url', p.avatar_url,
        'seat_no', rm.seat_no,
        'is_ready', rm.is_ready
      ) order by rm.seat_no
    ),
    '[]'::jsonb
  )
  into v_result
  from public.room_members rm
  left join public.profiles p on p.id = rm.user_id
  where rm.room_id = p_room_id;

  return v_result;
end;
$$;

revoke all on function public.join_room_by_code(text) from public, anon;
revoke all on function public.get_room_lobby(uuid) from public, anon;
grant execute on function public.join_room_by_code(text) to authenticated;
grant execute on function public.get_room_lobby(uuid) to authenticated;

alter publication supabase_realtime add table public.rooms;
alter publication supabase_realtime add table public.room_members;
alter publication supabase_realtime add table public.games;
alter publication supabase_realtime add table public.game_events;


-- Guest-only room experience (Supabase Anonymous Auth; no email/password UI).
create or replace function private.create_room_impl(p_display_name text, p_max_players integer default 5)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, private
as $$
declare
  v_user_id uuid := auth.uid();
  v_room_id uuid;
  v_code text;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if p_display_name is null or char_length(trim(p_display_name)) not between 2 and 24 then
    raise exception 'Username must be 2 to 24 characters' using errcode = '22023';
  end if;
  if p_max_players is null or p_max_players not between 2 and 5 then
    raise exception 'Room capacity must be between 2 and 5' using errcode = '22023';
  end if;

  insert into public.profiles(id, display_name, updated_at)
  values (v_user_id, trim(p_display_name), now())
  on conflict (id) do update
  set display_name = excluded.display_name, updated_at = now();

  for attempt in 1..10 loop
    select string_agg(substr(v_alphabet, (floor(random() * length(v_alphabet))::int + 1), 1), '')
    into v_code
    from generate_series(1,6);

    insert into public.rooms(invite_code, host_id, max_players)
    values (v_code, v_user_id, p_max_players)
    on conflict (invite_code) do nothing
    returning id into v_room_id;

    if v_room_id is not null then
      exit;
    end if;
  end loop;

  if v_room_id is null then
    raise exception 'Could not allocate a unique room code. Try again.' using errcode = '55000';
  end if;

  insert into public.room_members(room_id, user_id, seat_no, is_ready)
  values (v_room_id, v_user_id, 1, true);

  return jsonb_build_object(
    'room_id', v_room_id,
    'invite_code', v_code,
    'seat_no', 1,
    'max_players', p_max_players
  );
end;
$$;
revoke all on function private.create_room_impl(text,integer) from public, anon;
grant execute on function private.create_room_impl(text,integer) to authenticated;

create or replace function public.create_room(p_display_name text, p_max_players integer default 5)
returns jsonb
language sql
security invoker
set search_path = pg_catalog, public, private, auth
as $$
  select private.create_room_impl(p_display_name, p_max_players);
$$;
revoke all on function public.create_room(text,integer) from public, anon;
grant execute on function public.create_room(text,integer) to authenticated;

create or replace function private.list_open_rooms_impl()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, private
as $$
declare
  v_user_id uuid := auth.uid();
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', q.id,
        'invite_code', q.invite_code,
        'host_name', q.host_name,
        'member_count', q.member_count,
        'max_players', q.max_players,
        'created_at', q.created_at
      ) order by q.created_at desc
    ),
    '[]'::jsonb
  )
  into v_result
  from (
    select r.id, r.invite_code,
      coalesce(p.display_name, 'Pemain') as host_name,
      count(rm.id)::integer as member_count,
      r.max_players, r.created_at
    from public.rooms r
    left join public.profiles p on p.id = r.host_id
    left join public.room_members rm on rm.room_id = r.id
    where r.status = 'waiting'
    group by r.id, r.invite_code, p.display_name, r.max_players, r.created_at
    order by r.created_at desc
    limit 50
  ) q;

  return v_result;
end;
$$;
revoke all on function private.list_open_rooms_impl() from public, anon;
grant execute on function private.list_open_rooms_impl() to authenticated;

create or replace function public.list_open_rooms()
returns jsonb
language sql
security invoker
set search_path = pg_catalog, public, private, auth
as $$
  select private.list_open_rooms_impl();
$$;
revoke all on function public.list_open_rooms() from public, anon;
grant execute on function public.list_open_rooms() to authenticated;

create or replace function private.leave_room_impl(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, private
as $$
declare
  v_user_id uuid := auth.uid();
  v_host_id uuid;
  v_members integer;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  select host_id into v_host_id
  from public.rooms
  where id = p_room_id and status = 'waiting'
  for update;

  if not found then
    raise exception 'Waiting room not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.room_members
    where room_id = p_room_id and user_id = v_user_id
  ) then
    raise exception 'You are not a member of this room' using errcode = '42501';
  end if;

  select count(*) into v_members
  from public.room_members where room_id = p_room_id;

  if v_host_id = v_user_id and v_members > 1 then
    raise exception 'Host cannot leave while other players remain. Ask everyone to leave first.' using errcode = '55000';
  end if;

  if v_host_id = v_user_id then
    delete from public.rooms where id = p_room_id;
    return jsonb_build_object('deleted_room', true);
  end if;

  delete from public.room_members
  where room_id = p_room_id and user_id = v_user_id;

  return jsonb_build_object('deleted_room', false);
end;
$$;
revoke all on function private.leave_room_impl(uuid) from public, anon;
grant execute on function private.leave_room_impl(uuid) to authenticated;

create or replace function public.leave_room(p_room_id uuid)
returns jsonb
language sql
security invoker
set search_path = pg_catalog, public, private, auth
as $$
  select private.leave_room_impl(p_room_id);
$$;
revoke all on function public.leave_room(uuid) from public, anon;
grant execute on function public.leave_room(uuid) to authenticated;


-- Private game state and sealed bids. These tables are intentionally not in Realtime.
create table public.game_private_states (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  private_state jsonb not null default '{}'::jsonb
    check (jsonb_typeof(private_state) = 'object'),
  updated_at timestamptz not null default now(),
  primary key (game_id, user_id)
);
comment on table public.game_private_states is
  'Player-only game data. RLS exposes each row only to its owning room member; writes are reserved for validated game RPCs.';
alter table public.game_private_states enable row level security;
create policy game_private_states_select_own on public.game_private_states
for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.games g
    join public.room_members rm on rm.room_id = g.room_id
    where g.id = game_private_states.game_id
      and rm.user_id = (select auth.uid())
  )
);
revoke all privileges on public.game_private_states from public, anon, authenticated;
grant select on public.game_private_states to authenticated;

create table public.bidding_submissions (
  game_id uuid not null references public.games(id) on delete cascade,
  round_number integer not null check (round_number >= 1),
  user_id uuid not null references auth.users(id) on delete cascade,
  bid_amount integer not null check (bid_amount >= 0),
  submitted_at timestamptz not null default now(),
  primary key (game_id, round_number, user_id)
);
comment on table public.bidding_submissions is
  'Sealed per-player bids by round. RLS exposes only the caller''s own bid; do not add this table to supabase_realtime.';
alter table public.bidding_submissions enable row level security;
create policy bidding_submissions_select_own on public.bidding_submissions
for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.games g
    join public.room_members rm on rm.room_id = g.room_id
    where g.id = bidding_submissions.game_id
      and rm.user_id = (select auth.uid())
  )
);
revoke all privileges on public.bidding_submissions from public, anon, authenticated;
grant select on public.bidding_submissions to authenticated;


-- Phase 1 hardening: private player data, sealed bids, and least-privilege access.
-- This block is intentionally appended after the base lobby schema so it also
-- removes the broader legacy grants/policies created above.

BEGIN;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.game_private_states (
  game_id uuid NOT NULL REFERENCES public.games(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  private_state jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (pg_catalog.jsonb_typeof(private_state) = 'object'),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  PRIMARY KEY (game_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.bidding_submissions (
  game_id uuid NOT NULL REFERENCES public.games(id) ON DELETE CASCADE,
  round_number integer NOT NULL CHECK (round_number >= 1),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  bid_amount integer NOT NULL CHECK (bid_amount >= 0),
  submitted_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  PRIMARY KEY (game_id, round_number, user_id)
);

CREATE INDEX IF NOT EXISTS game_private_states_user_id_idx
  ON public.game_private_states (user_id);
CREATE INDEX IF NOT EXISTS bidding_submissions_user_id_idx
  ON public.bidding_submissions (user_id);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.room_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.games ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_private_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bidding_submissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS game_private_states_select_own ON public.game_private_states;
CREATE POLICY game_private_states_select_own
ON public.game_private_states
FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
  AND EXISTS (
    SELECT 1
    FROM public.games g
    WHERE g.id = game_private_states.game_id
      AND private.is_room_member(g.room_id)
  )
);

DROP POLICY IF EXISTS bidding_submissions_select_own ON public.bidding_submissions;
CREATE POLICY bidding_submissions_select_own
ON public.bidding_submissions
FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
  AND EXISTS (
    SELECT 1
    FROM public.games g
    WHERE g.id = bidding_submissions.game_id
      AND private.is_room_member(g.room_id)
  )
);

-- Room creation, joining, and leaving must use the validated RPCs. Only readiness
-- is writable directly by a player, and only for that player's own membership row.
DROP POLICY IF EXISTS rooms_insert_as_host ON public.rooms;
DROP POLICY IF EXISTS rooms_update_by_host ON public.rooms;
DROP POLICY IF EXISTS rooms_delete_by_host_while_waiting ON public.rooms;
DROP POLICY IF EXISTS room_members_insert_host_self ON public.room_members;
DROP POLICY IF EXISTS game_events_select_room_members ON public.game_events;

REVOKE ALL PRIVILEGES ON TABLE
  public.rooms,
  public.room_members,
  public.games,
  public.game_events,
  public.profiles,
  public.game_private_states,
  public.bidding_submissions
FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.rooms, public.room_members, public.games TO authenticated;
GRANT UPDATE (is_ready) ON TABLE public.room_members TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.profiles TO authenticated;
GRANT SELECT ON TABLE public.game_private_states, public.bidding_submissions TO authenticated;
GRANT ALL PRIVILEGES ON TABLE
  public.game_private_states,
  public.bidding_submissions
TO service_role;

-- All RPCs validate auth.uid(). SECURITY DEFINER is limited to private
-- implementation functions; public functions remain SECURITY INVOKER wrappers.
ALTER FUNCTION private.is_room_member(uuid) SET search_path = '';
ALTER FUNCTION private.create_room_impl(text, integer) SET search_path = '';
ALTER FUNCTION private.join_room_by_code_impl(text) SET search_path = '';
ALTER FUNCTION private.list_open_rooms_impl() SET search_path = '';
ALTER FUNCTION private.leave_room_impl(uuid) SET search_path = '';
ALTER FUNCTION public.create_room(text, integer) SET search_path = '';
ALTER FUNCTION public.get_room_lobby(uuid) SET search_path = '';
ALTER FUNCTION public.join_room_by_code(text) SET search_path = '';
ALTER FUNCTION public.list_open_rooms() SET search_path = '';
ALTER FUNCTION public.leave_room(uuid) SET search_path = '';

REVOKE ALL ON FUNCTION private.is_room_member(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.create_room_impl(text, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.join_room_by_code_impl(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.list_open_rooms_impl() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.leave_room_impl(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_room_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.create_room_impl(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION private.join_room_by_code_impl(text) TO authenticated;
GRANT EXECUTE ON FUNCTION private.list_open_rooms_impl() TO authenticated;
GRANT EXECUTE ON FUNCTION private.leave_room_impl(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.create_room(text, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_room_lobby(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.join_room_by_code(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_open_rooms() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.leave_room(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_room(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_room_lobby(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.join_room_by_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_open_rooms() TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_room(uuid) TO authenticated;

DO $do$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'game_events'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime DROP TABLE public.game_events';
  END IF;
END
$do$;

COMMENT ON COLUMN public.games.state IS
  'Shared/public game state only. Never store private hands, sealed bids, or player-only information here.';
COMMENT ON TABLE public.game_private_states IS
  'Player-only game data. RLS exposes each row only to its owning room member; writes are reserved for validated game RPCs.';
COMMENT ON TABLE public.bidding_submissions IS
  'Sealed per-player bids by round. RLS exposes only the caller''s own bid; do not add this table to supabase_realtime.';
COMMENT ON TABLE public.game_events IS
  'Internal audit/event log. Not exposed to anon/authenticated clients or Realtime until event payloads are explicitly sanitized.';

COMMIT;
