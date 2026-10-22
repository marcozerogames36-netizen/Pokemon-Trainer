-- Cooperative Mewtwo raid. Run after supabase-schema.sql (uses its team/type validators).
create table if not exists public.coop_boss_rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text not null unique check (room_code ~ '^[A-Z0-9]{6}$'),
  host_id uuid not null references auth.users(id) on delete cascade,
  members jsonb not null default '[]'::jsonb,
  status text not null default 'waiting' check (status in ('waiting','battle','won','lost','cancelled')),
  battle jsonb not null default '{}'::jsonb,
  actions jsonb not null default '{}'::jsonb,
  turn integer not null default 0,
  turn_deadline timestamptz,
  expires_at timestamptz not null default now()+interval '30 minutes',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists coop_boss_rooms_host_idx on public.coop_boss_rooms(host_id,status);
alter table public.coop_boss_rooms add column if not exists turn_deadline timestamptz;
alter table public.coop_boss_rooms enable row level security;
alter table public.coop_boss_rooms replica identity full;
revoke all on table public.coop_boss_rooms from public,anon,authenticated;
grant select on public.coop_boss_rooms to authenticated;
drop policy if exists "Raid participants can read room" on public.coop_boss_rooms;
create policy "Raid participants can read room" on public.coop_boss_rooms for select to authenticated
using (exists(select 1 from jsonb_array_elements(members) as entry(member) where entry.member->>'user_id'=(select auth.uid())::text));

create or replace function public.coop_boss_create(p_code text,p_trainer text,p_team jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_room public.coop_boss_rooms;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para criar a raid.'; end if;
  if p_code !~ '^[A-Z0-9]{6}$' or not public.pvp_valid_team(p_team) then raise exception 'Código ou equipe inválidos.'; end if;
  insert into public.coop_boss_rooms(room_code,host_id,members)
  values(p_code,auth.uid(),jsonb_build_array(jsonb_build_object('user_id',auth.uid(),'name',left(coalesce(nullif(trim(p_trainer),''),'Treinador'),24),'team',p_team)))
  returning * into v_room;
  return to_jsonb(v_room);
end $$;

create or replace function public.coop_boss_join(p_code text,p_trainer text,p_team jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_room public.coop_boss_rooms; v_member jsonb;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para participar da raid.'; end if;
  if not public.pvp_valid_team(p_team) then raise exception 'Equipe inválida.'; end if;
  select * into v_room from public.coop_boss_rooms where room_code=upper(p_code) for update;
  if not found then raise exception 'Sala indisponível ou já iniciada.'; end if;
  if exists(select 1 from jsonb_array_elements(v_room.members) as entry(member) where entry.member->>'user_id'=(select auth.uid())::text) then return to_jsonb(v_room); end if;
  if v_room.status<>'waiting' or v_room.expires_at<now() then raise exception 'Sala indisponível ou já iniciada.'; end if;
  if jsonb_array_length(v_room.members)>=5 then raise exception 'A raid já está cheia (máximo de 5 treinadores).'; end if;
  v_member:=jsonb_build_object('user_id',auth.uid(),'name',left(coalesce(nullif(trim(p_trainer),''),'Treinador'),24),'team',p_team);
  update public.coop_boss_rooms set members=members||jsonb_build_array(v_member),updated_at=now() where id=v_room.id returning * into v_room;
  return to_jsonb(v_room);
end $$;

create or replace function public.coop_boss_start(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_room public.coop_boss_rooms; v_member jsonb; v_states jsonb:='{}'::jsonb; v_user text; v_hps jsonb; v_team jsonb;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para iniciar a raid.'; end if;
  select * into v_room from public.coop_boss_rooms where room_code=upper(p_code) for update;
  if not found or v_room.host_id<>auth.uid() then raise exception 'Somente quem criou a sala pode iniciar.'; end if;
  if v_room.status<>'waiting' then raise exception 'A raid não está aguardando início.'; end if;
  for v_member in select value from jsonb_array_elements(v_room.members) loop
    v_user:=v_member->>'user_id'; v_team:=v_member->'team';
    select coalesce(jsonb_agg((p.value->>'maxHp')::integer order by p.ordinality),'[]'::jsonb) into v_hps
      from jsonb_array_elements(v_team) with ordinality p(value,ordinality);
    v_states:=jsonb_set(v_states,array[v_user],jsonb_build_object('hp',v_hps,'active',0),true);
  end loop;
  update public.coop_boss_rooms set status='battle',turn=1,turn_deadline=clock_timestamp()+interval '90 seconds',actions='{}'::jsonb,
    battle=jsonb_build_object('mewtwo_hp',30000,'mewtwo_max_hp',30000,'participants',v_states,'log',jsonb_build_array('Mewtwo surgiu! A equipe precisa agir em conjunto.')),
    updated_at=now() where id=v_room.id returning * into v_room;
  return to_jsonb(v_room);
end $$;

create or replace function public.coop_boss_act(p_code text,p_action jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_room public.coop_boss_rooms; v_member jsonb; v_user text; v_members jsonb; v_actions jsonb; v_battle jsonb;
  v_states jsonb; v_state jsonb; v_team jsonb; v_hp jsonb; v_active integer; v_action jsonb; v_move jsonb;
  v_boss_hp integer; v_attack integer; v_defense integer; v_power integer; v_damage integer; v_mult numeric;
  v_idx integer; v_move_idx integer; v_target jsonb; v_log jsonb; v_all_fainted boolean:=true; v_status text:='battle';
begin
  select * into v_room from public.coop_boss_rooms where room_code=upper(p_code) for update;
  if not found or v_room.status<>'battle' then raise exception 'A raid não está em andamento.'; end if;
  v_user:=auth.uid()::text;
  select value into v_member from jsonb_array_elements(v_room.members) where value->>'user_id'=v_user;
  if v_member is null then raise exception 'Você não participa desta raid.'; end if;
  if v_room.actions ? v_user then raise exception 'Sua ação deste turno já foi enviada.'; end if;
  if jsonb_typeof(p_action) is distinct from 'object' or p_action->>'type' not in ('move','switch','struggle','wait') then raise exception 'Ação inválida.'; end if;
  v_state:=v_room.battle->'participants'->v_user; v_team:=v_member->'team'; v_hp:=v_state->'hp'; v_active:=(v_state->>'active')::integer;
  if p_action->>'type'='wait' then
    if exists(select 1 from jsonb_array_elements_text(v_hp) h where h.value::integer>0) and clock_timestamp()<v_room.turn_deadline then raise exception 'Só é possível aguardar sem Pokémon saudável ou após o tempo da rodada.'; end if;
  elsif p_action->>'type'='switch' then
    if coalesce(p_action->>'index','') !~ '^[0-5]$' then raise exception 'Pokémon inválido.'; end if;
    v_idx:=(p_action->>'index')::integer;
    if v_idx>=jsonb_array_length(v_team) or (v_hp->>v_idx)::integer<=0 then raise exception 'Escolha um Pokémon saudável.'; end if;
    if v_idx=v_active and (v_hp->>v_active)::integer>0 then raise exception 'Esse Pokémon já está em campo.'; end if;
  elsif (v_hp->>v_active)::integer<=0 then raise exception 'Escolha um Pokémon saudável para continuar.';
  elsif p_action->>'type'='move' then
    if coalesce(p_action->>'index','') !~ '^[0-3]$' then raise exception 'Golpe inválido.'; end if;
    v_move_idx:=(p_action->>'index')::integer; v_move:=v_team->v_active->'moves'->v_move_idx;
    if v_move is null then raise exception 'Golpe inválido.'; end if;
  end if;
  v_actions:=jsonb_set(v_room.actions,array[v_user],p_action,true);
  if clock_timestamp()>=v_room.turn_deadline then
    for v_member in select value from jsonb_array_elements(v_room.members) loop
      v_user:=v_member->>'user_id';
      if not (v_actions ? v_user) then v_actions:=jsonb_set(v_actions,array[v_user],'{"type":"wait"}'::jsonb,true); end if;
    end loop;
  end if;
  if (select count(*) from jsonb_object_keys(v_actions)) < jsonb_array_length(v_room.members) then
    update public.coop_boss_rooms set actions=v_actions,updated_at=now() where id=v_room.id returning * into v_room;
    return to_jsonb(v_room);
  end if;

  v_battle:=v_room.battle; v_states:=v_battle->'participants'; v_boss_hp:=(v_battle->>'mewtwo_hp')::integer;
  v_log:=coalesce(v_battle->'log','[]'::jsonb);
  -- Resolve all trainer actions against the shared Mewtwo HP pool.
  for v_member in select value from jsonb_array_elements(v_room.members) loop
    v_user:=v_member->>'user_id'; v_state:=v_states->v_user; v_team:=v_member->'team'; v_hp:=v_state->'hp'; v_active:=(v_state->>'active')::integer; v_action:=v_actions->v_user;
    if v_action->>'type'='wait' then
      v_log:=v_log||jsonb_build_array((v_member->>'name')||' não conseguiu agir nesta rodada.');
    elsif v_action->>'type'='switch' then
      v_active:=(v_action->>'index')::integer;
      v_log:=v_log||jsonb_build_array((v_member->>'name')||' trocou para '||(v_team->v_active->>'name')||'.');
    elsif v_action->>'type'='struggle' then
      v_damage:=60;
      v_boss_hp:=greatest(0,v_boss_hp-v_damage);
      v_log:=v_log||jsonb_build_array((v_team->v_active->>'name')||' usou Esforço e causou '||v_damage||' de dano.');
    else
      v_move_idx:=(v_action->>'index')::integer; v_move:=v_team->v_active->'moves'->v_move_idx;
      v_power:=greatest(0,coalesce((v_move->>'power')::integer,0));
      v_attack:=coalesce((v_team->v_active->'stats'->>(case when v_move->>'category'='special' then 'specialAttack' else 'attack' end))::integer,50);
      v_defense:=150;
      v_mult:=public.pvp_type_multiplier(v_move->>'type','["Psiquico"]'::jsonb);
      v_damage:=case when v_power=0 or v_mult=0 then 0 else greatest(1,floor(((2*(v_team->v_active->>'level')::numeric/5+2)*v_power*v_attack/greatest(1,v_defense)/50+2)*v_mult*1.4)::integer) end;
      v_boss_hp:=greatest(0,v_boss_hp-v_damage);
      v_log:=v_log||jsonb_build_array((v_team->v_active->>'name')||' usou '||(v_move->>'name')||' e causou '||v_damage||' de dano.');
    end if;
    v_state:=jsonb_set(v_state,'{active}',to_jsonb(v_active),true); v_states:=jsonb_set(v_states,array[v_user],v_state,true);
  end loop;

  -- Mewtwo retaliates against each trainer that still has a conscious Pokémon.
  if v_boss_hp>0 then
    for v_member in select value from jsonb_array_elements(v_room.members) loop
      v_user:=v_member->>'user_id'; v_state:=v_states->v_user; v_team:=v_member->'team'; v_hp:=v_state->'hp'; v_active:=(v_state->>'active')::integer;
      if (v_hp->>v_active)::integer<=0 then
        for v_idx in 0..jsonb_array_length(v_team)-1 loop if (v_hp->>v_idx)::integer>0 then v_active:=v_idx; exit; end if; end loop;
      end if;
      if (v_hp->>v_active)::integer>0 then
        v_defense:=greatest(1,coalesce((v_team->v_active->'stats'->>'specialDefense')::integer,50));
        v_mult:=public.pvp_type_multiplier('Psiquico',v_team->v_active->'types');
        v_damage:=case when v_mult=0 then 0 else greatest(1,floor(((2*100/5+2)*90*150/v_defense/50+2)*v_mult*0.45)::integer) end;
        v_hp:=jsonb_set(v_hp,array[v_active::text],to_jsonb(greatest(0,(v_hp->>v_active)::integer-v_damage)),false);
        v_state:=jsonb_set(v_state,'{hp}',v_hp,true); v_state:=jsonb_set(v_state,'{active}',to_jsonb(v_active),true); v_states:=jsonb_set(v_states,array[v_user],v_state,true);
        v_log:=v_log||jsonb_build_array('Mewtwo atingiu a equipe de '||(v_member->>'name')||' por '||v_damage||' de dano.');
      end if;
    end loop;
  end if;
  if v_boss_hp<=0 then v_status:='won'; v_log:=v_log||jsonb_build_array('Mewtwo foi derrotado pela equipe!');
  else
    for v_member in select value from jsonb_array_elements(v_room.members) loop
      v_user:=v_member->>'user_id'; v_hp:=v_states->v_user->'hp';
      if exists(select 1 from jsonb_array_elements_text(v_hp) h where h.value::integer>0) then v_all_fainted:=false; end if;
    end loop;
    if v_all_fainted then v_status:='lost'; v_log:=v_log||jsonb_build_array('Todos os treinadores foram derrotados. Mewtwo venceu.'); end if;
  end if;
  v_battle:=jsonb_set(v_battle,'{mewtwo_hp}',to_jsonb(v_boss_hp),true); v_battle:=jsonb_set(v_battle,'{participants}',v_states,true); v_battle:=jsonb_set(v_battle,'{log}',(select coalesce(jsonb_agg(x order by ordinality),'[]'::jsonb) from jsonb_array_elements(v_log) with ordinality q(x,ordinality) where ordinality>greatest(0,jsonb_array_length(v_log)-20)),true);
  update public.coop_boss_rooms set battle=v_battle,status=v_status,turn=turn+1,turn_deadline=clock_timestamp()+interval '90 seconds',actions='{}'::jsonb,updated_at=now() where id=v_room.id returning * into v_room;
  return to_jsonb(v_room);
end $$;

revoke execute on function public.coop_boss_create(text,text,jsonb) from public,anon;
revoke execute on function public.coop_boss_join(text,text,jsonb) from public,anon;
revoke execute on function public.coop_boss_start(text) from public,anon;
revoke execute on function public.coop_boss_act(text,jsonb) from public,anon;
grant execute on function public.coop_boss_create(text,text,jsonb) to authenticated;
grant execute on function public.coop_boss_join(text,text,jsonb) to authenticated;
grant execute on function public.coop_boss_start(text) to authenticated;
grant execute on function public.coop_boss_act(text,jsonb) to authenticated;
do $$ begin
  if exists(select 1 from pg_catalog.pg_publication where pubname='supabase_realtime') and
     not exists(select 1 from pg_catalog.pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='coop_boss_rooms') then
    execute 'alter publication supabase_realtime add table public.coop_boss_rooms';
  end if;
end $$;
notify pgrst,'reload schema';
