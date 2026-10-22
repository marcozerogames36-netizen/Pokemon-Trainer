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

create or replace function public.coop_boss_stat_multiplier(p_pokemon jsonb,p_stat text)
returns numeric language sql immutable set search_path = '' as $$
  select greatest(0.85,least(1.35,1+(((coalesce((p_pokemon->'ivs'->>p_stat)::numeric,15)-15.5)/250+coalesce((p_pokemon->'evs'->>p_stat)::numeric,0)/800)*greatest(1,coalesce((p_pokemon->>'level')::numeric,1))/100)))
    * case
        when (p_stat='attack' and p_pokemon->>'nature' in ('Lonely','Brave','Adamant','Naughty')) or
             (p_stat='defense' and p_pokemon->>'nature' in ('Bold','Relaxed','Impish','Lax')) or
             (p_stat='specialAttack' and p_pokemon->>'nature' in ('Modest','Mild','Quiet','Rash')) or
             (p_stat='specialDefense' and p_pokemon->>'nature' in ('Calm','Gentle','Sassy','Careful')) or
             (p_stat='speed' and p_pokemon->>'nature' in ('Timid','Hasty','Jolly','Naive')) then 1.1
        when (p_stat='attack' and p_pokemon->>'nature' in ('Bold','Timid','Modest','Calm')) or
             (p_stat='defense' and p_pokemon->>'nature' in ('Lonely','Hasty','Mild','Gentle')) or
             (p_stat='specialAttack' and p_pokemon->>'nature' in ('Adamant','Impish','Jolly','Careful')) or
             (p_stat='specialDefense' and p_pokemon->>'nature' in ('Naughty','Lax','Rash','Naive')) or
             (p_stat='speed' and p_pokemon->>'nature' in ('Brave','Relaxed','Quiet','Sassy')) then 0.9
        else 1 end
    * case when p_stat='speed' and p_pokemon->>'heldItem'='macho_brace' then 0.5
           when (p_stat='attack' and p_pokemon->>'heldItem'='choice_band') or
                (p_stat='specialAttack' and p_pokemon->>'heldItem'='choice_specs') or
                (p_stat='specialDefense' and p_pokemon->>'heldItem'='assault_vest') or
                (p_stat='speed' and p_pokemon->>'heldItem'='choice_scarf') then 1.5
           else 1 end;
$$;

create or replace function public.coop_boss_create(p_code text,p_trainer text,p_team jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_room public.coop_boss_rooms;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para criar a raid.'; end if;
  if p_code !~ '^[A-Z0-9]{6}$' or not public.pvp_valid_team(p_team) then raise exception 'CÃ³digo ou equipe invÃ¡lidos.'; end if;
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
  if not public.pvp_valid_team(p_team) then raise exception 'Equipe invÃ¡lida.'; end if;
  select * into v_room from public.coop_boss_rooms where room_code=upper(p_code) for update;
  if not found then raise exception 'Sala indisponÃ­vel ou jÃ¡ iniciada.'; end if;
  if exists(select 1 from jsonb_array_elements(v_room.members) as entry(member) where entry.member->>'user_id'=(select auth.uid())::text) then return to_jsonb(v_room); end if;
  if v_room.status<>'waiting' or v_room.expires_at<now() then raise exception 'Sala indisponÃ­vel ou jÃ¡ iniciada.'; end if;
  if jsonb_array_length(v_room.members)>=5 then raise exception 'A raid jÃ¡ estÃ¡ cheia (mÃ¡ximo de 5 treinadores).'; end if;
  v_member:=jsonb_build_object('user_id',auth.uid(),'name',left(coalesce(nullif(trim(p_trainer),''),'Treinador'),24),'team',p_team);
  update public.coop_boss_rooms set members=members||jsonb_build_array(v_member),updated_at=now() where id=v_room.id returning * into v_room;
  return to_jsonb(v_room);
end $$;

create or replace function public.coop_boss_start(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_room public.coop_boss_rooms; v_member jsonb; v_states jsonb:='{}'::jsonb; v_user text; v_hps jsonb; v_pp jsonb; v_team jsonb;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para iniciar a raid.'; end if;
  select * into v_room from public.coop_boss_rooms where room_code=upper(p_code) for update;
  if not found or v_room.host_id<>auth.uid() then raise exception 'Somente quem criou a sala pode iniciar.'; end if;
  if v_room.status<>'waiting' or v_room.expires_at<=clock_timestamp() then raise exception 'Sala expirada ou raid indisponÃ­vel.'; end if;
  for v_member in select value from jsonb_array_elements(v_room.members) loop
    v_user:=v_member->>'user_id'; v_team:=v_member->'team';
    select coalesce(jsonb_agg((p.value->>'maxHp')::integer order by p.ordinality),'[]'::jsonb) into v_hps
      from jsonb_array_elements(v_team) with ordinality p(value,ordinality);
    select coalesce(jsonb_agg(coalesce((m.value->>'pp')::integer,(m.value->>'maxPp')::integer,10) order by p.ordinality,m.ordinality),'[]'::jsonb) into v_pp
      from jsonb_array_elements(v_team) with ordinality p(value,ordinality)
      cross join lateral jsonb_array_elements(coalesce(p.value->'moves','[]'::jsonb)) with ordinality m(value,ordinality);
    v_states:=jsonb_set(v_states,array[v_user],jsonb_build_object('hp',v_hps,'pp',v_pp,'active',0,'stages','{}'::jsonb,'protect',false,'protect_chain',0),true);
  end loop;
  update public.coop_boss_rooms set status='battle',turn=1,turn_deadline=clock_timestamp()+interval '90 seconds',actions='{}'::jsonb,
    battle=jsonb_build_object('mewtwo_hp',30000,'mewtwo_max_hp',30000,'participants',v_states,'mewtwo_stages','{}'::jsonb,'mewtwo_status',null,'mewtwo_sleep_turns',0,'log',jsonb_build_array('Mewtwo surgiu! A equipe precisa agir em conjunto.')),
    updated_at=now() where id=v_room.id returning * into v_room;
  return to_jsonb(v_room);
end $$;

create or replace function public.coop_boss_act(p_code text,p_action jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_room public.coop_boss_rooms; v_member jsonb; v_user text; v_members jsonb; v_actions jsonb; v_battle jsonb;
  v_states jsonb; v_state jsonb; v_team jsonb; v_hp jsonb; v_active integer; v_action jsonb; v_move jsonb;
  v_boss_hp integer; v_attack numeric; v_defense numeric; v_power integer; v_damage integer; v_mult numeric; v_base numeric;
  v_stab numeric; v_accuracy numeric; v_critical boolean; v_physical boolean; v_missed boolean; v_modifier numeric;
  v_current_hp integer; v_pp jsonb; v_pp_index integer; v_hit_count integer; v_min_hits integer; v_max_hits integer;
  v_idx integer; v_move_idx integer; v_target jsonb; v_log jsonb; v_all_fainted boolean:=true; v_status text:='battle';
  v_item_key text; v_item_qty integer; v_save_player jsonb; v_item_hp integer; v_item_max_hp integer; v_item_heal integer; v_item_name text;
  v_stages jsonb; v_boss_stages jsonb; v_change jsonb; v_stat text; v_delta integer; v_old_stage integer; v_stage_mult numeric;
  v_effect jsonb; v_effect_status text; v_effect_chance numeric; v_boss_status text; v_boss_sleep integer; v_boss_confusion integer;
  v_skip_boss_action boolean:=false; v_protect_streak integer; v_protect_success boolean;
  v_labels jsonb:='{"attack":"Ataque","defense":"Defesa","specialAttack":"Ataque Especial","specialDefense":"Defesa Especial","speed":"Velocidade","accuracy":"Precisao","evasion":"Evasao"}'::jsonb;
begin
  select * into v_room from public.coop_boss_rooms where room_code=upper(p_code) for update;
  if not found or v_room.status<>'battle' then raise exception 'A raid nÃ£o estÃ¡ em andamento.'; end if;
  v_user:=auth.uid()::text;
  select value into v_member from jsonb_array_elements(v_room.members) where value->>'user_id'=v_user;
  if v_member is null then raise exception 'VocÃª nÃ£o participa desta raid.'; end if;
  v_actions:=v_room.actions;
  v_state:=v_room.battle->'participants'->v_user; v_team:=v_member->'team'; v_hp:=v_state->'hp'; v_active:=(v_state->>'active')::integer;
  if clock_timestamp()>=v_room.turn_deadline then
    for v_member in select value from jsonb_array_elements(v_room.members) loop
      v_user:=v_member->>'user_id';
      if not (v_actions ? v_user) then v_actions:=jsonb_set(v_actions,array[v_user],'{"type":"wait"}'::jsonb,true); end if;
    end loop;
  else
  if v_actions ? v_user then raise exception 'Sua aÃ§Ã£o deste turno jÃ¡ foi enviada.'; end if;
  if jsonb_typeof(p_action) is distinct from 'object' or coalesce(p_action->>'type','') not in ('move','switch','struggle','wait','item') then raise exception 'AÃ§Ã£o invÃ¡lida.'; end if;
  if p_action->>'type'='wait' then
    if exists(select 1 from jsonb_array_elements_text(v_hp) h where h.value::integer>0) and clock_timestamp()<v_room.turn_deadline then raise exception 'SÃ³ Ã© possÃ­vel aguardar sem PokÃ©mon saudÃ¡vel ou apÃ³s o tempo da rodada.'; end if;
  elsif p_action->>'type'='switch' then
    if coalesce(p_action->>'index','') !~ '^[0-5]$' then raise exception 'PokÃ©mon invÃ¡lido.'; end if;
    v_idx:=(p_action->>'index')::integer;
    if v_idx>=jsonb_array_length(v_team) or (v_hp->>v_idx)::integer<=0 then raise exception 'Escolha um PokÃ©mon saudÃ¡vel.'; end if;
    if v_idx=v_active and (v_hp->>v_active)::integer>0 then raise exception 'Esse PokÃ©mon jÃ¡ estÃ¡ em campo.'; end if;
  elsif p_action->>'type'='item' then
    v_item_key:=p_action->>'key';
    if v_item_key is null or v_item_key not in ('potions','superpotion','hyperpotion','fullrestore','revive','maxrevive') then raise exception 'Esse item nÃ£o pode ser usado na raid.'; end if;
    if coalesce(p_action->>'index','') !~ '^[0-5]$' then raise exception 'PokÃ©mon alvo invÃ¡lido.'; end if;
    v_idx:=(p_action->>'index')::integer;
    if v_idx>=jsonb_array_length(v_team) then raise exception 'PokÃ©mon alvo invÃ¡lido.'; end if;
    v_item_hp:=greatest(0,(v_hp->>v_idx)::integer);
    v_item_max_hp:=greatest(1,(v_team->v_idx->>'maxHp')::integer);
    if v_item_key in ('revive','maxrevive') and v_item_hp>0 then raise exception 'Revive sÃ³ pode ser usado em PokÃ©mon desmaiados.'; end if;
    if v_item_key not in ('revive','maxrevive') and (v_item_hp<=0 or v_item_hp>=v_item_max_hp) then raise exception 'Esse PokÃ©mon nÃ£o precisa de cura.'; end if;
    select gs.player into v_save_player from public.game_saves gs where gs.user_id=auth.uid() for update;
    if not found then raise exception 'Save do treinador nÃ£o encontrado.'; end if;
    v_item_qty:=case
      when jsonb_typeof(v_save_player->v_item_key)='number' then greatest(0,(v_save_player->>v_item_key)::integer)
      when jsonb_typeof(v_save_player->'items'->v_item_key)='number' then greatest(0,(v_save_player->'items'->>v_item_key)::integer)
      else 0 end;
    if v_item_qty<1 then raise exception 'VocÃª nÃ£o possui esse item.'; end if;
    v_save_player:=jsonb_set(v_save_player,'{items}',case when jsonb_typeof(v_save_player->'items')='object' then v_save_player->'items' else '{}'::jsonb end,true);
    v_save_player:=jsonb_set(v_save_player,array['items',v_item_key],to_jsonb(v_item_qty-1),true);
    if jsonb_typeof(v_save_player->v_item_key)='number' then v_save_player:=jsonb_set(v_save_player,array[v_item_key],to_jsonb(v_item_qty-1),true); end if;
    update public.game_saves set player=v_save_player,updated_at=now() where user_id=auth.uid();
  elsif (v_hp->>v_active)::integer<=0 then raise exception 'Escolha um PokÃ©mon saudÃ¡vel para continuar.';
  elsif p_action->>'type'='struggle' then
    if jsonb_typeof(v_state->'pp')='array' and exists(
      select 1 from jsonb_array_elements(coalesce(v_team->v_active->'moves','[]'::jsonb)) with ordinality m(value,ordinality)
      where coalesce((m.value->>'power')::integer,0)>0
        and coalesce(((v_state->'pp'->>(coalesce((select sum(jsonb_array_length(coalesce(p.value->'moves','[]'::jsonb))) from jsonb_array_elements(v_team) with ordinality p(value,ordinality) where p.ordinality<=v_active),0)+m.ordinality-1)))::integer,0)>0
    ) then raise exception 'Ainda hÃ¡ golpes com PP. Use EsforÃ§o depois que todos acabarem.'; end if;
  elsif p_action->>'type'='move' then
    if coalesce(p_action->>'index','') !~ '^[0-3]$' then raise exception 'Golpe invÃ¡lido.'; end if;
    v_move_idx:=(p_action->>'index')::integer; v_move:=v_team->v_active->'moves'->v_move_idx;
    if v_move is null then raise exception 'Golpe invÃ¡lido.'; end if;
    v_pp:=v_state->'pp';
    if jsonb_typeof(v_pp)='array' then
      select coalesce(sum(jsonb_array_length(coalesce(p.value->'moves','[]'::jsonb))),0)::integer into v_pp_index
        from jsonb_array_elements(v_team) with ordinality p(value,ordinality) where p.ordinality<=v_active;
      v_pp_index:=v_pp_index+v_move_idx;
      if coalesce((v_pp->>v_pp_index)::integer,0)<=0 then raise exception 'Esse golpe estÃ¡ sem PP.'; end if;
    end if;
  end if;
  v_actions:=jsonb_set(v_actions,array[v_user],p_action,true);
  end if;
  if (select count(*) from jsonb_object_keys(v_actions)) < jsonb_array_length(v_room.members) then
    update public.coop_boss_rooms set actions=v_actions,updated_at=now() where id=v_room.id returning * into v_room;
    return to_jsonb(v_room);
  end if;

  v_battle:=v_room.battle; v_states:=v_battle->'participants'; v_boss_hp:=(v_battle->>'mewtwo_hp')::integer;
  v_boss_stages:=coalesce(v_battle->'mewtwo_stages','{}'::jsonb); v_boss_status:=v_battle->>'mewtwo_status'; v_boss_sleep:=coalesce((v_battle->>'mewtwo_sleep_turns')::integer,0); v_boss_confusion:=coalesce((v_battle->>'mewtwo_confusion_turns')::integer,0);
  v_log:=coalesce(v_battle->'log','[]'::jsonb);
  -- Resolve all trainer actions against the shared Mewtwo HP pool.
  for v_member in
    select m.value from jsonb_array_elements(v_room.members) m(value)
    order by case when v_actions->(m.value->>'user_id')->>'type' in ('switch','item') then 1 else 0 end desc,
      case when v_actions->(m.value->>'user_id')->>'type'='move' then coalesce((m.value->'team'->((v_states->(m.value->>'user_id')->>'active')::integer)->'moves'->((v_actions->(m.value->>'user_id')->>'index')::integer)->>'priority')::integer,0) else 0 end desc,
      public.coop_boss_stat_multiplier(m.value->'team'->((v_states->(m.value->>'user_id')->>'active')::integer),'speed') desc,
      random()
  loop
    v_user:=v_member->>'user_id'; v_state:=v_states->v_user; v_team:=v_member->'team'; v_hp:=v_state->'hp'; v_active:=(v_state->>'active')::integer; v_action:=v_actions->v_user;
    if v_action->>'type'='wait' then
      v_state:=jsonb_set(v_state,'{protect_chain}','0'::jsonb,true);
      v_log:=v_log||jsonb_build_array((v_member->>'name')||' nÃ£o conseguiu agir nesta rodada.');
    elsif v_action->>'type'='switch' then
      v_active:=(v_action->>'index')::integer;
      v_state:=jsonb_set(v_state,'{stages}','{}'::jsonb,true); v_state:=jsonb_set(v_state,'{protect}','false'::jsonb,true); v_state:=jsonb_set(v_state,'{protect_chain}','0'::jsonb,true);
      v_log:=v_log||jsonb_build_array((v_member->>'name')||' trocou para '||(v_team->v_active->>'name')||'.');
    elsif v_action->>'type'='item' then
      v_state:=jsonb_set(v_state,'{protect_chain}','0'::jsonb,true);
      v_item_key:=v_action->>'key'; v_idx:=(v_action->>'index')::integer;
      v_item_hp:=greatest(0,(v_hp->>v_idx)::integer); v_item_max_hp:=greatest(1,(v_team->v_idx->>'maxHp')::integer);
      v_item_heal:=case v_item_key
        when 'potions' then 25
        when 'superpotion' then 50
        when 'hyperpotion' then 200
        when 'fullrestore' then v_item_max_hp-v_item_hp
        when 'revive' then greatest(1,ceil(v_item_max_hp::numeric/2)::integer)
        when 'maxrevive' then v_item_max_hp
        else 0 end;
      v_item_name:=case v_item_key
        when 'potions' then 'PoÃ§Ã£o'
        when 'superpotion' then 'Super PoÃ§Ã£o'
        when 'hyperpotion' then 'Hiper PoÃ§Ã£o'
        when 'fullrestore' then 'Restaurar Tudo'
        when 'revive' then 'Revive'
        when 'maxrevive' then 'Max Revive'
        else 'Item' end;
      v_item_heal:=least(v_item_max_hp-v_item_hp,v_item_heal);
      v_hp:=jsonb_set(v_hp,array[v_idx::text],to_jsonb(least(v_item_max_hp,v_item_hp+v_item_heal)),false);
      if (v_hp->>v_active)::integer<=0 and (v_hp->>v_idx)::integer>0 then v_active:=v_idx; end if;
      v_state:=jsonb_set(v_state,'{hp}',v_hp,true);
      v_log:=v_log||jsonb_build_array((v_member->>'name')||' usou '||v_item_name||' em '||(v_team->v_idx->>'name')||' e recuperou '||v_item_heal||' HP.');
    elsif v_action->>'type'='struggle' and v_boss_hp>0 then
      v_damage:=least(60,v_boss_hp);
      v_boss_hp:=greatest(0,v_boss_hp-v_damage);
      v_log:=v_log||jsonb_build_array((v_team->v_active->>'name')||' usou EsforÃ§o e causou '||v_damage||' de dano.');
    elsif v_action->>'type'='move' and v_boss_hp<=0 then
      v_log:=v_log||jsonb_build_array((v_team->v_active->>'name')||' nÃ£o precisou atacar: Mewtwo jÃ¡ havia sido derrotado.');
    else
      v_move_idx:=(v_action->>'index')::integer; v_move:=v_team->v_active->'moves'->v_move_idx;
      if not (coalesce((v_move->>'protect')::boolean,false) or lower(coalesce(v_move->>'name','')) in ('protect','detect','endure','wide guard','quick guard','king''s shield','spiky shield','baneful bunker','obstruct','silk trap','burning bulwark')) then
        v_state:=jsonb_set(v_state,'{protect_chain}','0'::jsonb,true);
      end if;
      v_power:=greatest(0,coalesce((v_move->>'power')::integer,0));
      v_base:=((2*greatest(1,(v_team->v_active->>'level')::numeric)/5+2)*v_power/50)+2;
      v_physical:=coalesce(v_move->>'category','physical')='physical';
      v_stages:=coalesce(v_state->'stages','{}'::jsonb);
      v_attack:=public.coop_boss_stat_multiplier(v_team->v_active,case when v_physical then 'attack' else 'specialAttack' end);
      v_defense:=greatest(0.01,public.coop_boss_stat_multiplier(v_team->v_active,case when v_physical then 'defense' else 'specialDefense' end)*public.coop_boss_stat_multiplier(v_team->v_active,'hp'));
      v_stage_mult:=coalesce((v_boss_stages->>(case when v_physical then 'defense' else 'specialDefense' end))::integer,0);
      v_defense:=v_defense*case when v_stage_mult>=0 then (2+v_stage_mult)/2.0 else 2.0/(2-v_stage_mult) end;
      v_stage_mult:=coalesce((v_stages->>(case when v_physical then 'attack' else 'specialAttack' end))::integer,0);
      v_attack:=v_attack*case when v_stage_mult>=0 then (2+v_stage_mult)/2.0 else 2.0/(2-v_stage_mult) end;
      v_mult:=public.pvp_type_multiplier(v_move->>'type','["Psiquico"]'::jsonb);
      v_accuracy:=greatest(1,least(100,coalesce((v_move->>'accuracy')::numeric,100)));
      v_stage_mult:=coalesce((v_stages->>'accuracy')::integer,0)-coalesce((v_boss_stages->>'evasion')::integer,0);
      v_accuracy:=greatest(1,least(100,v_accuracy*case when v_stage_mult>=0 then (3+v_stage_mult)/3.0 else 3.0/(3-v_stage_mult) end));
      v_stab:=case when coalesce(v_team->v_active->'types','[]'::jsonb) ? (v_move->>'type') then 1.5 else 1 end;
      v_modifier:=1;
      if v_team->v_active->>'ability'='Adaptabilidade' and v_stab>1 then v_stab:=2; end if;
      if v_team->v_active->>'ability'='Technician' and v_power<=60 then v_modifier:=v_modifier*1.5; end if;
      if ((v_team->v_active->>'ability'='Overgrow' and v_move->>'type'='Planta') or (v_team->v_active->>'ability'='Blaze' and v_move->>'type'='Fogo') or (v_team->v_active->>'ability'='Torrent' and v_move->>'type'='Agua') or (v_team->v_active->>'ability'='Swarm' and v_move->>'type'='Inseto')) and coalesce((v_hp->>v_active)::numeric,0)<=(v_team->v_active->>'maxHp')::numeric/3 then v_modifier:=v_modifier*1.5; end if;
      if v_team->v_active->>'heldItem'='life_orb' then v_modifier:=v_modifier*1.3; end if;
      if v_team->v_active->>'heldItem'='muscle_band' and v_physical then v_modifier:=v_modifier*1.1; end if;
      if v_team->v_active->>'heldItem'='wise_glasses' and not v_physical then v_modifier:=v_modifier*1.1; end if;
      if (v_team->v_active->>'heldItem'='charcoal' and v_move->>'type'='Fogo') or (v_team->v_active->>'heldItem'='miracle_seed' and v_move->>'type'='Planta') or (v_team->v_active->>'heldItem'='mystic_water' and v_move->>'type'='Agua') or (v_team->v_active->>'heldItem'='magnet' and v_move->>'type'='Eletrico') or (v_team->v_active->>'heldItem'='twisted_spoon' and v_move->>'type'='Psiquico') or (v_team->v_active->>'heldItem'='black_belt' and v_move->>'type'='Lutador') or (v_team->v_active->>'heldItem'='silk_scarf' and v_move->>'type'='Normal') or (v_team->v_active->>'heldItem'='silver_powder' and v_move->>'type'='Inseto') or (v_team->v_active->>'heldItem'='hard_stone' and v_move->>'type'='Pedra') or (v_team->v_active->>'heldItem'='sharp_beak' and v_move->>'type'='Voador') or (v_team->v_active->>'heldItem'='poison_barb' and v_move->>'type'='Veneno') or (v_team->v_active->>'heldItem'='spell_tag' and v_move->>'type'='Fantasma') or (v_team->v_active->>'heldItem'='dragon_fang' and v_move->>'type'='Dragao') or (v_team->v_active->>'heldItem'='never_melt_ice' and v_move->>'type'='Gelo') or (v_team->v_active->>'heldItem'='metal_coat' and v_move->>'type'='A'||chr(231)||'o') or (v_team->v_active->>'heldItem'='black_glasses' and v_move->>'type'='Sombrio') or (v_team->v_active->>'heldItem'='fairy_feather' and v_move->>'type'='Fada') then v_modifier:=v_modifier*1.1; end if;
      v_critical:=random()<least(0.5,1.0/16.0+greatest(0,coalesce((v_move->>'critRate')::numeric,0))/16.0+case when v_team->v_active->>'heldItem'='scope_lens' then 1.0/16.0 else 0 end);
      v_missed:=v_power>0 and v_mult>0 and random()*100>=v_accuracy;
      if v_power=0 or v_mult=0 or v_missed then v_damage:=0;
      else v_damage:=greatest(1,floor(v_base*v_stab*v_mult*(0.85+random()*0.15)*v_attack/v_defense*(case when v_critical then 1.5 else 1 end)*v_modifier)::integer);
        v_min_hits:=greatest(1,least(10,coalesce((v_move->>'minHits')::integer,1))); v_max_hits:=greatest(v_min_hits,least(10,coalesce((v_move->>'maxHits')::integer,v_min_hits)));
        v_hit_count:=case when v_min_hits=v_max_hits then v_min_hits else v_min_hits+floor(random()*(v_max_hits-v_min_hits+1))::integer end;
        v_damage:=v_damage*v_hit_count;
      end if;
      v_damage:=least(v_damage,v_boss_hp);
      if jsonb_typeof(v_state->'pp')='array' then
        v_pp:=v_state->'pp';
        select coalesce(sum(jsonb_array_length(coalesce(p.value->'moves','[]'::jsonb))),0)::integer into v_pp_index
          from jsonb_array_elements(v_team) with ordinality p(value,ordinality) where p.ordinality<=v_active;
        v_pp_index:=v_pp_index+v_move_idx;
        v_pp:=jsonb_set(v_pp,array[v_pp_index::text],to_jsonb(greatest(0,coalesce((v_pp->>v_pp_index)::integer,0)-1)),false);
        v_state:=jsonb_set(v_state,'{pp}',v_pp,true);
      end if;
      if v_power=0 or v_damage>0 then
        if v_power=0 and (coalesce((v_move->>'healing')::numeric,0)>0 or lower(coalesce(v_move->>'name',''))='rest') and coalesce(v_move->>'target','')='user' then
          v_item_heal:=case when lower(coalesce(v_move->>'name',''))='rest' then (v_team->v_active->>'maxHp')::integer-(v_hp->>v_active)::integer else least((v_team->v_active->>'maxHp')::integer-(v_hp->>v_active)::integer,greatest(1,ceil((v_team->v_active->>'maxHp')::numeric*(v_move->>'healing')::numeric/100)::integer)) end;
          if v_item_heal>0 then
            v_hp:=jsonb_set(v_hp,array[v_active::text],to_jsonb((v_hp->>v_active)::integer+v_item_heal),false);
            v_state:=jsonb_set(v_state,'{hp}',v_hp,true);
            v_log:=v_log||jsonb_build_array((v_team->v_active->>'name')||' recuperou '||v_item_heal||' HP com '||(v_move->>'name')||'.');
          end if;
          if lower(coalesce(v_move->>'name',''))='rest' then v_state:=jsonb_set(v_state,'{status}','"sleep"'::jsonb,true); v_state:=jsonb_set(v_state,'{sleep_turns}','2'::jsonb,true); end if;
        end if;
        if coalesce((v_move->>'protect')::boolean,false) or lower(coalesce(v_move->>'name','')) in ('protect','detect','endure','wide guard','quick guard','king''s shield','spiky shield','baneful bunker','obstruct','silk trap','burning bulwark') then
          v_protect_streak:=greatest(0,least(6,coalesce((v_state->>'protect_chain')::integer,0)));
          v_protect_success:=random()<power(1.0/3.0,v_protect_streak);
          v_state:=jsonb_set(v_state,'{protect_chain}',to_jsonb(case when v_protect_success then least(6,v_protect_streak+1) else 0 end),true);
          v_state:=jsonb_set(v_state,'{protect}',to_jsonb(v_protect_success),true);
          v_log:=v_log||jsonb_build_array((v_team->v_active->>'name')||case when v_protect_success then ' se protegeu com ' else ' falhou ao usar ' end||(v_move->>'name')||'.');
        end if;
        if v_damage>0 and random()<greatest(0,least(1,coalesce((v_move->>'flinchChance')::numeric,0))) then v_skip_boss_action:=true; v_log:=v_log||jsonb_build_array('Mewtwo recuou com o golpe!'); end if;
        for v_change in select value from jsonb_array_elements(coalesce(v_move->'statChanges','[]'::jsonb)) loop
          v_stat:=v_change->>'stat'; v_delta:=coalesce((v_change->>'stages')::integer,0);
          if v_stat is null or v_stat not in ('attack','defense','specialAttack','specialDefense','speed','accuracy','evasion') or v_delta=0 then continue; end if;
          if coalesce(v_change->>'target','self') in ('self','attacker') then
            v_stages:=coalesce(v_state->'stages','{}'::jsonb); v_old_stage:=coalesce((v_stages->>v_stat)::integer,0);
            v_stage_mult:=greatest(-6,least(6,v_old_stage+v_delta));
            v_stages:=jsonb_set(v_stages,array[v_stat],to_jsonb(v_stage_mult),true); v_state:=jsonb_set(v_state,'{stages}',v_stages,true);
          else
            v_old_stage:=coalesce((v_boss_stages->>v_stat)::integer,0); v_stage_mult:=greatest(-6,least(6,v_old_stage+v_delta));
            v_boss_stages:=jsonb_set(v_boss_stages,array[v_stat],to_jsonb(v_stage_mult),true);
          end if;
          if v_stage_mult<>v_old_stage then
            v_log:=v_log||jsonb_build_array(coalesce(v_labels->>v_stat,v_stat)||case when coalesce(v_change->>'target','self') in ('self','attacker') then ' de '||(v_team->v_active->>'name') else ' de Mewtwo' end||case when v_stage_mult>v_old_stage then ' aumentou.' else ' diminuiu.' end);
          end if;
        end loop;
        v_effect:=v_move->'statusEffect'; v_effect_status:=v_effect->>'status'; v_effect_chance:=coalesce((v_effect->>'chance')::numeric,0);
        if coalesce(v_move->>'target','')<>'user' and v_effect_status in ('burn','paralysis','poison','sleep','freeze','confusion') and v_boss_status is null and random()<v_effect_chance
          and not (v_effect_status='burn' and coalesce(v_move->>'type','')='Fogo')
          and not (v_effect_status='paralysis' and coalesce(v_move->>'type','')='Eletrico') then
          v_boss_status:=v_effect_status;
          if v_effect_status='sleep' then v_boss_sleep:=1+floor(random()*3)::integer; end if;
          if v_effect_status='confusion' then v_boss_confusion:=2+floor(random()*4)::integer; end if;
          v_log:=v_log||jsonb_build_array('Mewtwo foi afetado por '||case v_effect_status when 'burn' then 'queimadura' when 'paralysis' then 'paralisia' when 'poison' then 'veneno' when 'sleep' then 'sono' when 'confusion' then 'confusao' else 'congelamento' end||'!');
        end if;
      end if;
      if v_damage>0 and coalesce((v_move->>'drain')::numeric,0)>0 then
        v_current_hp:=greatest(0,coalesce((v_hp->>v_active)::integer,0));
        v_hp:=jsonb_set(v_hp,array[v_active::text],to_jsonb(least((v_team->v_active->>'maxHp')::integer,v_current_hp+greatest(1,floor(v_damage*(v_move->>'drain')::numeric/100)::integer))),false);
        v_state:=jsonb_set(v_state,'{hp}',v_hp,true);
      end if;
      if v_damage>0 and coalesce((v_move->>'recoil')::numeric,0)>0 then
        v_current_hp:=greatest(0,coalesce((v_hp->>v_active)::integer,0)); v_item_heal:=greatest(1,floor(v_damage*(v_move->>'recoil')::numeric/100)::integer);
        v_hp:=jsonb_set(v_hp,array[v_active::text],to_jsonb(greatest(0,v_current_hp-v_item_heal)),false); v_state:=jsonb_set(v_state,'{hp}',v_hp,true);
        v_log:=v_log||jsonb_build_array((v_team->v_active->>'name')||' sofreu '||least(v_current_hp,v_item_heal)||' de dano de recuo.');
      end if;
      if v_damage>0 and v_team->v_active->>'heldItem'='shell_bell' then
        v_current_hp:=greatest(0,coalesce((v_hp->>v_active)::integer,0));
        v_hp:=jsonb_set(v_hp,array[v_active::text],to_jsonb(least((v_team->v_active->>'maxHp')::integer,v_current_hp+greatest(1,floor(v_damage/8.0)::integer))),false);
        v_state:=jsonb_set(v_state,'{hp}',v_hp,true);
      end if;
      if v_damage>0 and v_team->v_active->>'heldItem'='life_orb' then
        v_current_hp:=greatest(0,coalesce((v_hp->>v_active)::integer,0));
        v_hp:=jsonb_set(v_hp,array[v_active::text],to_jsonb(greatest(0,v_current_hp-greatest(1,ceil((v_team->v_active->>'maxHp')::numeric/10)::integer))),false);
        v_state:=jsonb_set(v_state,'{hp}',v_hp,true);
      end if;
      v_boss_hp:=greatest(0,v_boss_hp-v_damage);
      if not (coalesce((v_move->>'protect')::boolean,false) or lower(coalesce(v_move->>'name','')) in ('protect','detect','endure','wide guard','quick guard','king''s shield','spiky shield','baneful bunker','obstruct','silk trap','burning bulwark')) then
      v_log:=v_log||jsonb_build_array(case when v_missed then (v_team->v_active->>'name')||' errou '||(v_move->>'name')||'.' when v_power=0 then (v_team->v_active->>'name')||' usou '||(v_move->>'name')||'.' else (v_team->v_active->>'name')||' usou '||(v_move->>'name')||' e causou '||v_damage||' de dano.'||case when v_critical and v_damage>0 then ' CrÃ­tico!' else '' end||case when v_mult>=2 then ' Super efetivo!' when v_mult>0 and v_mult<1 then ' Pouco efetivo.' else '' end end);
      end if;
    end if;
    v_state:=jsonb_set(v_state,'{active}',to_jsonb(v_active),true); v_states:=jsonb_set(v_states,array[v_user],v_state,true);
  end loop;

  -- Apply residual boss conditions before the counterattack.
  if v_boss_hp>0 and v_boss_status in ('burn','poison') then
    v_damage:=greatest(1,floor((v_battle->>'mewtwo_max_hp')::numeric/16)::integer); v_boss_hp:=greatest(0,v_boss_hp-v_damage);
    v_log:=v_log||jsonb_build_array('Mewtwo sofreu '||v_damage||' de dano por '||case v_boss_status when 'burn' then 'queimadura' else 'veneno' end||'.');
  elsif v_boss_hp>0 and v_boss_status='sleep' then
    v_boss_sleep:=greatest(0,v_boss_sleep-1); v_skip_boss_action:=true;
    if v_boss_sleep=0 then v_boss_status:=null; v_log:=v_log||jsonb_build_array('Mewtwo acordou!');
    else v_log:=v_log||jsonb_build_array('Mewtwo continua dormindo.'); end if;
  elsif v_boss_hp>0 and v_boss_status='freeze' then
    if random()<0.2 then v_boss_status:=null; v_log:=v_log||jsonb_build_array('Mewtwo descongelou!');
    else v_skip_boss_action:=true; v_log:=v_log||jsonb_build_array('Mewtwo esta congelado e nao conseguiu atacar.'); end if;
  end if;
  if v_boss_hp>0 and not v_skip_boss_action and v_boss_status='confusion' then
    v_boss_confusion:=greatest(0,v_boss_confusion-1);
    if random()<0.333 then
      v_damage:=greatest(1,floor((v_battle->>'mewtwo_max_hp')::numeric/8)::integer);
      v_boss_hp:=greatest(0,v_boss_hp-v_damage); v_skip_boss_action:=true;
      v_log:=v_log||jsonb_build_array('Mewtwo se feriu na confusao e sofreu '||v_damage||' de dano.');
    end if;
    if v_boss_confusion=0 then v_boss_status:=null; v_log:=v_log||jsonb_build_array('Mewtwo saiu da confusao.'); end if;
  end if;
  -- Mewtwo retaliates against each trainer that still has a conscious PokÃ©mon.
  if v_boss_hp>0 then
    for v_member in select value from jsonb_array_elements(v_room.members) loop
      v_user:=v_member->>'user_id'; v_state:=v_states->v_user; v_team:=v_member->'team'; v_hp:=v_state->'hp'; v_active:=(v_state->>'active')::integer;
      if v_skip_boss_action then
        if coalesce((v_state->>'protect')::boolean,false) then v_state:=jsonb_set(v_state,'{protect}','false'::jsonb,true); v_states:=jsonb_set(v_states,array[v_user],v_state,true); end if;
        continue;
      end if;
      if v_boss_status='paralysis' and random()<0.25 then
        v_log:=v_log||jsonb_build_array('Paralisia impediu Mewtwo de atacar a equipe de '||(v_member->>'name')||'.');
        if coalesce((v_state->>'protect')::boolean,false) then v_state:=jsonb_set(v_state,'{protect}','false'::jsonb,true); v_states:=jsonb_set(v_states,array[v_user],v_state,true); end if;
        continue;
      end if;
      if coalesce((v_state->>'protect')::boolean,false) then
        v_state:=jsonb_set(v_state,'{protect}','false'::jsonb,true); v_states:=jsonb_set(v_states,array[v_user],v_state,true);
        v_log:=v_log||jsonb_build_array('O escudo de '||(v_member->>'name')||' bloqueou o ataque de Mewtwo.'); continue;
      end if;
      if (v_hp->>v_active)::integer<=0 then
        for v_idx in 0..jsonb_array_length(v_team)-1 loop
          if (v_hp->>v_idx)::integer>0 then
            v_active:=v_idx; v_state:=jsonb_set(v_state,'{stages}','{}'::jsonb,true); v_state:=jsonb_set(v_state,'{protect}','false'::jsonb,true); exit;
          end if;
        end loop;
      end if;
      if (v_hp->>v_active)::integer>0 then
      v_defense:=greatest(0.01,public.coop_boss_stat_multiplier(v_team->v_active,'specialDefense')*public.coop_boss_stat_multiplier(v_team->v_active,'hp'));
        v_stages:=coalesce(v_state->'stages','{}'::jsonb); v_stage_mult:=coalesce((v_stages->>'specialDefense')::integer,0);
        v_defense:=v_defense*case when v_stage_mult>=0 then (2+v_stage_mult)/2.0 else 2.0/(2-v_stage_mult) end;
        v_mult:=public.pvp_type_multiplier('Psiquico',v_team->v_active->'types');
      v_critical:=random()<1.0/16.0;
        if v_mult=0 or (v_team->v_active->>'ability'='Wonder Guard' and v_mult<=1) then v_damage:=0;
        else v_base:=((2*100/5+2)*90/50)+2; v_stage_mult:=coalesce((v_boss_stages->>'specialAttack')::integer,0); v_base:=v_base*case when v_stage_mult>=0 then (2+v_stage_mult)/2.0 else 2.0/(2-v_stage_mult) end; v_damage:=greatest(1,floor(v_base*1.5*v_mult*(0.85+random()*0.15)*0.925/v_defense*(case when v_critical then 1.5 else 1 end)*0.45)::integer); end if;
        v_hp:=jsonb_set(v_hp,array[v_active::text],to_jsonb(greatest(0,(v_hp->>v_active)::integer-v_damage)),false);
        v_state:=jsonb_set(v_state,'{hp}',v_hp,true); v_state:=jsonb_set(v_state,'{active}',to_jsonb(v_active),true); v_states:=jsonb_set(v_states,array[v_user],v_state,true);
        v_log:=v_log||jsonb_build_array(case when v_damage=0 then 'Mewtwo nÃ£o conseguiu causar dano Ã  equipe de '||(v_member->>'name')||'.' else 'Mewtwo atingiu a equipe de '||(v_member->>'name')||' por '||v_damage||' de dano.'||case when v_critical then ' CrÃ­tico!' else '' end end);
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
  v_battle:=jsonb_set(v_battle,'{mewtwo_hp}',to_jsonb(v_boss_hp),true); v_battle:=jsonb_set(v_battle,'{participants}',v_states,true); v_battle:=jsonb_set(v_battle,'{mewtwo_stages}',v_boss_stages,true); v_battle:=jsonb_set(v_battle,'{mewtwo_status}',coalesce(to_jsonb(v_boss_status),'null'::jsonb),true); v_battle:=jsonb_set(v_battle,'{mewtwo_sleep_turns}',to_jsonb(v_boss_sleep),true); v_battle:=jsonb_set(v_battle,'{mewtwo_confusion_turns}',to_jsonb(v_boss_confusion),true); v_battle:=jsonb_set(v_battle,'{log}',(select coalesce(jsonb_agg(x order by ordinality),'[]'::jsonb) from jsonb_array_elements(v_log) with ordinality q(x,ordinality) where ordinality>greatest(0,jsonb_array_length(v_log)-20)),true);
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
