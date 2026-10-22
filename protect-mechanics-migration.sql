-- Protect mechanics update for existing installations.
-- Requires the PvP and cooperative boss schemas/functions to be installed first.
-- Applies priority-ordered protection, consecutive-use odds, and Feint bypass.

begin;
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
  v_is_protect boolean;
  v_target_protected boolean;
  v_protect_streak integer;
  v_feint boolean;
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
    raise exception 'VocÃª nÃ£o participa desta sala.';
  end if;
  if v_room.status <> 'battle' then return to_jsonb(v_room); end if;
  if (v_room.host_action is null or v_room.guest_action is null) and
     (v_room.turn_deadline is null or v_room.turn_deadline > clock_timestamp()) then return to_jsonb(v_room); end if;

  -- Ao expirar o relÃ³gio, escolhe uma aÃ§Ã£o simples para o lado que nÃ£o jogou.
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
        (case when v_side='host' then v_room.host_name else v_room.guest_name end)||' ficou sem tempo; uma aÃ§Ã£o automÃ¡tica foi escolhida.');
      v_room.battle := jsonb_set(v_room.battle,'{log}',v_logs,true);
    end loop;
  end if;
  v_state := v_room.battle;
  v_logs := coalesce(v_state->'log','[]'::jsonb);
  v_host_active := coalesce((v_state->>'hostActive')::integer,0);
  v_guest_active := coalesce((v_state->>'guestActive')::integer,0);

  -- Trocas sÃ£o aplicadas antes dos ataques do turno.
  foreach v_side in array array['host','guest']::text[] loop
    v_action := case when v_side='host' then v_room.host_action else v_room.guest_action end;
    if v_action->>'type'='switch' then
      v_temp_index := (v_action->>'index')::integer;
      if v_side='host' then
        v_state := jsonb_set(v_state,ARRAY['hostStages',v_host_active::text],jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0),true);
        v_state := jsonb_set(v_state,ARRAY['hostStages',v_temp_index::text],jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0),true);
        v_state := jsonb_set(v_state,'{hostProtectChain}','0'::jsonb,true);
        v_host_active := v_temp_index;
      else
        v_state := jsonb_set(v_state,ARRAY['guestStages',v_guest_active::text],jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0),true);
        v_state := jsonb_set(v_state,ARRAY['guestStages',v_temp_index::text],jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0),true);
        v_state := jsonb_set(v_state,'{guestProtectChain}','0'::jsonb,true);
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
      v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'ProtectChain'],'0'::jsonb,true);
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
      v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'ProtectChain'],'0'::jsonb,true);
      v_logs := v_logs || jsonb_build_array((v_attacker->>'name')||' esta congelado e nao conseguiu agir.');
      continue;
    elsif v_status_name='paralysis' and random()<.25 then
      v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'ProtectChain'],'0'::jsonb,true);
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
    v_is_protect := coalesce((v_move->>'protect')::boolean,false) or lower(v_move_name) in
      ('protect','detect','endure','wide guard','quick guard','king''s shield','spiky shield','baneful bunker','obstruct','silk trap','burning bulwark');
    if v_is_protect then
      v_protect_streak := greatest(0,least(6,coalesce((v_state->>(v_attacker_side||'ProtectChain'))::integer,0)));
      v_is_protect := random()<power(1.0/3.0,v_protect_streak);
      v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'ProtectChain'],to_jsonb(case when v_is_protect then least(6,v_protect_streak+1) else 0 end),true);
      v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'Protect'],to_jsonb(v_is_protect),true);
      v_logs := v_logs || jsonb_build_array((v_attacker->>'name')||case when v_is_protect then ' se protegeu com ' else ' falhou ao usar ' end||v_move_name||'.');
      continue;
    else
      v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'ProtectChain'],'0'::jsonb,true);
    end if;
    v_target_protected := coalesce((v_state->>(v_defender_side||'Protect'))::boolean,false);
    v_feint := lower(v_move_name)='feint';
    if v_target_protected and lower(coalesce(v_move->>'target','')) not in ('user','user-or-ally','user-and-allies','users-and-allies','users-field','user-side','ally','allies','ally-side','ally-team','opponents-field','entire-field','field') then
      if v_feint then
        v_state := jsonb_set(v_state,ARRAY[v_defender_side||'Protect'],'false'::jsonb,true);
        v_logs := v_logs || jsonb_build_array(v_move_name||' quebrou a proteÃ§Ã£o de '||(v_defender->>'name')||'!');
      else
        v_logs := v_logs || jsonb_build_array((v_defender->>'name')||' se protegeu e bloqueou '||v_move_name||'!');
        continue;
      end if;
    end if;
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
    v_logs := v_logs || jsonb_build_array(case when v_damage=0 then (v_attacker->>'name')||' usou '||v_move_name||', mas nÃ£o causou dano.'
      else (v_attacker->>'name')||' usou '||v_move_name||' e causou '||v_damage::integer||' de dano.'||case when v_critical then ' CrÃ­tico!' else '' end||case when v_type_mult>=2 then ' Super efetivo!' when v_type_mult>0 and v_type_mult<1 then ' Pouco efetivo.' else '' end end);
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

  v_state := jsonb_set(v_state,'{hostProtect}','false'::jsonb,true);
  v_state := jsonb_set(v_state,'{guestProtect}','false'::jsonb,true);
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
notify pgrst, 'reload schema';

commit;

