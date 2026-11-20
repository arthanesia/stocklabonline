-- Draft schema for StockLab Online.
-- Review against the uploaded Official StockLab Guide before applying.
-- This file has NOT been applied to a Supabase project.

create extension if not exists pgcrypto;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text not null unique,
  host_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'lobby'
    check (status in ('lobby','bidding','action','sell','economy','finished')),
  round_number integer not null default 1 check (round_number >= 1),
  max_players integer not null default 5 check (max_players between 2 and 5),
  game_state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.room_players (
  room_id uuid not null references public.rooms(id) on delete cascade,
  player_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  seat_number integer not null check (seat_number between 1 and 5),
  is_ready boolean not null default false,
  player_state jsonb not null default '{}'::jsonb,
  joined_at timestamptz not null default now(),
  primary key (room_id, player_id),
  unique (room_id, seat_number)
);

create table if not exists public.game_events (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.rooms enable row level security;
alter table public.room_players enable row level security;
alter table public.game_events enable row level security;

-- Room members and host can read room metadata/state.
create policy "room members can read their rooms"
on public.rooms for select to authenticated
using (
  host_id = (select auth.uid())
  or exists (
    select 1 from public.room_players rp
    where rp.room_id = rooms.id and rp.player_id = (select auth.uid())
  )
);

-- Host can create a room for themselves.
create policy "players create rooms as host"
on public.rooms for insert to authenticated
with check (host_id = (select auth.uid()));

-- Player list visible only to members of that room.
create policy "room members can read players"
on public.room_players for select to authenticated
using (
  player_id = (select auth.uid())
  or exists (
    select 1 from public.rooms r
    where r.id = room_players.room_id and r.host_id = (select auth.uid())
  )
  or exists (
    select 1 from public.room_players rp
    where rp.room_id = room_players.room_id and rp.player_id = (select auth.uid())
  )
);

-- A player may add only their own membership row. Seat allocation will be
-- moved to a validated RPC before the public multiplayer launch.
create policy "players may join as themselves"
on public.room_players for insert to authenticated
with check (player_id = (select auth.uid()));

create policy "room members can read game events"
on public.game_events for select to authenticated
using (
  exists (
    select 1 from public.room_players rp
    where rp.room_id = game_events.room_id and rp.player_id = (select auth.uid())
  )
  or exists (
    select 1 from public.rooms r
    where r.id = game_events.room_id and r.host_id = (select auth.uid())
  )
);

-- Direct writes to game_events are intentionally not granted. Game actions
-- will be performed through transaction-safe, validated database functions.
