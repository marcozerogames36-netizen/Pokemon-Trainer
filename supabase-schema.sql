create table if not exists public.game_saves (
  user_id uuid primary key references auth.users (id) on delete cascade,
  player jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.game_saves enable row level security;

revoke all on table public.game_saves from public, anon, authenticated;
grant select, insert, update, delete on table public.game_saves to authenticated;

drop policy if exists "Players can read their own save" on public.game_saves;
create policy "Players can read their own save"
  on public.game_saves for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "Players can create their own save" on public.game_saves;
create policy "Players can create their own save"
  on public.game_saves for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists "Players can update their own save" on public.game_saves;
create policy "Players can update their own save"
  on public.game_saves for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Players can delete their own save" on public.game_saves;
create policy "Players can delete their own save"
  on public.game_saves for delete to authenticated
  using ((select auth.uid()) = user_id);

-- Salas temporárias do PvP amistoso. Execute este arquivo no SQL Editor do Supabase.
create table if not exists public.pvp_rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text not null unique,
  host_id uuid not null references auth.users (id) on delete cascade,
  guest_id uuid references auth.users (id) on delete set null,
  host_name text not null,
  guest_name text,
  host_team jsonb not null,
  guest_team jsonb,
  status text not null default 'waiting' check (status in ('waiting','ready','battle','finished','cancelled')),
  battle jsonb not null default '{}'::jsonb,
  host_action jsonb,
  guest_action jsonb,
  turn integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '2 hours')
);

alter table public.pvp_rooms enable row level security;
alter table public.pvp_rooms replica identity full;
revoke all on table public.pvp_rooms from public, anon, authenticated;
grant select on table public.pvp_rooms to authenticated;

drop policy if exists "PvP participants can read their room" on public.pvp_rooms;
create policy "PvP participants can read their room"
  on public.pvp_rooms for select to authenticated
  using ((select auth.uid()) = host_id or (select auth.uid()) = guest_id);

create or replace function public.pvp_type_multiplier(p_move_type text, p_defender_types jsonb)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare v_chart jsonb; v_type text; v_result numeric := 1;
begin
  v_chart := case p_move_type
    when 'Normal' then '{"Pedra":0.5,"Aço":0.5,"Fantasma":0}'::jsonb
    when 'Fogo' then '{"Fogo":0.5,"Agua":0.5,"Planta":2,"Gelo":2,"Inseto":2,"Pedra":0.5,"Dragao":0.5,"Aço":2}'::jsonb
    when 'Agua' then '{"Fogo":2,"Agua":0.5,"Planta":0.5,"Terra":2,"Pedra":2,"Dragao":0.5}'::jsonb
    when 'Planta' then '{"Fogo":0.5,"Agua":2,"Planta":0.5,"Veneno":0.5,"Terra":2,"Voador":0.5,"Inseto":0.5,"Pedra":2,"Dragao":0.5,"Aço":0.5}'::jsonb
    when 'Eletrico' then '{"Agua":2,"Eletrico":0.5,"Planta":0.5,"Terra":0,"Voador":2,"Dragao":0.5}'::jsonb
    when 'Gelo' then '{"Fogo":0.5,"Agua":0.5,"Planta":2,"Gelo":0.5,"Terra":2,"Voador":2,"Dragao":2,"Aço":0.5}'::jsonb
    when 'Lutador' then '{"Normal":2,"Gelo":2,"Veneno":0.5,"Voador":0.5,"Psiquico":0.5,"Inseto":0.5,"Pedra":2,"Fantasma":0,"Sombrio":2,"Aço":2,"Fada":0.5}'::jsonb
    when 'Veneno' then '{"Planta":2,"Veneno":0.5,"Terra":0.5,"Pedra":0.5,"Fantasma":0.5,"Aço":0,"Fada":2}'::jsonb
    when 'Terra' then '{"Fogo":2,"Eletrico":2,"Planta":0.5,"Veneno":2,"Voador":0,"Inseto":0.5,"Pedra":2,"Aço":2}'::jsonb
    when 'Voador' then '{"Eletrico":0.5,"Planta":2,"Lutador":2,"Inseto":2,"Pedra":0.5,"Aço":0.5}'::jsonb
    when 'Psiquico' then '{"Lutador":2,"Veneno":2,"Psiquico":0.5,"Sombrio":0,"Aço":0.5}'::jsonb
    when 'Inseto' then '{"Fogo":0.5,"Planta":2,"Lutador":0.5,"Veneno":0.5,"Voador":0.5,"Psiquico":2,"Fantasma":0.5,"Sombrio":2,"Aço":0.5,"Fada":0.5}'::jsonb
    when 'Pedra' then '{"Fogo":2,"Gelo":2,"Lutador":0.5,"Terra":0.5,"Voador":2,"Inseto":2,"Aço":0.5}'::jsonb
    when 'Fantasma' then '{"Normal":0,"Psiquico":2,"Fantasma":2,"Sombrio":0.5}'::jsonb
    when 'Dragao' then '{"Aço":0.5,"Dragao":2,"Fada":0}'::jsonb
    when 'Sombrio' then '{"Lutador":0.5,"Psiquico":2,"Fantasma":2,"Sombrio":0.5,"Fada":0.5}'::jsonb
    when 'Aço' then '{"Fogo":0.5,"Agua":0.5,"Eletrico":0.5,"Gelo":2,"Pedra":2,"Aço":0.5,"Fada":2}'::jsonb
    when 'Fada' then '{"Fogo":0.5,"Lutador":2,"Veneno":0.5,"Dragao":2,"Sombrio":2,"Aço":0.5}'::jsonb
    else '{}'::jsonb
  end;
  if jsonb_typeof(p_defender_types) <> 'array' then return 1; end if;
  for v_type in select jsonb_array_elements_text(p_defender_types) loop
    v_result := v_result * coalesce((v_chart->>v_type)::numeric,1);
  end loop;
  return v_result;
end;
$$;

create or replace function public.pvp_valid_team(p_team jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_pokemon jsonb;
  v_move jsonb;
  v_type text;
  v_types text[] := array['Normal','Fogo','Agua','Planta','Eletrico','Gelo','Lutador','Veneno','Terra','Voador','Psiquico','Inseto','Pedra','Fantasma','Dragao','Sombrio','Aço','Fada'];
  v_stats text[] := array['hp','attack','defense','specialAttack','specialDefense','speed'];
begin
  if jsonb_typeof(p_team) is distinct from 'array' then return false; end if;
  if jsonb_array_length(p_team) < 1 or jsonb_array_length(p_team) > 6 then return false; end if;
  for v_pokemon in select jsonb_array_elements(p_team) loop
    if jsonb_typeof(v_pokemon) is distinct from 'object' or jsonb_typeof(v_pokemon->'moves') is distinct from 'array' or
       jsonb_typeof(v_pokemon->'types') is distinct from 'array' or jsonb_array_length(v_pokemon->'types') not between 1 and 2 or
       jsonb_typeof(v_pokemon->'ivs') is distinct from 'object' or jsonb_typeof(v_pokemon->'evs') is distinct from 'object' then return false; end if;
    if (v_pokemon->>'id')::integer not between 1 and 1025 or (v_pokemon->>'level')::integer not between 1 and 100 or
       (v_pokemon->>'maxHp')::integer not between 1 and 10000 or jsonb_array_length(v_pokemon->'moves') > 4 then return false; end if;
    for v_type in select jsonb_array_elements_text(v_pokemon->'types') loop
      if not (v_type = any(v_types)) then return false; end if;
    end loop;
    foreach v_type in array v_stats loop
      if jsonb_typeof(v_pokemon->'ivs'->v_type) is distinct from 'number' or (v_pokemon->'ivs'->>v_type)::integer not between 0 and 31 then return false; end if;
      if jsonb_typeof(v_pokemon->'evs'->v_type) is distinct from 'number' or (v_pokemon->'evs'->>v_type)::integer not between 0 and 252 then return false; end if;
    end loop;
    for v_move in select jsonb_array_elements(v_pokemon->'moves') loop
      if jsonb_typeof(v_move) is distinct from 'object' or jsonb_typeof(v_move->'power') is distinct from 'number' or
         (v_move->>'power')::integer not between 1 and 250 or not coalesce((v_move->>'type') = any(v_types),false) or
         jsonb_typeof(v_move->'accuracy') is distinct from 'number' or (v_move->>'accuracy')::numeric not between 1 and 100 or
         (v_move->>'maxPp')::integer not between 1 and 100 then return false; end if;
    end loop;
  end loop;
  return true;
exception when others then
  return false;
end;
$$;

-- Remove interim signatures if an earlier draft of the PvP schema was applied.
drop function if exists public.pvp_start_room(text,jsonb);
drop function if exists public.pvp_resolve_turn(text,jsonb,text);

create or replace function public.pvp_create_room(p_code text, p_trainer text, p_team jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_room public.pvp_rooms;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para criar uma sala.'; end if;
  if p_code !~ '^[A-HJ-NP-Z2-9]{6}$' then raise exception 'Código de sala inválido.'; end if;
  if not public.pvp_valid_team(p_team) then
    raise exception 'Escolha entre 1 e 6 Pokémon.';
  end if;
  insert into public.pvp_rooms (room_code, host_id, host_name, host_team)
  values (p_code, auth.uid(), left(trim(coalesce(p_trainer, 'Treinador')), 24), p_team)
  returning * into v_room;
  return to_jsonb(v_room);
end;
$$;

create or replace function public.pvp_join_room(p_code text, p_trainer text, p_team jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_room public.pvp_rooms;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para entrar em uma sala.'; end if;
  if not public.pvp_valid_team(p_team) then
    raise exception 'Escolha entre 1 e 6 Pokémon.';
  end if;
  update public.pvp_rooms
    set guest_id = auth.uid(), guest_name = left(trim(coalesce(p_trainer, 'Treinador')), 24),
        guest_team = p_team, status = 'ready', updated_at = now()
    where room_code = upper(p_code) and status = 'waiting' and guest_id is null
      and host_id <> auth.uid() and expires_at > now()
    returning * into v_room;
  if not found then raise exception 'Sala não encontrada, expirada ou já ocupada.'; end if;
  return to_jsonb(v_room);
end;
$$;

create or replace function public.pvp_start_room(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_room public.pvp_rooms; v_host_hp jsonb; v_guest_hp jsonb; v_host_pp jsonb; v_guest_pp jsonb; v_battle jsonb;
begin
  select * into v_room from public.pvp_rooms where room_code = upper(p_code) for update;
  if not found or not (v_room.host_id is not distinct from auth.uid() or v_room.guest_id is not distinct from auth.uid()) then
    raise exception 'Você não participa desta sala.';
  end if;
  if v_room.status = 'battle' then return to_jsonb(v_room); end if;
  if v_room.status <> 'ready' or v_room.guest_id is null then
    raise exception 'A sala ainda não está pronta para começar.';
  end if;
  select jsonb_agg((p.pokemon->>'maxHp')::integer order by p.ordinality),
    jsonb_agg(coalesce((select jsonb_agg(coalesce((m.move->>'maxPp')::integer,1) order by m.ordinality)
      from jsonb_array_elements(p.pokemon->'moves') with ordinality as m(move,ordinality)),'[]'::jsonb) order by p.ordinality)
    into v_host_hp,v_host_pp from jsonb_array_elements(v_room.host_team) with ordinality as p(pokemon,ordinality);
  select jsonb_agg((p.pokemon->>'maxHp')::integer order by p.ordinality),
    jsonb_agg(coalesce((select jsonb_agg(coalesce((m.move->>'maxPp')::integer,1) order by m.ordinality)
      from jsonb_array_elements(p.pokemon->'moves') with ordinality as m(move,ordinality)),'[]'::jsonb) order by p.ordinality)
    into v_guest_hp,v_guest_pp from jsonb_array_elements(v_room.guest_team) with ordinality as p(pokemon,ordinality);
  v_battle := jsonb_build_object('hostActive',0,'guestActive',0,'hostHp',v_host_hp,'guestHp',v_guest_hp,
    'hostPp',v_host_pp,'guestPp',v_guest_pp,
    'log',jsonb_build_array('A batalha entre '||v_room.host_name||' e '||v_room.guest_name||' começou!'),
    'winner_user_id',null,'result','');
  update public.pvp_rooms set status='battle',battle=v_battle,turn=1,updated_at=now()
    where id=v_room.id returning * into v_room;
  return to_jsonb(v_room);
end;
$$;

create or replace function public.pvp_submit_action(p_code text, p_action jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.pvp_rooms;
  v_is_host boolean;
  v_team jsonb;
  v_active integer;
  v_index integer;
  v_action_type text;
  v_hp numeric;
  v_move jsonb;
  v_pp integer;
  v_pp_state jsonb;
begin
  select * into v_room from public.pvp_rooms where room_code = upper(p_code) for update;
  if not found or v_room.status <> 'battle' then raise exception 'A sala não está em batalha.'; end if;
  v_is_host := v_room.host_id = auth.uid();
  if not v_is_host and v_room.guest_id is distinct from auth.uid() then raise exception 'Você não participa desta sala.'; end if;
  v_action_type := p_action->>'type';
  if v_action_type is null or v_action_type not in ('move','switch','struggle') then raise exception 'Ação de batalha inválida.'; end if;
  if coalesce(p_action->>'index','') !~ '^-?[0-9]+$' then raise exception 'Índice de ação inválido.'; end if;
  v_index := (p_action->>'index')::integer;
  v_team := case when v_is_host then v_room.host_team else v_room.guest_team end;
  v_active := coalesce((v_room.battle->>(case when v_is_host then 'hostActive' else 'guestActive' end))::integer,0);
  v_hp := coalesce((v_room.battle->(case when v_is_host then 'hostHp' else 'guestHp' end)->>v_active)::numeric,0);
  if v_action_type = 'switch' then
    if v_index < 0 or v_index >= jsonb_array_length(v_team) then raise exception 'Pokémon inválido para troca.'; end if;
    v_hp := coalesce((v_room.battle->(case when v_is_host then 'hostHp' else 'guestHp' end)->>v_index)::numeric,0);
    if v_index = v_active or v_hp <= 0 then raise exception 'Esse Pokémon não pode entrar na batalha.'; end if;
  elsif v_action_type = 'move' then
    if v_hp <= 0 then raise exception 'Troque o Pokémon desmaiado antes de agir.'; end if;
    if v_index < 0 or v_index > 3 then raise exception 'Golpe inválido.'; end if;
    v_move := v_team->v_active->'moves'->v_index;
    v_pp := coalesce((v_room.battle->(case when v_is_host then 'hostPp' else 'guestPp' end)->v_active->>v_index)::integer,0);
    if v_move is null or coalesce((v_move->>'power')::integer,0) <= 0 or v_pp <= 0 then
      raise exception 'Esse golpe não está disponível.';
    end if;
  end if;
  if v_action_type = 'struggle' then
    if v_hp <= 0 then raise exception 'Troque o Pokémon desmaiado antes de agir.'; end if;
    v_pp_state := v_room.battle->(case when v_is_host then 'hostPp' else 'guestPp' end)->v_active;
    if exists(select 1 from jsonb_array_elements_text(coalesce(v_pp_state,'[]'::jsonb)) pp(value) where pp.value::integer>0) then
      raise exception 'Struggle só pode ser usado quando todos os golpes estiverem sem PP.';
    end if;
  end if;
  if v_is_host then
    if v_room.host_action is not null then raise exception 'Você já enviou sua ação neste turno.'; end if;
    update public.pvp_rooms set host_action = p_action, updated_at = now() where id = v_room.id returning * into v_room;
  else
    if v_room.guest_action is not null then raise exception 'Você já enviou sua ação neste turno.'; end if;
    update public.pvp_rooms set guest_action = p_action, updated_at = now() where id = v_room.id returning * into v_room;
  end if;
  return to_jsonb(v_room);
end;
$$;

create or replace function public.pvp_resolve_turn(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.pvp_rooms;
  v_state jsonb;
  v_logs jsonb;
  v_host_active integer;
  v_guest_active integer;
  v_action jsonb;
  v_move jsonb;
  v_attacker jsonb;
  v_defender jsonb;
  v_attacker_side text;
  v_defender_side text;
  v_attacker_team jsonb;
  v_defender_team jsonb;
  v_attacker_index integer;
  v_defender_index integer;
  v_move_index integer;
  v_move_type text;
  v_move_name text;
  v_power numeric;
  v_accuracy numeric;
  v_pp integer;
  v_current_hp numeric;
  v_damage numeric;
  v_type_mult numeric;
  v_stab numeric;
  v_attack_mult numeric;
  v_defense_mult numeric;
  v_ability_mult numeric;
  v_level numeric;
  v_def_level numeric;
  v_physical boolean;
  v_critical boolean;
  v_host_speed numeric;
  v_guest_speed numeric;
  v_order text[];
  v_side text;
  v_temp_index integer;
  v_host_alive boolean;
  v_guest_alive boolean;
  v_winner uuid;
  v_status text := 'battle';
begin
  select * into v_room from public.pvp_rooms where room_code = upper(p_code) for update;
  if not found or not (v_room.host_id is not distinct from auth.uid() or v_room.guest_id is not distinct from auth.uid()) then
    raise exception 'Você não participa desta sala.';
  end if;
  if v_room.status <> 'battle' or v_room.host_action is null or v_room.guest_action is null then return to_jsonb(v_room); end if;
  v_state := v_room.battle;
  v_logs := coalesce(v_state->'log','[]'::jsonb);
  v_host_active := coalesce((v_state->>'hostActive')::integer,0);
  v_guest_active := coalesce((v_state->>'guestActive')::integer,0);

  -- Trocas são aplicadas antes dos ataques do turno.
  foreach v_side in array array['host','guest']::text[] loop
    v_action := case when v_side='host' then v_room.host_action else v_room.guest_action end;
    if v_action->>'type'='switch' then
      v_temp_index := (v_action->>'index')::integer;
      if v_side='host' then v_host_active := v_temp_index; else v_guest_active := v_temp_index; end if;
      v_logs := v_logs || jsonb_build_array(((case when v_side='host' then v_room.host_team else v_room.guest_team end)->v_temp_index->>'name') || ' entrou na batalha.');
    end if;
  end loop;
  v_state := jsonb_set(v_state,'{hostActive}',to_jsonb(v_host_active),true);
  v_state := jsonb_set(v_state,'{guestActive}',to_jsonb(v_guest_active),true);

  v_host_speed := coalesce((v_room.host_team->v_host_active->>'level')::numeric,1) *
    (1 + ((coalesce((v_room.host_team->v_host_active->'ivs'->>'speed')::numeric,15)-15.5)/250 + coalesce((v_room.host_team->v_host_active->'evs'->>'speed')::numeric,0)/800));
  v_guest_speed := coalesce((v_room.guest_team->v_guest_active->>'level')::numeric,1) *
    (1 + ((coalesce((v_room.guest_team->v_guest_active->'ivs'->>'speed')::numeric,15)-15.5)/250 + coalesce((v_room.guest_team->v_guest_active->'evs'->>'speed')::numeric,0)/800));
  if v_room.host_action->>'type' in ('move','struggle') and v_room.guest_action->>'type' in ('move','struggle') then
    if v_host_speed > v_guest_speed or (v_host_speed = v_guest_speed and random() < 0.5) then v_order := array['host','guest'];
    else v_order := array['guest','host']; end if;
  elsif v_room.host_action->>'type' in ('move','struggle') then v_order := array['host'];
  elsif v_room.guest_action->>'type' in ('move','struggle') then v_order := array['guest'];
  else v_order := array[]::text[]; end if;

  foreach v_attacker_side in array v_order loop
    v_defender_side := case when v_attacker_side='host' then 'guest' else 'host' end;
    v_action := case when v_attacker_side='host' then v_room.host_action else v_room.guest_action end;
    v_attacker_team := case when v_attacker_side='host' then v_room.host_team else v_room.guest_team end;
    v_defender_team := case when v_defender_side='host' then v_room.host_team else v_room.guest_team end;
    v_attacker_index := case when v_attacker_side='host' then v_host_active else v_guest_active end;
    v_defender_index := case when v_defender_side='host' then v_host_active else v_guest_active end;
    v_attacker := v_attacker_team->v_attacker_index;
    v_defender := v_defender_team->v_defender_index;
    if coalesce((v_state->(v_attacker_side||'Hp')->>v_attacker_index)::numeric,0)<=0 or
       coalesce((v_state->(v_defender_side||'Hp')->>v_defender_index)::numeric,0)<=0 then continue; end if;
    if v_action->>'type'='struggle' then
      v_move := '{"name":"Struggle","power":50,"type":"Normal","accuracy":100}'::jsonb;
      v_move_index := -1;
    else
      v_move_index := (v_action->>'index')::integer;
      v_move := v_attacker->'moves'->v_move_index;
      v_pp := coalesce((v_state->(v_attacker_side||'Pp')->v_attacker_index->>v_move_index)::integer,0);
      v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'Pp',v_attacker_index::text,v_move_index::text],to_jsonb(greatest(v_pp-1,0)),false);
    end if;
    v_move_name := coalesce(v_move->>'name','Golpe');
    v_move_type := coalesce(v_move->>'type','Normal');
    v_power := coalesce((v_move->>'power')::numeric,0);
    v_accuracy := coalesce((v_move->>'accuracy')::numeric,100);
    if random()*100 >= v_accuracy then
      v_logs := v_logs || jsonb_build_array((v_attacker->>'name')||' errou '||v_move_name||'!');
      continue;
    end if;
    v_type_mult := public.pvp_type_multiplier(v_move_type,v_defender->'types');
    if (v_defender->>'ability'='Levitate' and v_move_type='Terra') or
       (v_defender->>'ability'='Water Absorb' and v_move_type='Agua') or
       (v_defender->>'ability'='Volt Absorb' and v_move_type='Eletrico') or
       (v_defender->>'ability'='Flash Fire' and v_move_type='Fogo') then v_type_mult := 0; end if;
    v_stab := case when coalesce(v_attacker->'types','[]'::jsonb) ? v_move_type then 1.5 else 1 end;
    if v_attacker->>'ability'='Adaptabilidade' and v_stab>1 then v_stab:=2; end if;
    v_level := greatest(1,coalesce((v_attacker->>'level')::numeric,1));
    v_def_level := greatest(1,coalesce((v_defender->>'level')::numeric,1));
    v_physical := v_move_type in ('Normal','Lutador','Voador','Veneno','Terra','Pedra','Inseto','Fantasma','Aço');
    v_attack_mult := greatest(0.85,least(1.35,1+((coalesce((v_attacker->'ivs'->>(case when v_physical then 'attack' else 'specialAttack' end))::numeric,15)-15.5)/250 + coalesce((v_attacker->'evs'->>(case when v_physical then 'attack' else 'specialAttack' end))::numeric,0)/800)*v_level/100));
    v_defense_mult := greatest(0.85,least(1.35,1+((coalesce((v_defender->'ivs'->>(case when v_physical then 'defense' else 'specialDefense' end))::numeric,15)-15.5)/250 + coalesce((v_defender->'evs'->>(case when v_physical then 'defense' else 'specialDefense' end))::numeric,0)/800)*v_def_level/100));
    v_ability_mult := 1;
    if v_attacker->>'ability' in ('Overgrow','Blaze','Torrent','Swarm') and
       ((v_attacker->>'ability'='Overgrow' and v_move_type='Planta') or (v_attacker->>'ability'='Blaze' and v_move_type='Fogo') or (v_attacker->>'ability'='Torrent' and v_move_type='Agua') or (v_attacker->>'ability'='Swarm' and v_move_type='Inseto')) and
       coalesce((v_state->(v_attacker_side||'Hp')->>v_attacker_index)::numeric,0) <= coalesce((v_attacker->>'maxHp')::numeric,1)/3 then v_ability_mult:=v_ability_mult*1.5; end if;
    if v_physical and v_defender->>'ability'='Intimidate' then v_ability_mult:=v_ability_mult*0.75; end if;
    if v_move_type in ('Fogo','Gelo') and v_defender->>'ability'='Thick Fat' then v_ability_mult:=v_ability_mult*0.5; end if;
    v_critical := random()<1.0/16.0;
    if v_power<=0 or v_type_mult=0 then v_damage:=0;
    else
      v_damage := greatest(1,floor(((((2*v_level/5)+2)*v_power/50+2)*v_stab*v_type_mult*(0.85+random()*0.15))*(v_attack_mult/v_defense_mult)*v_ability_mult*(case when v_critical then 1.5 else 1 end)));
    end if;
    v_current_hp := coalesce((v_state->(v_defender_side||'Hp')->>v_defender_index)::numeric,0);
    v_state := jsonb_set(v_state,ARRAY[v_defender_side||'Hp',v_defender_index::text],to_jsonb(greatest(0,v_current_hp-v_damage)),false);
    v_logs := v_logs || jsonb_build_array(case when v_damage=0 then (v_attacker->>'name')||' usou '||v_move_name||', mas não causou dano.'
      else (v_attacker->>'name')||' usou '||v_move_name||' e causou '||v_damage::integer||' de dano.'||case when v_critical then ' Crítico!' else '' end||case when v_type_mult>=2 then ' Super efetivo!' when v_type_mult>0 and v_type_mult<1 then ' Pouco efetivo.' else '' end end);
  end loop;

  v_state := jsonb_set(v_state,'{log}',v_logs,true);
  select exists(select 1 from jsonb_array_elements_text(v_state->'hostHp') h(value) where h.value::numeric>0) into v_host_alive;
  select exists(select 1 from jsonb_array_elements_text(v_state->'guestHp') h(value) where h.value::numeric>0) into v_guest_alive;
  if not v_host_alive or not v_guest_alive then
    v_status := 'finished';
    v_winner := case when v_host_alive then v_room.host_id when v_guest_alive then v_room.guest_id else null end;
    v_state := v_state || jsonb_build_object('winner_user_id',v_winner,'result','normal');
    v_logs := v_logs || jsonb_build_array(case when v_host_alive then v_room.host_name||' venceu a batalha!' when v_guest_alive then v_room.guest_name||' venceu a batalha!' else 'A batalha terminou empatada.' end);
    v_state := jsonb_set(v_state,'{log}',v_logs,true);
  end if;
  update public.pvp_rooms set battle=v_state,status=v_status,host_action=null,guest_action=null,
    turn=turn+1,updated_at=now() where id=v_room.id returning * into v_room;
  return to_jsonb(v_room);
end;
$$;

create or replace function public.pvp_leave_room(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_room public.pvp_rooms; v_winner uuid;
begin
  select * into v_room from public.pvp_rooms where room_code = upper(p_code) for update;
  if not found or not (v_room.host_id is not distinct from auth.uid() or v_room.guest_id is not distinct from auth.uid()) then
    raise exception 'Sala não encontrada ou você não participa dela.';
  end if;
  if v_room.status not in ('finished','cancelled') then
    v_winner := case when auth.uid() = v_room.host_id then v_room.guest_id else v_room.host_id end;
    update public.pvp_rooms set status = case when v_room.guest_id is null then 'cancelled' else 'finished' end,
      battle = coalesce(v_room.battle,'{}'::jsonb) || jsonb_build_object('winner_user_id',v_winner,'result','abandoned'),
      host_action = null, guest_action = null, updated_at = now()
      where id = v_room.id returning * into v_room;
  end if;
  return to_jsonb(v_room);
end;
$$;

revoke execute on function public.pvp_create_room(text,text,jsonb) from public, anon;
revoke execute on function public.pvp_join_room(text,text,jsonb) from public, anon;
revoke execute on function public.pvp_type_multiplier(text,jsonb) from public, anon, authenticated;
revoke execute on function public.pvp_valid_team(jsonb) from public, anon, authenticated;
revoke execute on function public.pvp_start_room(text) from public, anon;
revoke execute on function public.pvp_submit_action(text,jsonb) from public, anon;
revoke execute on function public.pvp_resolve_turn(text) from public, anon;
revoke execute on function public.pvp_leave_room(text) from public, anon;
grant execute on function public.pvp_create_room(text,text,jsonb) to authenticated;
grant execute on function public.pvp_join_room(text,text,jsonb) to authenticated;
grant execute on function public.pvp_start_room(text) to authenticated;
grant execute on function public.pvp_submit_action(text,jsonb) to authenticated;
grant execute on function public.pvp_resolve_turn(text) to authenticated;
grant execute on function public.pvp_leave_room(text) to authenticated;

do $$
begin
  if exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_catalog.pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pvp_rooms') then
    execute 'alter publication supabase_realtime add table public.pvp_rooms';
  end if;
end;
$$;
