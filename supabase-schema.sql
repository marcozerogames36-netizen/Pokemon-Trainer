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
  turn_deadline timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '2 hours')
);

alter table public.pvp_rooms add column if not exists turn_deadline timestamptz;
update public.pvp_rooms set turn_deadline = now() + interval '45 seconds'
  where status = 'battle' and turn_deadline is null;
-- Normalize open rooms that predate battle stages and status tracking.
update public.pvp_rooms r set battle = r.battle || jsonb_build_object(
  'hostStages', coalesce(r.battle->'hostStages',(select jsonb_agg(jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0) order by p.ordinality) from jsonb_array_elements(r.host_team) with ordinality p(pokemon,ordinality))),
  'guestStages', coalesce(r.battle->'guestStages',(select jsonb_agg(jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0) order by p.ordinality) from jsonb_array_elements(r.guest_team) with ordinality p(pokemon,ordinality))),
  'hostStatus', coalesce(r.battle->'hostStatus',(select jsonb_agg('null'::jsonb order by p.ordinality) from jsonb_array_elements(r.host_team) with ordinality p(pokemon,ordinality))),
  'guestStatus', coalesce(r.battle->'guestStatus',(select jsonb_agg('null'::jsonb order by p.ordinality) from jsonb_array_elements(r.guest_team) with ordinality p(pokemon,ordinality)))
) where r.status='battle';

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
    when 'Normal' then '{"Pedra":0.5,"A\u00e7o":0.5,"Fantasma":0}'::jsonb
    when 'Fogo' then '{"Fogo":0.5,"Agua":0.5,"Planta":2,"Gelo":2,"Inseto":2,"Pedra":0.5,"Dragao":0.5,"A\u00e7o":2,"Fada":0.5}'::jsonb
    when 'Agua' then '{"Fogo":2,"Agua":0.5,"Planta":0.5,"Terra":2,"Pedra":2,"Dragao":0.5}'::jsonb
    when 'Planta' then '{"Fogo":0.5,"Agua":2,"Planta":0.5,"Veneno":0.5,"Terra":2,"Voador":0.5,"Inseto":0.5,"Pedra":2,"Dragao":0.5,"A\u00e7o":0.5}'::jsonb
    when 'Eletrico' then '{"Agua":2,"Eletrico":0.5,"Planta":0.5,"Terra":0,"Voador":2,"Dragao":0.5}'::jsonb
    when 'Gelo' then '{"Fogo":0.5,"Agua":0.5,"Planta":2,"Gelo":0.5,"Terra":2,"Voador":2,"Dragao":2,"A\u00e7o":0.5}'::jsonb
    when 'Lutador' then '{"Normal":2,"Gelo":2,"Veneno":0.5,"Voador":0.5,"Psiquico":0.5,"Inseto":0.5,"Pedra":2,"Fantasma":0,"Sombrio":2,"A\u00e7o":2,"Fada":0.5}'::jsonb
    when 'Veneno' then '{"Planta":2,"Veneno":0.5,"Terra":0.5,"Pedra":0.5,"Fantasma":0.5,"A\u00e7o":0,"Fada":2}'::jsonb
    when 'Terra' then '{"Fogo":2,"Eletrico":2,"Planta":0.5,"Veneno":2,"Voador":0,"Inseto":0.5,"Pedra":2,"A\u00e7o":2}'::jsonb
    when 'Voador' then '{"Eletrico":0.5,"Planta":2,"Lutador":2,"Inseto":2,"Pedra":0.5,"A\u00e7o":0.5}'::jsonb
    when 'Psiquico' then '{"Lutador":2,"Veneno":2,"Psiquico":0.5,"Sombrio":0,"A\u00e7o":0.5}'::jsonb
    when 'Inseto' then '{"Fogo":0.5,"Planta":2,"Lutador":0.5,"Veneno":0.5,"Voador":0.5,"Psiquico":2,"Fantasma":0.5,"Sombrio":2,"A\u00e7o":0.5}'::jsonb
    when 'Pedra' then '{"Fogo":2,"Gelo":2,"Lutador":0.5,"Terra":0.5,"Voador":2,"Inseto":2,"A\u00e7o":0.5}'::jsonb
    when 'Fantasma' then '{"Normal":0,"Psiquico":2,"Fantasma":2,"Sombrio":0.5}'::jsonb
    when 'Dragao' then '{"Dragao":2,"Fada":0}'::jsonb
    when 'Sombrio' then '{"Lutador":0.5,"Psiquico":2,"Fantasma":2,"Sombrio":0.5,"Fada":0.5}'::jsonb
    when 'A'||chr(231)||'o' then '{"Fogo":0.5,"Agua":0.5,"Eletrico":0.5,"Gelo":2,"Pedra":2,"A\u00e7o":0.5,"Fada":2}'::jsonb
    when 'Fada' then '{"Fogo":0.5,"Lutador":2,"Veneno":0.5,"Dragao":2,"Sombrio":2,"A\u00e7o":0.5}'::jsonb
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
  v_types text[] := array['Normal','Fogo','Agua','Planta','Eletrico','Gelo','Lutador','Veneno','Terra','Voador','Psiquico','Inseto','Pedra','Fantasma','Dragao','Sombrio','A'||chr(231)||'o','Fada'];
  v_stats text[] := array['hp','attack','defense','specialAttack','specialDefense','speed'];
begin
  if jsonb_typeof(p_team) is distinct from 'array' then return false; end if;
  if jsonb_array_length(p_team) < 1 or jsonb_array_length(p_team) > 6 then return false; end if;
  for v_pokemon in select jsonb_array_elements(p_team) loop
    if jsonb_typeof(v_pokemon) is distinct from 'object' or jsonb_typeof(v_pokemon->'moves') is distinct from 'array' or
       jsonb_typeof(v_pokemon->'types') is distinct from 'array' or jsonb_array_length(v_pokemon->'types') not between 1 and 2 or
       jsonb_typeof(v_pokemon->'ivs') is distinct from 'object' or jsonb_typeof(v_pokemon->'evs') is distinct from 'object' or
       jsonb_typeof(v_pokemon->'stats') is distinct from 'object' then return false; end if;
    if (v_pokemon->>'id')::integer not between 1 and 1025 or (v_pokemon->>'level')::integer not between 1 and 100 or
       (v_pokemon->>'maxHp')::integer not between 1 and 10000 or jsonb_array_length(v_pokemon->'moves') > 4 then return false; end if;
    for v_type in select jsonb_array_elements_text(v_pokemon->'types') loop
      if not (v_type = any(v_types)) then return false; end if;
    end loop;
    foreach v_type in array v_stats loop
      if jsonb_typeof(v_pokemon->'ivs'->v_type) is distinct from 'number' or (v_pokemon->'ivs'->>v_type)::integer not between 0 and 31 then return false; end if;
      if jsonb_typeof(v_pokemon->'evs'->v_type) is distinct from 'number' or (v_pokemon->'evs'->>v_type)::integer not between 0 and 252 then return false; end if;
      if jsonb_typeof(v_pokemon->'stats'->v_type) is distinct from 'number' or (v_pokemon->'stats'->>v_type)::integer not between 1 and 1000 then return false; end if;
    end loop;
    for v_move in select jsonb_array_elements(v_pokemon->'moves') loop
      if jsonb_typeof(v_move) is distinct from 'object' or coalesce(v_move->>'category','physical') not in ('physical','special','status') or jsonb_typeof(v_move->'power') is distinct from 'number' or
         (v_move->>'power')::integer not between 0 and 250 or not coalesce((v_move->>'type') = any(v_types),false) or
         jsonb_typeof(v_move->'accuracy') is distinct from 'number' or (v_move->>'accuracy')::numeric not between 1 and 100 or
         (v_move->>'maxPp')::integer not between 1 and 100 or
         coalesce((v_move->>'priority')::integer,0) not between -7 and 7 or
         ((v_move->>'power')::integer=0 and coalesce(jsonb_array_length(v_move->'statChanges'),0)=0 and v_move->'statusEffect' is null and
          coalesce((v_move->>'healing')::integer,0)<=0 and coalesce((v_move->>'drain')::integer,0)<=0) then return false; end if;
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
declare v_room public.pvp_rooms; v_host_hp jsonb; v_guest_hp jsonb; v_host_pp jsonb; v_guest_pp jsonb; v_host_stages jsonb; v_guest_stages jsonb; v_host_status jsonb; v_guest_status jsonb; v_battle jsonb;
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
  select jsonb_agg(jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0) order by ordinality)
    into v_host_stages from jsonb_array_elements(v_room.host_team) with ordinality as p(pokemon,ordinality);
  select jsonb_agg(jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0) order by ordinality)
    into v_guest_stages from jsonb_array_elements(v_room.guest_team) with ordinality as p(pokemon,ordinality);
  select jsonb_agg('null'::jsonb order by ordinality) into v_host_status from jsonb_array_elements(v_room.host_team) with ordinality as p(pokemon,ordinality);
  select jsonb_agg('null'::jsonb order by ordinality) into v_guest_status from jsonb_array_elements(v_room.guest_team) with ordinality as p(pokemon,ordinality);
  if v_room.host_team->0->>'ability'='Intimidate' then v_guest_stages := jsonb_set(v_guest_stages,'{0,attack}','-1'::jsonb,true); end if;
  if v_room.guest_team->0->>'ability'='Intimidate' then v_host_stages := jsonb_set(v_host_stages,'{0,attack}','-1'::jsonb,true); end if;
  v_battle := jsonb_build_object('hostActive',0,'guestActive',0,'hostHp',v_host_hp,'guestHp',v_guest_hp,
    'hostPp',v_host_pp,'guestPp',v_guest_pp,'hostStages',v_host_stages,'guestStages',v_guest_stages,
    'hostStatus',v_host_status,'guestStatus',v_guest_status,
    'log',jsonb_build_array('A batalha entre '||v_room.host_name||' e '||v_room.guest_name||' começou!'),
    'winner_user_id',null,'result','');
  update public.pvp_rooms set status='battle',battle=v_battle,turn=1,turn_deadline=clock_timestamp()+interval '45 seconds',updated_at=now()
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
  if v_room.turn_deadline is not null and v_room.turn_deadline <= clock_timestamp() then raise exception 'O tempo da jogada acabou; o turno está sendo resolvido.'; end if;
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
    if v_move is null or v_pp <= 0 then
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
  v_attack_value numeric;
  v_defense_value numeric;
  v_attack_stage numeric;
  v_defense_stage numeric;
  v_move_priority integer;
  v_host_priority integer;
  v_guest_priority integer;
  v_stage_effect jsonb;
  v_major_status jsonb;
  v_status_name text;
  v_status_chance numeric;
  v_status_immune boolean;
  v_residual numeric;
  v_healing numeric;
  v_max_hp numeric;
  v_stage_stat text;
  v_stage_target text;
  v_stage_index integer;
  v_stage_side text;
  v_stage_amount integer;
  v_accuracy_stage numeric;
  v_evasion_stage numeric;
  v_level numeric;
  v_def_level numeric;
  v_physical boolean;
  v_critical boolean;
  v_host_speed numeric;
  v_guest_speed numeric;
  v_order text[];
  v_side text;
  v_temp_index integer;
  v_side_team jsonb;
  v_side_hp jsonb;
  v_side_pp jsonb;
  v_side_active integer;
  v_host_alive boolean;
  v_guest_alive boolean;
  v_winner uuid;
  v_status text := 'battle';
begin
  select * into v_room from public.pvp_rooms where room_code = upper(p_code) for update;
  if not found or not (v_room.host_id is not distinct from auth.uid() or v_room.guest_id is not distinct from auth.uid()) then
    raise exception 'Você não participa desta sala.';
  end if;
  if v_room.status <> 'battle' then return to_jsonb(v_room); end if;
  if (v_room.host_action is null or v_room.guest_action is null) and
     (v_room.turn_deadline is null or v_room.turn_deadline > clock_timestamp()) then return to_jsonb(v_room); end if;

  -- Ao expirar o relógio, escolhe uma ação simples para o lado que não jogou.
  if v_room.host_action is null or v_room.guest_action is null then
    foreach v_side in array array['host','guest']::text[] loop
      v_action := case when v_side='host' then v_room.host_action else v_room.guest_action end;
      if v_action is not null then continue; end if;
      v_side_team := case when v_side='host' then v_room.host_team else v_room.guest_team end;
      v_side_hp := v_room.battle->(v_side||'Hp');
      v_side_pp := v_room.battle->(v_side||'Pp');
      v_side_active := coalesce((v_room.battle->>(v_side||'Active'))::integer,0);
      v_action := null;
      if coalesce((v_side_hp->>v_side_active)::integer,0) > 0 then
        if jsonb_array_length(v_side_team->v_side_active->'moves') > 0 then
          for v_temp_index in 0..(jsonb_array_length(v_side_team->v_side_active->'moves')-1) loop
            if coalesce((v_side_pp->v_side_active->>v_temp_index)::integer,0) > 0 then
              v_action := jsonb_build_object('type','move','index',v_temp_index);
              exit;
            end if;
          end loop;
        end if;
        if v_action is null then v_action := jsonb_build_object('type','struggle','index',-1); end if;
      else
        for v_temp_index in 0..(jsonb_array_length(v_side_team)-1) loop
          if v_temp_index <> v_side_active and coalesce((v_side_hp->>v_temp_index)::integer,0) > 0 then
            v_action := jsonb_build_object('type','switch','index',v_temp_index);
            exit;
          end if;
        end loop;
        if v_action is null then v_action := jsonb_build_object('type','struggle','index',-1); end if;
      end if;
      if v_side='host' then v_room.host_action := v_action; else v_room.guest_action := v_action; end if;
      v_logs := coalesce(v_room.battle->'log','[]'::jsonb) || jsonb_build_array(
        (case when v_side='host' then v_room.host_name else v_room.guest_name end)||' ficou sem tempo; uma ação automática foi escolhida.');
      v_room.battle := jsonb_set(v_room.battle,'{log}',v_logs,true);
    end loop;
  end if;
  v_state := v_room.battle;
  v_logs := coalesce(v_state->'log','[]'::jsonb);
  v_host_active := coalesce((v_state->>'hostActive')::integer,0);
  v_guest_active := coalesce((v_state->>'guestActive')::integer,0);

  -- Trocas são aplicadas antes dos ataques do turno.
  foreach v_side in array array['host','guest']::text[] loop
    v_action := case when v_side='host' then v_room.host_action else v_room.guest_action end;
    if v_action->>'type'='switch' then
      v_temp_index := (v_action->>'index')::integer;
      if v_side='host' then
        v_state := jsonb_set(v_state,ARRAY['hostStages',v_host_active::text],jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0),true);
        v_state := jsonb_set(v_state,ARRAY['hostStages',v_temp_index::text],jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0),true);
        v_host_active := v_temp_index;
      else
        v_state := jsonb_set(v_state,ARRAY['guestStages',v_guest_active::text],jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0),true);
        v_state := jsonb_set(v_state,ARRAY['guestStages',v_temp_index::text],jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0),true);
        v_guest_active := v_temp_index;
      end if;
      v_logs := v_logs || jsonb_build_array(((case when v_side='host' then v_room.host_team else v_room.guest_team end)->v_temp_index->>'name') || ' entrou na batalha.');
      v_side_team := case when v_side='host' then v_room.host_team else v_room.guest_team end;
      if v_side_team->v_temp_index->>'ability'='Intimidate' then
        v_stage_index := case when v_side='host' then v_guest_active else v_host_active end;
        v_stage_side := case when v_side='host' then 'guest' else 'host' end;
        v_stage_amount := greatest(-6,coalesce((v_state->(v_stage_side||'Stages')->v_stage_index->>'attack')::integer,0)-1);
        v_state := jsonb_set(v_state,ARRAY[v_stage_side||'Stages',v_stage_index::text,'attack'],to_jsonb(v_stage_amount),true);
        v_logs := v_logs || jsonb_build_array((v_side_team->v_temp_index->>'name')||' intimidou o oponente: Ataque caiu 1 estagio.');
      end if;
    end if;
  end loop;
  v_state := jsonb_set(v_state,'{hostActive}',to_jsonb(v_host_active),true);
  v_state := jsonb_set(v_state,'{guestActive}',to_jsonb(v_guest_active),true);

  v_host_speed := coalesce((v_room.host_team->v_host_active->'stats'->>'speed')::numeric,1) *
    case when coalesce((v_state->'hostStages'->v_host_active->>'speed')::numeric,0)>=0 then (2+coalesce((v_state->'hostStages'->v_host_active->>'speed')::numeric,0))/2 else 2/(2-coalesce((v_state->'hostStages'->v_host_active->>'speed')::numeric,0)) end *
    case when coalesce((v_state->'hostStatus'->v_host_active->>'status'),'')='paralysis' then .25 else 1 end;
  v_guest_speed := coalesce((v_room.guest_team->v_guest_active->'stats'->>'speed')::numeric,1) *
    case when coalesce((v_state->'guestStages'->v_guest_active->>'speed')::numeric,0)>=0 then (2+coalesce((v_state->'guestStages'->v_guest_active->>'speed')::numeric,0))/2 else 2/(2-coalesce((v_state->'guestStages'->v_guest_active->>'speed')::numeric,0)) end *
    case when coalesce((v_state->'guestStatus'->v_guest_active->>'status'),'')='paralysis' then .25 else 1 end;
  v_host_priority := case when v_room.host_action->>'type'='move' then coalesce((v_room.host_team->v_host_active->'moves'->(v_room.host_action->>'index')::integer->>'priority')::integer,0) else 0 end;
  v_guest_priority := case when v_room.guest_action->>'type'='move' then coalesce((v_room.guest_team->v_guest_active->'moves'->(v_room.guest_action->>'index')::integer->>'priority')::integer,0) else 0 end;
  if v_room.host_action->>'type' in ('move','struggle') and v_room.guest_action->>'type' in ('move','struggle') then
    if v_host_priority > v_guest_priority or (v_host_priority=v_guest_priority and (v_host_speed > v_guest_speed or (v_host_speed = v_guest_speed and random() < 0.5))) then v_order := array['host','guest'];
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
    v_major_status := v_state->(v_attacker_side||'Status')->v_attacker_index;
    v_status_name := v_major_status->>'status';
    if v_status_name='sleep' then
      if coalesce((v_major_status->>'turns')::integer,1)>1 then
        v_major_status := jsonb_set(v_major_status,'{turns}',to_jsonb((v_major_status->>'turns')::integer-1),true);
        v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'Status',v_attacker_index::text],v_major_status,true);
        v_logs := v_logs || jsonb_build_array((v_attacker->>'name')||' esta dormindo e nao conseguiu agir.');
        continue;
      else
        v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'Status',v_attacker_index::text],'null'::jsonb,true);
        v_logs := v_logs || jsonb_build_array((v_attacker->>'name')||' acordou!');
      end if;
    elsif v_status_name='freeze' then
      v_logs := v_logs || jsonb_build_array((v_attacker->>'name')||' esta congelado e nao conseguiu agir.');
      continue;
    elsif v_status_name='paralysis' and random()<.25 then
      v_logs := v_logs || jsonb_build_array((v_attacker->>'name')||' esta paralisado e nao conseguiu agir.');
      continue;
    end if;
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
    v_move_priority := coalesce((v_move->>'priority')::integer,0);
    v_accuracy := coalesce((v_move->>'accuracy')::numeric,100);
    v_accuracy_stage := coalesce((v_state->(v_attacker_side||'Stages')->v_attacker_index->>'accuracy')::numeric,0);
    v_evasion_stage := coalesce((v_state->(v_defender_side||'Stages')->v_defender_index->>'evasion')::numeric,0);
    v_accuracy := v_accuracy * case v_accuracy_stage when -6 then .33 when -5 then .36 when -4 then .43 when -3 then .5 when -2 then .6 when -1 then .75 when 1 then 1.33 when 2 then 1.66 when 3 then 2 when 4 then 2.33 when 5 then 2.66 when 6 then 3 else 1 end /
      case v_evasion_stage when -6 then .33 when -5 then .36 when -4 then .43 when -3 then .5 when -2 then .6 when -1 then .75 when 1 then 1.33 when 2 then 1.66 when 3 then 2 when 4 then 2.33 when 5 then 2.66 when 6 then 3 else 1 end;
    if random()*100 >= v_accuracy then
      v_logs := v_logs || jsonb_build_array((v_attacker->>'name')||' errou '||v_move_name||'!');
      continue;
    end if;
    if v_power<=0 and v_move->'statChanges' is not null and jsonb_typeof(v_move->'statChanges')='array' then
      for v_stage_effect in select value from jsonb_array_elements(v_move->'statChanges') loop
        v_stage_target := case when v_stage_effect->>'target' in ('self','attacker') then v_attacker_side else v_defender_side end;
        v_stage_index := case when v_stage_target=v_attacker_side then v_attacker_index else v_defender_index end;
        v_stage_stat := v_stage_effect->>'stat';
        v_stage_amount := coalesce((v_stage_effect->>'stages')::integer,0);
        if v_stage_stat not in ('attack','defense','specialAttack','specialDefense','speed','accuracy','evasion') or v_stage_amount=0 then continue; end if;
        v_stage_amount := greatest(-6,least(6,coalesce((v_state->(v_stage_target||'Stages')->v_stage_index->>v_stage_stat)::integer,0)+v_stage_amount));
        v_state := jsonb_set(v_state,ARRAY[v_stage_target||'Stages',v_stage_index::text,v_stage_stat],to_jsonb(v_stage_amount),true);
        v_logs := v_logs || jsonb_build_array((case when v_stage_target=v_attacker_side then v_attacker->>'name' else v_defender->>'name' end)||' teve o atributo '||v_stage_stat||' alterado ('||v_stage_amount||' estagio(s)).');
      end loop;
    end if;
    if v_power<=0 then
      v_healing := coalesce((v_move->>'healing')::numeric,0);
      if v_healing>0 and v_move->>'target'='user' then
        v_max_hp := coalesce((v_attacker->>'maxHp')::numeric,1);
        v_current_hp := coalesce((v_state->(v_attacker_side||'Hp')->>v_attacker_index)::numeric,0);
        v_damage := least(v_max_hp-v_current_hp,greatest(1,ceil(v_max_hp*v_healing/100)));
        if v_damage>0 then
          v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'Hp',v_attacker_index::text],to_jsonb(v_current_hp+v_damage),false);
          v_logs := v_logs || jsonb_build_array((v_attacker->>'name')||' recuperou '||v_damage::integer||' HP com '||v_move_name||'.');
        end if;
      end if;
      v_status_name := v_move->'statusEffect'->>'status';
      v_status_chance := coalesce((v_move->'statusEffect'->>'chance')::numeric,0);
      v_status_immune := (v_status_name='burn' and v_defender->'types' ? 'Fogo') or
        (v_status_name='freeze' and v_defender->'types' ? 'Gelo') or
        (v_status_name='poison' and (v_defender->'types' ? 'Veneno' or v_defender->'types' ? ('A'||chr(231)||'o')));
      if v_status_name in ('burn','freeze','paralysis','poison','sleep') and v_status_chance>0 and random()<v_status_chance and
         v_state->(v_defender_side||'Status')->v_defender_index='null'::jsonb and not v_status_immune then
        v_state := jsonb_set(v_state,ARRAY[v_defender_side||'Status',v_defender_index::text],jsonb_build_object('status',v_status_name,'turns',case when v_status_name='sleep' then 1+floor(random()*3)::integer else 0 end),true);
        v_logs := v_logs || jsonb_build_array((v_defender->>'name')||' recebeu o status '||v_status_name||'!');
      end if;
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
    if v_move_type='Fogo' and v_state->(v_defender_side||'Status')->v_defender_index->>'status'='freeze' then
      v_state := jsonb_set(v_state,ARRAY[v_defender_side||'Status',v_defender_index::text],'null'::jsonb,true);
      v_logs := v_logs || jsonb_build_array((v_defender->>'name')||' descongelou com o golpe de Fogo!');
    end if;
    v_physical := coalesce(v_move->>'category','physical')='physical';
    v_attack_stage := coalesce((v_state->(v_attacker_side||'Stages')->v_attacker_index->>(case when v_physical then 'attack' else 'specialAttack' end))::numeric,0);
    v_defense_stage := coalesce((v_state->(v_defender_side||'Stages')->v_defender_index->>(case when v_physical then 'defense' else 'specialDefense' end))::numeric,0);
    v_critical := random()<1.0/16.0;
    if v_critical then
      if v_attack_stage<0 then v_attack_stage:=0; end if;
      if v_defense_stage>0 then v_defense_stage:=0; end if;
    end if;
    v_attack_mult := case when v_attack_stage>=0 then (2+v_attack_stage)/2 else 2/(2-v_attack_stage) end;
    v_defense_mult := case when v_defense_stage>=0 then (2+v_defense_stage)/2 else 2/(2-v_defense_stage) end;
    v_attack_value := greatest(1,coalesce((v_attacker->'stats'->>(case when v_physical then 'attack' else 'specialAttack' end))::numeric,1)*v_attack_mult *
      case when v_physical and v_state->(v_attacker_side||'Status')->v_attacker_index->>'status'='burn' and v_attacker->>'ability'<>'Guts' then .5 else 1 end);
    v_defense_value := greatest(1,coalesce((v_defender->'stats'->>(case when v_physical then 'defense' else 'specialDefense' end))::numeric,1)*v_defense_mult);
    v_ability_mult := 1;
    if v_attacker->>'ability' in ('Overgrow','Blaze','Torrent','Swarm') and
       ((v_attacker->>'ability'='Overgrow' and v_move_type='Planta') or (v_attacker->>'ability'='Blaze' and v_move_type='Fogo') or (v_attacker->>'ability'='Torrent' and v_move_type='Agua') or (v_attacker->>'ability'='Swarm' and v_move_type='Inseto')) and
       coalesce((v_state->(v_attacker_side||'Hp')->>v_attacker_index)::numeric,0) <= coalesce((v_attacker->>'maxHp')::numeric,1)/3 then v_ability_mult:=v_ability_mult*1.5; end if;
    if v_move_type in ('Fogo','Gelo') and v_defender->>'ability'='Thick Fat' then v_ability_mult:=v_ability_mult*0.5; end if;
    if v_power<=0 or v_type_mult=0 then v_damage:=0;
    else
      v_damage := greatest(1,floor((floor((floor(((2*v_level/5)+2)*v_power*v_attack_value/v_defense_value)/50))+2)*v_stab*v_type_mult*((85+floor(random()*16))/100)*v_ability_mult*(case when v_critical then 2 else 1 end)*(case when (v_attacker->>'id')::integer=80 then 0.7 else 1 end)));
    end if;
    v_current_hp := coalesce((v_state->(v_defender_side||'Hp')->>v_defender_index)::numeric,0);
    v_damage := least(v_damage,v_current_hp);
    v_state := jsonb_set(v_state,ARRAY[v_defender_side||'Hp',v_defender_index::text],to_jsonb(greatest(0,v_current_hp-v_damage)),false);
    v_healing := coalesce((v_move->>'drain')::numeric,0);
    if v_healing>0 and v_damage>0 then
      v_max_hp := coalesce((v_attacker->>'maxHp')::numeric,1);
      v_current_hp := coalesce((v_state->(v_attacker_side||'Hp')->>v_attacker_index)::numeric,0);
      v_residual := least(v_max_hp-v_current_hp,greatest(1,floor(v_damage*v_healing/100)));
      if v_residual>0 then
        v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'Hp',v_attacker_index::text],to_jsonb(v_current_hp+v_residual),false);
        v_logs := v_logs || jsonb_build_array((v_attacker->>'name')||' recuperou '||v_residual::integer||' HP com '||v_move_name||'.');
      end if;
    end if;
    v_status_name := v_move->'statusEffect'->>'status';
    v_status_chance := coalesce((v_move->'statusEffect'->>'chance')::numeric,0);
    v_status_immune := (v_status_name='burn' and v_defender->'types' ? 'Fogo') or
      (v_status_name='freeze' and v_defender->'types' ? 'Gelo') or
      (v_status_name='poison' and (v_defender->'types' ? 'Veneno' or v_defender->'types' ? ('A'||chr(231)||'o')));
    if v_damage>0 and v_status_name in ('burn','freeze','paralysis','poison','sleep') and v_status_chance>0 and random()<v_status_chance and
       v_state->(v_defender_side||'Status')->v_defender_index='null'::jsonb and not v_status_immune then
      v_state := jsonb_set(v_state,ARRAY[v_defender_side||'Status',v_defender_index::text],jsonb_build_object('status',v_status_name,'turns',case when v_status_name='sleep' then 1+floor(random()*3)::integer else 0 end),true);
      v_logs := v_logs || jsonb_build_array((v_defender->>'name')||' recebeu o status '||v_status_name||'!');
    end if;
    if v_damage>0 and v_move->'statChanges' is not null and jsonb_typeof(v_move->'statChanges')='array' then
      for v_stage_effect in select value from jsonb_array_elements(v_move->'statChanges') loop
        v_stage_target := case when v_stage_effect->>'target' in ('self','attacker') then v_attacker_side else v_defender_side end;
        v_stage_index := case when v_stage_target=v_attacker_side then v_attacker_index else v_defender_index end;
        v_stage_stat := v_stage_effect->>'stat';
        v_stage_amount := coalesce((v_stage_effect->>'stages')::integer,0);
        if v_stage_stat not in ('attack','defense','specialAttack','specialDefense','speed','accuracy','evasion') or v_stage_amount=0 then continue; end if;
        v_stage_amount := greatest(-6,least(6,coalesce((v_state->(v_stage_target||'Stages')->v_stage_index->>v_stage_stat)::integer,0)+v_stage_amount));
        v_state := jsonb_set(v_state,ARRAY[v_stage_target||'Stages',v_stage_index::text,v_stage_stat],to_jsonb(v_stage_amount),true);
        v_logs := v_logs || jsonb_build_array((case when v_stage_target=v_attacker_side then v_attacker->>'name' else v_defender->>'name' end)||' teve um estagio de '||v_stage_stat||' alterado.');
      end loop;
    end if;
    v_logs := v_logs || jsonb_build_array(case when v_damage=0 then (v_attacker->>'name')||' usou '||v_move_name||', mas não causou dano.'
      else (v_attacker->>'name')||' usou '||v_move_name||' e causou '||v_damage::integer||' de dano.'||case when v_critical then ' Crítico!' else '' end||case when v_type_mult>=2 then ' Super efetivo!' when v_type_mult>0 and v_type_mult<1 then ' Pouco efetivo.' else '' end end);
  end loop;

  -- Burn and poison deal one eighth of max HP at turn end in this Gen III ruleset.
  foreach v_side in array array['host','guest']::text[] loop
    v_temp_index := case when v_side='host' then v_host_active else v_guest_active end;
    v_side_team := case when v_side='host' then v_room.host_team else v_room.guest_team end;
    v_status_name := v_state->(v_side||'Status')->v_temp_index->>'status';
    v_current_hp := coalesce((v_state->(v_side||'Hp')->>v_temp_index)::numeric,0);
    if v_status_name in ('burn','poison') and v_current_hp>0 then
      v_residual := greatest(1,floor(coalesce((v_side_team->v_temp_index->>'maxHp')::numeric,1)/8));
      v_current_hp := greatest(0,v_current_hp-v_residual);
      v_state := jsonb_set(v_state,ARRAY[v_side||'Hp',v_temp_index::text],to_jsonb(v_current_hp),false);
      v_logs := v_logs || jsonb_build_array((v_side_team->v_temp_index->>'name')||' sofreu '||v_residual::integer||' de dano pelo status '||v_status_name||'.');
    end if;
    -- Leftovers heals 1/16 of max HP at the end of the turn, after residual damage.
    v_max_hp := coalesce((v_side_team->v_temp_index->>'maxHp')::numeric,1);
    if v_side_team->v_temp_index->>'heldItem'='leftovers' and v_current_hp>0 and v_current_hp<v_max_hp then
      v_residual := least(v_max_hp-v_current_hp,greatest(1,floor(v_max_hp/16)));
      v_current_hp := v_current_hp+v_residual;
      v_state := jsonb_set(v_state,ARRAY[v_side||'Hp',v_temp_index::text],to_jsonb(v_current_hp),false);
      v_logs := v_logs || jsonb_build_array((v_side_team->v_temp_index->>'name')||' recuperou '||v_residual::integer||' HP com Leftovers.');
    end if;
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
    turn_deadline=case when v_status='battle' then clock_timestamp()+interval '45 seconds' else null end,
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
      host_action = null, guest_action = null, turn_deadline = null, updated_at = now()
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

-- Diretório público de treinadores (somente nome e presença) e recursos sociais.
create table if not exists public.trainer_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  trainer_name text not null check (char_length(trim(trainer_name)) between 1 and 24),
  last_seen timestamptz not null default now()
);
create index if not exists trainer_profiles_name_idx on public.trainer_profiles(lower(trainer_name));
create table if not exists public.trainer_friends (
  user_id uuid not null references auth.users(id) on delete cascade,
  friend_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(), primary key(user_id,friend_id), check(user_id<>friend_id)
);
create table if not exists public.social_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  receiver_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check(kind in ('friend','trade','battle')),
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check(status in ('pending','accepted','rejected')),
  created_at timestamptz not null default now(), responded_at timestamptz, check(sender_id<>receiver_id)
);
create index if not exists social_requests_inbox_idx on public.social_requests(receiver_id,status,created_at desc);

alter table public.trainer_profiles enable row level security;
alter table public.trainer_friends enable row level security;
alter table public.social_requests enable row level security;
revoke all on table public.trainer_profiles,public.trainer_friends,public.social_requests from public,anon,authenticated;
grant select on table public.trainer_profiles,public.trainer_friends,public.social_requests to authenticated;
drop policy if exists "Authenticated trainers can see names" on public.trainer_profiles;
create policy "Authenticated trainers can see names" on public.trainer_profiles for select to authenticated using(auth.uid() is not null);
drop policy if exists "Read own friend list" on public.trainer_friends;
create policy "Read own friend list" on public.trainer_friends for select to authenticated using((select auth.uid())=user_id);
drop policy if exists "Read own social requests" on public.social_requests;
create policy "Read own social requests" on public.social_requests for select to authenticated using((select auth.uid())=sender_id or (select auth.uid())=receiver_id);

create or replace function public.social_presence(p_name text) returns void
language plpgsql security definer set search_path='' as $$ begin
  if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
  insert into public.trainer_profiles(user_id,trainer_name,last_seen) values(auth.uid(),left(trim(coalesce(p_name,'Treinador')),24),now())
  on conflict(user_id) do update set trainer_name=excluded.trainer_name,last_seen=excluded.last_seen;
end; $$;

create or replace function public.social_send_friend_request(p_target uuid) returns uuid
language plpgsql security definer set search_path='' as $$ declare v_id uuid; begin
  if auth.uid() is null or p_target is null or p_target=auth.uid() then raise exception 'Treinador inválido.'; end if;
  if not exists(select 1 from public.trainer_profiles where user_id=p_target) then raise exception 'Treinador não encontrado.'; end if;
  if exists(select 1 from public.trainer_friends where (user_id=auth.uid() and friend_id=p_target) or (user_id=p_target and friend_id=auth.uid())) then raise exception 'Já são amigos.'; end if;
  if exists(select 1 from public.social_requests where kind='friend' and status='pending' and ((sender_id=auth.uid() and receiver_id=p_target) or (sender_id=p_target and receiver_id=auth.uid()))) then raise exception 'Já existe um pedido pendente.'; end if;
  insert into public.social_requests(sender_id,receiver_id,kind) values(auth.uid(),p_target,'friend') returning id into v_id; return v_id;
end; $$;

create or replace function public.social_respond_friend(p_request uuid,p_accept boolean) returns void
language plpgsql security definer set search_path='' as $$ declare v_req public.social_requests; begin
  select * into v_req from public.social_requests where id=p_request for update;
  if not found or v_req.receiver_id is distinct from auth.uid() or v_req.kind<>'friend' or v_req.status<>'pending' then raise exception 'Pedido indisponível.'; end if;
  if p_accept then
    insert into public.trainer_friends(user_id,friend_id) values(v_req.sender_id,v_req.receiver_id),(v_req.receiver_id,v_req.sender_id) on conflict do nothing;
  end if;
  update public.social_requests set status=case when p_accept then 'accepted' else 'rejected' end,responded_at=now() where id=p_request;
end; $$;

create or replace function public.social_decline_request(p_request uuid) returns void
language plpgsql security definer set search_path='' as $$ declare v_req public.social_requests; begin
  select * into v_req from public.social_requests where id=p_request for update;
  if not found or v_req.receiver_id is distinct from auth.uid() or v_req.status<>'pending' then raise exception 'Solicitação indisponível.'; end if;
  update public.social_requests set status='rejected',responded_at=now() where id=p_request;
end; $$;
create or replace function public.social_send_trade(p_target uuid,p_pokemon_id text) returns uuid
language plpgsql security definer set search_path='' as $$ declare v_save jsonb; v_id uuid; v_pokemon_name text; begin
  if auth.uid() is null or not exists(select 1 from public.trainer_friends where user_id=auth.uid() and friend_id=p_target) then raise exception 'Trocas só podem ser propostas a amigos.'; end if;
  select player into v_save from public.game_saves where user_id=auth.uid();
  select p.value->>'name' into v_pokemon_name from jsonb_array_elements(coalesce(v_save->'party','[]'::jsonb)) p(value) where p.value->>'tradeId'=p_pokemon_id limit 1;
  if v_pokemon_name is null then raise exception 'Pokémon indisponível na equipe.'; end if;
  if exists(select 1 from public.social_requests where kind='trade' and status='pending' and (payload->>'offered_id'=p_pokemon_id or payload->>'requested_id'=p_pokemon_id)) then raise exception 'Pokémon já reservado em outra troca.'; end if;
  insert into public.social_requests(sender_id,receiver_id,kind,payload) values(auth.uid(),p_target,'trade',jsonb_build_object('offered_id',p_pokemon_id,'offered_name',v_pokemon_name)) returning id into v_id; return v_id;
end; $$;

create or replace function public.social_accept_trade(p_request uuid,p_pokemon_id text) returns jsonb
language plpgsql security definer set search_path='' as $$ declare
  v_req public.social_requests; v_sender jsonb; v_receiver jsonb; v_a jsonb; v_b jsonb; v_ai integer; v_bi integer; v_offered text;
begin
  select * into v_req from public.social_requests where id=p_request for update;
  if not found or v_req.receiver_id is distinct from auth.uid() or v_req.kind<>'trade' or v_req.status<>'pending' then raise exception 'Oferta indisponível.'; end if;
  v_offered:=v_req.payload->>'offered_id';
  if p_pokemon_id is null or p_pokemon_id=v_offered then raise exception 'Escolha outro Pokémon.'; end if;
  perform 1 from public.game_saves where user_id in(v_req.sender_id,v_req.receiver_id) order by user_id for update;
  select player into v_sender from public.game_saves where user_id=v_req.sender_id;
  select player into v_receiver from public.game_saves where user_id=v_req.receiver_id;
  select (x.ordinality-1)::integer,x.value into v_ai,v_a from jsonb_array_elements(coalesce(v_sender->'party','[]'::jsonb)) with ordinality x(value,ordinality) where x.value->>'tradeId'=v_offered limit 1;
  select (x.ordinality-1)::integer,x.value into v_bi,v_b from jsonb_array_elements(coalesce(v_receiver->'party','[]'::jsonb)) with ordinality x(value,ordinality) where x.value->>'tradeId'=p_pokemon_id limit 1;
  if v_a is null or v_b is null then raise exception 'Um Pokémon não está mais disponível na equipe.'; end if;
  v_sender:=jsonb_set(v_sender,array['party',v_ai::text],v_b,false);
  v_receiver:=jsonb_set(v_receiver,array['party',v_bi::text],v_a,false);
  if v_sender->'poke'->>'tradeId'=v_offered then v_sender:=jsonb_set(v_sender,'{poke}',v_b,false); end if;
  if v_receiver->'poke'->>'tradeId'=p_pokemon_id then v_receiver:=jsonb_set(v_receiver,'{poke}',v_a,false); end if;
  update public.game_saves set player=v_sender,updated_at=now() where user_id=v_req.sender_id;
  update public.game_saves set player=v_receiver,updated_at=now() where user_id=v_req.receiver_id;
  update public.social_requests set status='accepted',responded_at=now(),payload=payload||jsonb_build_object('requested_id',p_pokemon_id) where id=p_request;
  return jsonb_build_object('player',v_receiver);
end; $$;

create or replace function public.social_send_battle(p_target uuid,p_code text) returns uuid
language plpgsql security definer set search_path='' as $$ declare v_id uuid; begin
  if auth.uid() is null or not exists(select 1 from public.trainer_friends where user_id=auth.uid() and friend_id=p_target) then raise exception 'Desafios só podem ser enviados a amigos.'; end if;
  if not exists(select 1 from public.pvp_rooms where room_code=upper(p_code) and host_id=auth.uid() and status='waiting' and expires_at>now()) then raise exception 'Sala de batalha indisponível.'; end if;
  insert into public.social_requests(sender_id,receiver_id,kind,payload) values(auth.uid(),p_target,'battle',jsonb_build_object('room_code',upper(p_code))) returning id into v_id; return v_id;
end; $$;

create or replace function public.social_accept_battle(p_request uuid,p_name text,p_team jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$ declare v_req public.social_requests; v_room jsonb; begin
  select * into v_req from public.social_requests where id=p_request for update;
  if not found or v_req.receiver_id is distinct from auth.uid() or v_req.kind<>'battle' or v_req.status<>'pending' then raise exception 'Desafio indisponível.'; end if;
  v_room:=public.pvp_join_room(v_req.payload->>'room_code',p_name,p_team);
  update public.social_requests set status='accepted',responded_at=now() where id=p_request; return v_room;
end; $$;

revoke execute on function public.social_presence(text) from public,anon;
revoke execute on function public.social_send_friend_request(uuid) from public,anon;
revoke execute on function public.social_respond_friend(uuid,boolean) from public,anon;
revoke execute on function public.social_decline_request(uuid) from public,anon;
revoke execute on function public.social_send_trade(uuid,text) from public,anon;
revoke execute on function public.social_accept_trade(uuid,text) from public,anon;
revoke execute on function public.social_send_battle(uuid,text) from public,anon;
revoke execute on function public.social_accept_battle(uuid,text,jsonb) from public,anon;
grant execute on function public.social_presence(text) to authenticated;
grant execute on function public.social_send_friend_request(uuid) to authenticated;
grant execute on function public.social_respond_friend(uuid,boolean) to authenticated;
grant execute on function public.social_decline_request(uuid) to authenticated;
grant execute on function public.social_send_trade(uuid,text) to authenticated;
grant execute on function public.social_accept_trade(uuid,text) to authenticated;
grant execute on function public.social_send_battle(uuid,text) to authenticated;
grant execute on function public.social_accept_battle(uuid,text,jsonb) to authenticated;

-- Award PvP Battle Points once for a normal match victory.
create or replace function public.pvp_claim_battle_points(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.pvp_rooms;
  v_player jsonb;
  v_points integer;
  v_reward integer := 3;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
  select * into v_room from public.pvp_rooms where room_code = upper(p_code) for update;
  if not found or v_room.status <> 'finished' or (v_room.battle->>'result' is distinct from 'normal' and v_room.battle->>'result' is distinct from 'abandoned') or
     v_room.battle->>'winner_user_id' is distinct from auth.uid()::text then
    raise exception 'Esta vitoria PvP nao pode receber Battle Points.';
  end if;
  select player into v_player from public.game_saves where user_id = auth.uid() for update;
  if not found then raise exception 'Save do treinador nao encontrado.'; end if;
  v_points := case when jsonb_typeof(v_player->'battlePoints') = 'number'
    then greatest(0, (v_player->>'battlePoints')::integer) else 0 end;
  if v_room.battle->>'battle_points_claimed' = 'true' then
    return jsonb_build_object('awarded', 0, 'battle_points', v_points);
  end if;
  v_points := v_points + v_reward;
  v_player := jsonb_set(v_player, '{battlePoints}', to_jsonb(v_points), true);
  update public.game_saves set player = v_player, updated_at = now() where user_id = auth.uid();
  update public.pvp_rooms
    set battle = battle || jsonb_build_object('battle_points_claimed', true), updated_at = now()
    where id = v_room.id;
  return jsonb_build_object('awarded', v_reward, 'battle_points', v_points);
end;
$$;

revoke execute on function public.pvp_claim_battle_points(text) from public, anon;
grant execute on function public.pvp_claim_battle_points(text) to authenticated;


-- Administrative trainer grants. Both RPCs enforce the allowlisted auth user server-side.
create or replace function public.admin_search_trainers(p_query text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_result jsonb;
begin
  if auth.uid() is distinct from 'c1224d4d-f533-4991-8c05-27d7ae3202e6'::uuid
     or lower(coalesce(auth.jwt()->>'email','')) is distinct from 'aleffantunes12@gmail.com' then
    raise exception 'Acesso restrito ao administrador.';
  end if;
  if length(trim(coalesce(p_query,''))) < 2 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', q.user_id,
    'trainer_name', q.trainer_name
  ) order by q.trainer_name), '[]'::jsonb)
  into v_result
  from (
    select gs.user_id, left(coalesce(nullif(trim(tp.trainer_name),''), nullif(trim(gs.player->>'name'),''), 'Treinador'), 24) as trainer_name
    from public.game_saves gs
    left join public.trainer_profiles tp on tp.user_id=gs.user_id
    where lower(coalesce(tp.trainer_name,gs.player->>'name','')) like '%'||lower(trim(p_query))||'%'
    order by lower(coalesce(tp.trainer_name,gs.player->>'name',''))
    limit 20
  ) q;
  return v_result;
end;
$$;

create or replace function public.admin_grant_trainer_asset(p_target uuid, p_kind text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_save public.game_saves;
  v_player jsonb;
  v_amount integer;
  v_current bigint;
  v_key text;
  v_pokemon jsonb;
  v_party jsonb;
  v_boxes jsonb;
  v_box jsonb;
  v_box_index integer;
  v_slot_index integer;
  v_trainer_name text;
  v_pokemon_inserted boolean := false;
begin
  if auth.uid() is distinct from 'c1224d4d-f533-4991-8c05-27d7ae3202e6'::uuid
     or lower(coalesce(auth.jwt()->>'email','')) is distinct from 'aleffantunes12@gmail.com' then
    raise exception 'Acesso restrito ao administrador.';
  end if;
  if p_target is null then raise exception 'Selecione um treinador.'; end if;
  select * into v_save from public.game_saves where user_id=p_target for update;
  if not found then raise exception 'Save do treinador nao encontrado.'; end if;
  v_player:=v_save.player;
  v_trainer_name:=coalesce(nullif(trim(v_player->>'name'),''),'Treinador');

  if p_kind in ('money','pokeCoins','battlePoints','item') then
    if coalesce(p_payload->>'amount','') !~ '^[0-9]{1,7}$' then raise exception 'Quantidade invalida.'; end if;
    v_amount:=(p_payload->>'amount')::integer;
    if v_amount<1 or v_amount>1000000 then raise exception 'Quantidade deve ficar entre 1 e 1.000.000.'; end if;
  end if;

  if p_kind in ('money','pokeCoins','battlePoints') then
    v_key:=case p_kind when 'money' then 'money' when 'pokeCoins' then 'pokeCoins' else 'battlePoints' end;
    v_current:=case when jsonb_typeof(v_player->v_key)='number' then greatest(0,(v_player->>v_key)::bigint) else 0 end;
    v_player:=jsonb_set(v_player,array[v_key],to_jsonb(v_current+v_amount),true);
  elsif p_kind='item' then
    v_key:=p_payload->>'key';
    if v_key is null or v_key !~ '^[a-z0-9_]{1,50}$' then raise exception 'Item invalido.'; end if;
    v_current:=case
      when jsonb_typeof(v_player->v_key)='number' then greatest(0,(v_player->>v_key)::bigint)
      when jsonb_typeof(v_player->'items'->v_key)='number' then greatest(0,(v_player->'items'->>v_key)::bigint)
      else 0 end;
    v_player:=jsonb_set(v_player,'{items}',case when jsonb_typeof(v_player->'items')='object' then v_player->'items' else '{}'::jsonb end,true);
    v_player:=jsonb_set(v_player,array['items',v_key],to_jsonb(v_current+v_amount),true);
    if jsonb_typeof(v_player->v_key)='number' then v_player:=jsonb_set(v_player,array[v_key],to_jsonb(v_current+v_amount),true); end if;
  elsif p_kind='pokemon' then
    v_pokemon:=p_payload->'pokemon';
    if jsonb_typeof(v_pokemon) is distinct from 'object'
       or coalesce(v_pokemon->>'id','') !~ '^[0-9]+$'
       or (v_pokemon->>'id')::integer not between 1 and 1025
       or coalesce(v_pokemon->>'level','') !~ '^[0-9]+$'
       or (v_pokemon->>'level')::integer not between 1 and 100
       or jsonb_typeof(v_pokemon->'moves') is distinct from 'array'
       or jsonb_typeof(v_pokemon->'types') is distinct from 'array' then
      raise exception 'Dados do Pokemon invalidos.';
    end if;
    v_pokemon:=jsonb_set(v_pokemon,'{tradeId}',to_jsonb(gen_random_uuid()::text),true);
    v_party:=case when jsonb_typeof(v_player->'party')='array' then v_player->'party' else '[]'::jsonb end;
    if jsonb_array_length(v_party)<6 then
      v_player:=jsonb_set(v_player,'{party}',v_party||jsonb_build_array(v_pokemon),true);
    else
      v_boxes:=v_player->'pc'->'boxes';
      if jsonb_typeof(v_boxes)='array' and jsonb_array_length(v_boxes)>0 then
        for v_box_index in 0..jsonb_array_length(v_boxes)-1 loop
          v_box:=v_boxes->v_box_index;
          if jsonb_typeof(v_box)='array' and jsonb_array_length(v_box)>0 then
            for v_slot_index in 0..jsonb_array_length(v_box)-1 loop
              if v_box->v_slot_index='null'::jsonb then
                v_player:=jsonb_set(v_player,array['pc','boxes',v_box_index::text,v_slot_index::text],v_pokemon,false);
                v_pokemon_inserted:=true;
                exit;
              end if;
            end loop;
          end if;
          exit when v_pokemon_inserted;
        end loop;
      end if;
      if not v_pokemon_inserted then raise exception 'Equipe cheia e PC sem espaco.'; end if;
    end if;
  else
    raise exception 'Tipo de recurso invalido.';
  end if;

  update public.game_saves set player=v_player,updated_at=now() where user_id=p_target;
  return jsonb_build_object('user_id',p_target,'trainer_name',v_trainer_name,'kind',p_kind);
end;
$$;

revoke execute on function public.admin_search_trainers(text) from public,anon;
revoke execute on function public.admin_grant_trainer_asset(uuid,text,jsonb) from public,anon;
grant execute on function public.admin_search_trainers(text) to authenticated;
grant execute on function public.admin_grant_trainer_asset(uuid,text,jsonb) to authenticated;

-- Mensagens privadas entre treinadores que ja sao amigos.
create table if not exists public.trainer_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 500),
  created_at timestamptz not null default now(),
  check (sender_id <> recipient_id)
);
create index if not exists trainer_messages_sender_idx on public.trainer_messages(sender_id,recipient_id,created_at desc);
create index if not exists trainer_messages_recipient_idx on public.trainer_messages(recipient_id,sender_id,created_at desc);
alter table public.trainer_messages enable row level security;
revoke all on table public.trainer_messages from public,anon,authenticated;
grant select on table public.trainer_messages to authenticated;
grant insert (sender_id,recipient_id,body) on table public.trainer_messages to authenticated;
drop policy if exists "Friends can read their messages" on public.trainer_messages;
create policy "Friends can read their messages" on public.trainer_messages
  for select to authenticated
  using (
    ((select auth.uid())=sender_id or (select auth.uid())=recipient_id)
    and exists (
      select 1 from public.trainer_friends f
      where f.user_id=(select auth.uid())
        and f.friend_id=case when sender_id=(select auth.uid()) then recipient_id else sender_id end
    )
  );
drop policy if exists "Friends can send messages" on public.trainer_messages;
create policy "Friends can send messages" on public.trainer_messages
  for insert to authenticated
  with check (
    sender_id=(select auth.uid())
    and exists (
      select 1 from public.trainer_friends f
      where f.user_id=(select auth.uid()) and f.friend_id=recipient_id
    )
  );
