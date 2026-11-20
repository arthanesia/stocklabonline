-- Room password support for StockLab Online.
-- Run after schema.sql and game-engine.sql on a fresh Supabase project.
-- Passwords are bcrypt hashes in a private schema, never returned by room-list RPCs.

create table if not exists private.room_credentials (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  password_hash text not null,
  created_at timestamptz not null default now()
);
alter table private.room_credentials enable row level security;
revoke all privileges on table private.room_credentials from public, anon, authenticated;

drop function if exists public.create_room(text, integer);
drop function if exists private.create_room_impl(text, integer);
drop function if exists public.join_room_by_code(text);
drop function if exists private.join_room_by_code_impl(text);

create or replace function private.create_room_impl(p_display_name text, p_max_players integer, p_password text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room_id uuid;
  v_code text;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if v_user_id is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_display_name is null or char_length(trim(p_display_name)) not between 2 and 24 then
    raise exception 'Username must be 2 to 24 characters' using errcode = '22023';
  end if;
  if p_max_players is null or p_max_players not between 2 and 5 then
    raise exception 'Room capacity must be between 2 and 5' using errcode = '22023';
  end if;
  if p_password is null or char_length(p_password) not between 6 and 32 or octet_length(p_password) > 72 then
    raise exception 'Room password must be 6 to 32 characters' using errcode = '22023';
  end if;

  insert into public.profiles(id, display_name, updated_at)
  values (v_user_id, trim(p_display_name), now())
  on conflict (id) do update set display_name = excluded.display_name, updated_at = now();

  for attempt in 1..10 loop
    select string_agg(substr(v_alphabet, (floor(random() * length(v_alphabet))::int + 1), 1), '')
    into v_code from generate_series(1,6);
    insert into public.rooms(invite_code, host_id, max_players)
    values (v_code, v_user_id, p_max_players)
    on conflict (invite_code) do nothing returning id into v_room_id;
    if v_room_id is not null then exit; end if;
  end loop;
  if v_room_id is null then
    raise exception 'Could not allocate a unique room code. Try again.' using errcode = '55000';
  end if;

  insert into private.room_credentials(room_id, password_hash)
  values (v_room_id, extensions.crypt(p_password, extensions.gen_salt('bf', 12)));
  insert into public.room_members(room_id, user_id, seat_no, is_ready)
  values (v_room_id, v_user_id, 1, true);

  return jsonb_build_object('room_id', v_room_id, 'invite_code', v_code, 'seat_no', 1, 'max_players', p_max_players);
end;
$$;
revoke all on function private.create_room_impl(text, integer, text) from public, anon;
grant execute on function private.create_room_impl(text, integer, text) to authenticated;

create or replace function public.create_room(p_display_name text, p_max_players integer, p_password text)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.create_room_impl(p_display_name, p_max_players, p_password); $$;
revoke all on function public.create_room(text, integer, text) from public, anon;
grant execute on function public.create_room(text, integer, text) to authenticated;

create or replace function private.join_room_by_code_impl(p_code text, p_password text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_existing public.room_members%rowtype;
  v_password_hash text;
  v_seat integer;
  v_count integer;
begin
  if v_user_id is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_code is null or p_code !~ '^[A-Za-z0-9]{6}$' then
    raise exception 'Invalid room code' using errcode = '22023';
  end if;
  if p_password is null or char_length(p_password) not between 6 and 32 or octet_length(p_password) > 72 then
    raise exception 'Password room tidak valid.' using errcode = '22023';
  end if;

  select * into v_room from public.rooms r where r.invite_code = upper(p_code) for update;
  if not found then raise exception 'Room tidak ditemukan.' using errcode = 'P0002'; end if;

  select rc.password_hash into v_password_hash
  from private.room_credentials rc where rc.room_id = v_room.id;
  if v_password_hash is null
     or extensions.crypt(p_password, v_password_hash) is distinct from v_password_hash then
    raise exception 'Password room salah.' using errcode = '28P01';
  end if;
  if v_room.status <> 'waiting' then
    raise exception 'Room sudah tidak menerima pemain.' using errcode = '55000';
  end if;

  select * into v_existing from public.room_members rm
  where rm.room_id = v_room.id and rm.user_id = v_user_id;
  if found then
    select count(*) into v_count from public.room_members rm where rm.room_id = v_room.id;
    return jsonb_build_object('room_id', v_room.id, 'seat_no', v_existing.seat_no, 'member_count', v_count);
  end if;

  select count(*) into v_count from public.room_members rm where rm.room_id = v_room.id;
  if v_count >= v_room.max_players then raise exception 'Room sudah penuh.' using errcode = '54000'; end if;

  select seats.seat_no into v_seat
  from generate_series(1, v_room.max_players) as seats(seat_no)
  where not exists (
    select 1 from public.room_members rm
    where rm.room_id = v_room.id and rm.seat_no = seats.seat_no
  )
  order by seats.seat_no limit 1;
  if v_seat is null then raise exception 'No available seat' using errcode = '54000'; end if;

  insert into public.room_members(room_id, user_id, seat_no) values (v_room.id, v_user_id, v_seat);
  return jsonb_build_object('room_id', v_room.id, 'seat_no', v_seat, 'member_count', v_count + 1);
end;
$$;
revoke all on function private.join_room_by_code_impl(text, text) from public, anon;
grant execute on function private.join_room_by_code_impl(text, text) to authenticated;

create or replace function public.join_room_by_code(p_code text, p_password text)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.join_room_by_code_impl(p_code, p_password); $$;
revoke all on function public.join_room_by_code(text, text) from public, anon;
grant execute on function public.join_room_by_code(text, text) to authenticated;

create or replace function private.list_open_rooms_impl()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_result jsonb;
begin
  if v_user_id is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', q.id, 'invite_code', q.invite_code, 'host_name', q.host_name,
    'member_count', q.member_count, 'max_players', q.max_players, 'created_at', q.created_at
  ) order by q.created_at desc), '[]'::jsonb)
  into v_result
  from (
    select r.id, r.invite_code, coalesce(p.display_name, 'Pemain') as host_name,
      count(rm.id)::integer as member_count, r.max_players, r.created_at
    from public.rooms r
    left join public.profiles p on p.id = r.host_id
    left join public.room_members rm on rm.room_id = r.id
    where r.status = 'waiting'
      and exists (select 1 from private.room_credentials rc where rc.room_id = r.id)
    group by r.id, r.invite_code, p.display_name, r.max_players, r.created_at
    order by r.created_at desc limit 50
  ) q;
  return v_result;
end;
$$;
revoke all on function private.list_open_rooms_impl() from public, anon;
grant execute on function private.list_open_rooms_impl() to authenticated;
