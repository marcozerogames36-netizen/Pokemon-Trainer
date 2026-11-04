-- Trainer affinity is earned by completing friendly battles with an existing friend.
-- Ten qualifying matches, at most one point per pair every 24 hours, unlock direct Pokémon trades.
create table if not exists public.trainer_affinity (
  trainer_a uuid not null references auth.users(id) on delete cascade,
  trainer_b uuid not null references auth.users(id) on delete cascade,
  points integer not null default 0 check (points between 0 and 10),
  last_awarded_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (trainer_a, trainer_b),
  check (trainer_a < trainer_b)
);
alter table public.trainer_affinity add column if not exists last_awarded_at timestamptz;
alter table public.trainer_affinity drop constraint if exists trainer_affinity_points_check;
alter table public.trainer_affinity add constraint trainer_affinity_points_check check (points between 0 and 10);

create table if not exists public.trainer_affinity_matches (
  room_id uuid primary key references public.pvp_rooms(id) on delete cascade,
  trainer_a uuid not null references auth.users(id) on delete cascade,
  trainer_b uuid not null references auth.users(id) on delete cascade,
  awarded_at timestamptz not null default now(),
  check (trainer_a < trainer_b)
);

alter table public.trainer_affinity enable row level security;
alter table public.trainer_affinity_matches enable row level security;
revoke all on table public.trainer_affinity, public.trainer_affinity_matches from public, anon, authenticated;

create or replace function public.award_trainer_affinity_after_friendly_battle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trainer_a uuid;
  v_trainer_b uuid;
  v_inserted integer;
  v_points integer;
  v_last_awarded_at timestamptz;
begin
  if new.status <> 'finished' or old.status = 'finished'
     or new.battle_mode <> 'friendly'
     or new.host_id is null or new.guest_id is null
     or new.host_id = new.guest_id
     or coalesce(new.turn, 0) < 5
     or new.battle->>'result' is distinct from 'normal'
     or coalesce(new.battle->>'winner_user_id', '') not in (new.host_id::text, new.guest_id::text) then
    return new;
  end if;

  if not exists (
    select 1 from public.trainer_friends
    where user_id = new.host_id and friend_id = new.guest_id
  ) or not exists (
    select 1 from public.trainer_friends
    where user_id = new.guest_id and friend_id = new.host_id
  ) then
    return new;
  end if;

  v_trainer_a := least(new.host_id, new.guest_id);
  v_trainer_b := greatest(new.host_id, new.guest_id);

  perform pg_advisory_xact_lock(hashtextextended('trainer-affinity:' || v_trainer_a::text || ':' || v_trainer_b::text, 0));
  select points, last_awarded_at into v_points, v_last_awarded_at
  from public.trainer_affinity
  where trainer_a = v_trainer_a and trainer_b = v_trainer_b
  for update;
  if coalesce(v_points, 0) >= 10
     or (v_last_awarded_at is not null and v_last_awarded_at > now() - interval '24 hours') then
    return new;
  end if;

  insert into public.trainer_affinity_matches(room_id, trainer_a, trainer_b)
  values (new.id, v_trainer_a, v_trainer_b)
  on conflict (room_id) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 1 then
    insert into public.trainer_affinity(trainer_a, trainer_b, points, last_awarded_at, updated_at)
    values (v_trainer_a, v_trainer_b, 1, now(), now())
    on conflict (trainer_a, trainer_b) do update
      set points = least(10, public.trainer_affinity.points + 1),
          last_awarded_at = now(),
          updated_at = now();
  end if;
  return new;
end;
$$;

revoke execute on function public.award_trainer_affinity_after_friendly_battle() from public, anon, authenticated;

drop trigger if exists trainer_affinity_on_friendly_battle_finish on public.pvp_rooms;
create trigger trainer_affinity_on_friendly_battle_finish
after update of status on public.pvp_rooms
for each row
when (new.status = 'finished')
execute function public.award_trainer_affinity_after_friendly_battle();

create or replace function public.social_get_trade_affinity(p_friend_ids uuid[])
returns table(friend_id uuid, affinity_points integer, required_points integer, trade_unlocked boolean, next_point_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
  return query
  select f.friend_id,
         coalesce(a.points, 0),
         10,
         coalesce(a.points, 0) >= 10,
         case when coalesce(a.points, 0) < 10
                    and a.last_awarded_at > now() - interval '24 hours'
              then a.last_awarded_at + interval '24 hours'
              else null::timestamptz end
  from public.trainer_friends f
  left join public.trainer_affinity a
    on a.trainer_a = least(auth.uid(), f.friend_id)
   and a.trainer_b = greatest(auth.uid(), f.friend_id)
  where f.user_id = auth.uid()
    and f.friend_id = any(coalesce(p_friend_ids, array[]::uuid[]));
end;
$$;

revoke execute on function public.social_get_trade_affinity(uuid[]) from public, anon;
grant execute on function public.social_get_trade_affinity(uuid[]) to authenticated;

create or replace function public.enforce_trade_affinity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trainer_a uuid;
  v_trainer_b uuid;
  v_points integer;
  v_should_check boolean := false;
begin
  if new.kind <> 'trade' then return new; end if;
  if tg_op = 'INSERT' then
    v_should_check := true;
  elsif old.status = 'pending' and new.status = 'accepted' then
    v_should_check := true;
  end if;
  if not v_should_check then return new; end if;
  if new.sender_id is null or new.receiver_id is null or new.sender_id = new.receiver_id then
    raise exception 'Treinadores inválidos para troca.';
  end if;

  v_trainer_a := least(new.sender_id, new.receiver_id);
  v_trainer_b := greatest(new.sender_id, new.receiver_id);
  select points into v_points
  from public.trainer_affinity
  where trainer_a = v_trainer_a and trainer_b = v_trainer_b;
  v_points := coalesce(v_points, 0);
  if v_points < 10 then
    raise exception 'Afinidade insuficiente para troca: %/10 batalhas amistosas válidas.', v_points;
  end if;
  return new;
end;
$$;

revoke execute on function public.enforce_trade_affinity() from public, anon, authenticated;

drop trigger if exists enforce_trade_affinity_before_request_write on public.social_requests;
create trigger enforce_trade_affinity_before_request_write
before insert or update of status on public.social_requests
for each row
execute function public.enforce_trade_affinity();
