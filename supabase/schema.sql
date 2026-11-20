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
as $
  select auth.uid() is not null
    and exists (
      select 1 from public.room_members rm
      where rm.room_id = p_room_id and rm.user_id = auth.uid()
    );
$;
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
for insert to authenticated with check (host_id = (select auth.uid()));
create policy "rooms_update_by_host" on public.rooms
for update to authenticated
using (host_id = (select auth.uid()) and status = 'waiting')
with check (host_id = (select auth.uid()));
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
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.rooms to authenticated;
grant select, insert on public.room_members to authenticated;
grant update (is_ready) on public.room_members to authenticated;
grant select on public.games, public.game_events to authenticated;
grant usage, select on sequence public.game_events_id_seq to authenticated;

create or replace function public.join_room_by_code(p_code text)
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
