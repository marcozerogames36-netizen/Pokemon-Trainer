CREATE OR REPLACE FUNCTION public.pvp_resolve_turn(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
        v_logs := v_logs || jsonb_build_array(v_move_name||' quebrou a proteção de '||(v_defender->>'name')||'!');
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
    if v_attacker->>'heldItem'='big_root' then v_healing:=v_healing*1.3; end if;
    if v_healing>0 and v_damage>0 then
      v_max_hp := coalesce((v_attacker->>'maxHp')::numeric,1);
      v_current_hp := coalesce((v_state->(v_attacker_side||'Hp')->>v_attacker_index)::numeric,0);
      v_residual := greatest(1,floor(v_damage*v_healing/100));
      if v_defender->>'ability'='Liquid Ooze' then
        v_residual := least(v_current_hp,v_residual);
        if v_residual>0 then
          v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'Hp',v_attacker_index::text],to_jsonb(greatest(0,v_current_hp-v_residual)),false);
          v_logs := v_logs || jsonb_build_array((v_attacker->>'name')||' perdeu '||v_residual::integer||' HP por causa de Lodo L�quido de '||(v_defender->>'name')||'.');
        end if;
      else
        v_residual := least(v_max_hp-v_current_hp,v_residual);
        if v_residual>0 then
          v_state := jsonb_set(v_state,ARRAY[v_attacker_side||'Hp',v_attacker_index::text],to_jsonb(v_current_hp+v_residual),false);
          v_logs := v_logs || jsonb_build_array((v_attacker->>'name')||' recuperou '||v_residual::integer||' HP com '||v_move_name||'.');
        end if;
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
$function$
