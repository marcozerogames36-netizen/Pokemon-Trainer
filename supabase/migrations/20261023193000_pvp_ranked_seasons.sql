alter table public.pvp_rooms
  add column if not exists battle_mode text not null default 'friendly',
  add column if not exists season_id text;
do $$
begin
  if not exists(select 1 from pg_catalog.pg_constraint where conname='pvp_rooms_battle_mode_check') then
    alter table public.pvp_rooms add constraint pvp_rooms_battle_mode_check check (battle_mode in ('friendly','ranked'));
  end if;
end $$;

create table if not exists public.pvp_ranked_profiles (
  user_id uuid not null references auth.users(id) on delete cascade,
  season_id text not null,
  rating integer not null default 1000 check (rating >= 100),
  wins integer not null default 0 check (wins >= 0),
  losses integer not null default 0 check (losses >= 0),
  best_rating integer not null default 1000 check (best_rating >= 100),
  current_streak integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key(user_id,season_id)
);
create table if not exists public.pvp_ranked_queue (
  user_id uuid primary key references auth.users(id) on delete cascade,
  season_id text not null,
  rating integer not null default 1000,
  team jsonb not null,
  trainer_name text not null,
  queue_status text not null default 'waiting' check(queue_status in ('waiting','matched')),
  room_id uuid references public.pvp_rooms(id) on delete set null,
  queued_at timestamptz not null default now()
);
create index if not exists pvp_ranked_queue_match_idx on public.pvp_ranked_queue(season_id,queue_status,rating,queued_at);
alter table public.pvp_ranked_profiles enable row level security;
alter table public.pvp_ranked_queue enable row level security;
revoke all on public.pvp_ranked_profiles,public.pvp_ranked_queue from public,anon,authenticated;

create or replace function public.pvp_ranked_get_profile()
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_season text:=to_char(now() at time zone 'UTC','YYYY-MM'); v_profile public.pvp_ranked_profiles;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
  insert into public.pvp_ranked_profiles(user_id,season_id) values(auth.uid(),v_season) on conflict do nothing;
  select * into v_profile from public.pvp_ranked_profiles where user_id=auth.uid() and season_id=v_season;
  return to_jsonb(v_profile);
end $$;

create or replace function public.pvp_ranked_enter_queue(p_team jsonb,p_trainer text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_user uuid:=auth.uid(); v_season text:=to_char(now() at time zone 'UTC','YYYY-MM');
  v_rating integer; v_entry public.pvp_ranked_queue; v_opponent public.pvp_ranked_queue; v_room public.pvp_rooms; v_code text;
begin
  if v_user is null then raise exception 'Entre na sua conta.'; end if;
  if not public.pvp_valid_team(p_team) then raise exception 'Escolha entre 1 e 6 Pokémon.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('pvp-ranked-'||v_season,0));
  delete from public.pvp_ranked_queue where queue_status='waiting' and queued_at < now()-interval '10 minutes';
  insert into public.pvp_ranked_profiles(user_id,season_id) values(v_user,v_season) on conflict do nothing;
  select rating into v_rating from public.pvp_ranked_profiles where user_id=v_user and season_id=v_season;
  select * into v_entry from public.pvp_ranked_queue where user_id=v_user for update;
  if found and v_entry.queue_status='matched' and v_entry.room_id is not null then
    select * into v_room from public.pvp_rooms where id=v_entry.room_id;
    if found and v_room.status in ('ready','battle') then return jsonb_build_object('status','matched','room',to_jsonb(v_room)); end if;
    delete from public.pvp_ranked_queue where user_id=v_user;
  end if;
  select * into v_opponent from public.pvp_ranked_queue q
  where q.season_id=v_season and q.queue_status='waiting' and q.user_id<>v_user
    and abs(q.rating-v_rating) <= least(600,200+floor(extract(epoch from (now()-q.queued_at))/15)::integer)
  order by q.queued_at asc limit 1 for update;
  if found then
    loop
      v_code:=upper(substr(md5(random()::text||clock_timestamp()::text),1,6));
      exit when not exists(select 1 from public.pvp_rooms where room_code=v_code);
    end loop;
    insert into public.pvp_rooms(room_code,host_id,guest_id,host_name,guest_name,host_team,guest_team,status,host_ready,guest_ready,battle_mode,season_id)
    values(v_code,v_user,v_opponent.user_id,left(trim(coalesce(p_trainer,'Treinador')),24),v_opponent.trainer_name,p_team,v_opponent.team,'ready',false,false,'ranked',v_season)
    returning * into v_room;
    update public.pvp_ranked_queue set queue_status='matched',room_id=v_room.id where user_id in (v_user,v_opponent.user_id);
    return jsonb_build_object('status','matched','room',to_jsonb(v_room));
  end if;
  insert into public.pvp_ranked_queue(user_id,season_id,rating,team,trainer_name,queue_status,room_id,queued_at)
  values(v_user,v_season,v_rating,p_team,left(trim(coalesce(p_trainer,'Treinador')),24),'waiting',null,now())
  on conflict(user_id) do update set season_id=excluded.season_id,rating=excluded.rating,team=excluded.team,
    trainer_name=excluded.trainer_name,queue_status='waiting',room_id=null,queued_at=now();
  return jsonb_build_object('status','waiting','season_id',v_season,'rating',v_rating);
end $$;

create or replace function public.pvp_ranked_queue_status()
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_entry public.pvp_ranked_queue; v_room public.pvp_rooms;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
  select * into v_entry from public.pvp_ranked_queue where user_id=auth.uid();
  if not found then return jsonb_build_object('status','idle'); end if;
  if v_entry.queue_status='matched' and v_entry.room_id is not null then
    select * into v_room from public.pvp_rooms where id=v_entry.room_id;
    if found and v_room.status in ('ready','battle') then return jsonb_build_object('status','matched','room',to_jsonb(v_room)); end if;
    delete from public.pvp_ranked_queue where user_id=auth.uid();
    return jsonb_build_object('status','idle');
  end if;
  if v_entry.queued_at < now()-interval '10 minutes' then
    delete from public.pvp_ranked_queue where user_id=auth.uid();
    return jsonb_build_object('status','idle');
  end if;
  return jsonb_build_object('status','waiting','season_id',v_entry.season_id,'rating',v_entry.rating,'queued_at',v_entry.queued_at);
end $$;

create or replace function public.pvp_ranked_leave_queue()
returns jsonb language plpgsql security definer set search_path=''
as $$
begin
  if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
  delete from public.pvp_ranked_queue where user_id=auth.uid() and queue_status='waiting';
  return jsonb_build_object('status','idle');
end $$;

create or replace function public.pvp_ranked_settle(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_room public.pvp_rooms; v_winner uuid; v_loser uuid; v_winner_rating integer; v_loser_rating integer;
  v_expected numeric; v_delta integer; v_host_change integer; v_guest_change integer; v_profile public.pvp_ranked_profiles;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
  select * into v_room from public.pvp_rooms where id=p_room_id for update;
  if not found or auth.uid() not in (v_room.host_id,v_room.guest_id) then raise exception 'Você não participa desta batalha.'; end if;
  if v_room.battle_mode<>'ranked' or v_room.status<>'finished' then raise exception 'A batalha ranqueada ainda não terminou.'; end if;
  if v_room.battle->>'ranked_settled'='true' then
    select * into v_profile from public.pvp_ranked_profiles where user_id=auth.uid() and season_id=v_room.season_id;
    return jsonb_build_object('rating',v_profile.rating,'rating_change',case when auth.uid()=v_room.host_id then coalesce((v_room.battle->>'ranked_host_change')::integer,0) else coalesce((v_room.battle->>'ranked_guest_change')::integer,0) end,'already_settled',true);
  end if;
  v_winner:=nullif(v_room.battle->>'winner_user_id','')::uuid;
  if v_winner is null or v_winner not in (v_room.host_id,v_room.guest_id) or v_room.battle->>'result' not in ('normal','abandoned') then
    raise exception 'O resultado desta batalha não pode alterar o rating.';
  end if;
  v_loser:=case when v_winner=v_room.host_id then v_room.guest_id else v_room.host_id end;
  perform pg_advisory_xact_lock(hashtextextended('pvp-ranked-settle-'||v_room.season_id,0));
  insert into public.pvp_ranked_profiles(user_id,season_id) values(v_winner,v_room.season_id),(v_loser,v_room.season_id) on conflict do nothing;
  select rating into v_winner_rating from public.pvp_ranked_profiles where user_id=v_winner and season_id=v_room.season_id for update;
  select rating into v_loser_rating from public.pvp_ranked_profiles where user_id=v_loser and season_id=v_room.season_id for update;
  v_expected:=1/(1+power(10::numeric,(v_loser_rating-v_winner_rating)::numeric/400));
  v_delta:=greatest(1,round(32*(1-v_expected))::integer);
  if v_winner=v_room.host_id then
    v_host_change:=v_delta; v_guest_change:=-least(v_delta,v_loser_rating-100);
  else
    v_guest_change:=v_delta; v_host_change:=-least(v_delta,v_loser_rating-100);
  end if;
  update public.pvp_ranked_profiles set rating=rating+v_host_change,wins=wins+case when user_id=v_winner then 1 else 0 end,
    losses=losses+case when user_id=v_loser then 1 else 0 end,
    current_streak=case when user_id=v_winner then current_streak+1 else 0 end,
    best_rating=greatest(best_rating,rating+v_host_change),updated_at=now()
    where user_id=v_room.host_id and season_id=v_room.season_id returning * into v_profile;
  update public.pvp_ranked_profiles set rating=rating+v_guest_change,wins=wins+case when user_id=v_winner then 1 else 0 end,
    losses=losses+case when user_id=v_loser then 1 else 0 end,
    current_streak=case when user_id=v_winner then current_streak+1 else 0 end,
    best_rating=greatest(best_rating,rating+v_guest_change),updated_at=now()
    where user_id=v_room.guest_id and season_id=v_room.season_id;
  update public.pvp_rooms set battle=battle||jsonb_build_object('ranked_settled',true,'ranked_host_change',v_host_change,'ranked_guest_change',v_guest_change),updated_at=now() where id=v_room.id;
  if auth.uid()=v_room.host_id then return jsonb_build_object('rating',v_profile.rating,'rating_change',v_host_change,'season_id',v_room.season_id); end if;
  select * into v_profile from public.pvp_ranked_profiles where user_id=auth.uid() and season_id=v_room.season_id;
  return jsonb_build_object('rating',v_profile.rating,'rating_change',v_guest_change,'season_id',v_room.season_id);
end $$;

revoke execute on function public.pvp_ranked_get_profile() from public,anon;
revoke execute on function public.pvp_ranked_enter_queue(jsonb,text) from public,anon;
revoke execute on function public.pvp_ranked_queue_status() from public,anon;
revoke execute on function public.pvp_ranked_leave_queue() from public,anon;
revoke execute on function public.pvp_ranked_settle(uuid) from public,anon;
grant execute on function public.pvp_ranked_get_profile() to authenticated;
grant execute on function public.pvp_ranked_enter_queue(jsonb,text) to authenticated;
grant execute on function public.pvp_ranked_queue_status() to authenticated;
grant execute on function public.pvp_ranked_leave_queue() to authenticated;
grant execute on function public.pvp_ranked_settle(uuid) to authenticated;
notify pgrst,'reload schema';