-- Apply a forced replacement as soon as a PvP Pokemon faints, without consuming the trainer's next action.
create or replace function public.pvp_forced_switch(p_code text,p_index integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.pvp_rooms;
  v_state jsonb;
  v_team jsonb;
  v_is_host boolean;
  v_active integer;
  v_hp numeric;
  v_active_key text;
  v_hp_key text;
  v_stages_key text;
  v_protect_key text;
  v_other_side text;
  v_other_active integer;
  v_other_stages_key text;
  v_stage_amount integer;
  v_logs jsonb;
begin
  select * into v_room from public.pvp_rooms where room_code=upper(p_code) for update;
  if not found or v_room.status<>'battle' then raise exception 'A sala nao esta em batalha.'; end if;
  v_is_host:=v_room.host_id=auth.uid();
  if not v_is_host and v_room.guest_id is distinct from auth.uid() then raise exception 'Voce nao participa desta sala.'; end if;
  if v_room.turn_deadline is not null and v_room.turn_deadline<=clock_timestamp() then
    raise exception 'O tempo da jogada acabou; o turno esta sendo resolvido.';
  end if;

  v_active_key:=case when v_is_host then 'hostActive' else 'guestActive' end;
  v_hp_key:=case when v_is_host then 'hostHp' else 'guestHp' end;
  v_stages_key:=case when v_is_host then 'hostStages' else 'guestStages' end;
  v_protect_key:=case when v_is_host then 'hostProtectChain' else 'guestProtectChain' end;
  v_other_side:=case when v_is_host then 'guest' else 'host' end;
  v_other_stages_key:=v_other_side||'Stages';
  v_active:=coalesce((v_room.battle->>v_active_key)::integer,0);
  v_hp:=coalesce((v_room.battle->v_hp_key->>v_active)::numeric,0);
  if v_hp>0 then raise exception 'Seu Pokemon ainda esta em campo.'; end if;
  if (case when v_is_host then v_room.host_action else v_room.guest_action end) is not null then
    raise exception 'Sua acao deste turno ja foi enviada.';
  end if;

  v_team:=case when v_is_host then v_room.host_team else v_room.guest_team end;
  if p_index is null or p_index<0 or p_index>=jsonb_array_length(v_team) then raise exception 'Pokemon invalido para troca.'; end if;
  if p_index=v_active or coalesce((v_room.battle->v_hp_key->>p_index)::numeric,0)<=0 then
    raise exception 'Esse Pokemon nao pode entrar na batalha.';
  end if;

  v_state:=v_room.battle;
  v_state:=jsonb_set(v_state,ARRAY[v_stages_key,v_active::text],jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0),true);
  v_state:=jsonb_set(v_state,ARRAY[v_stages_key,p_index::text],jsonb_build_object('attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0,'accuracy',0,'evasion',0),true);
  v_state:=jsonb_set(v_state,ARRAY[v_active_key],to_jsonb(p_index),true);
  v_state:=jsonb_set(v_state,ARRAY[v_protect_key],'0'::jsonb,true);
  v_logs:=coalesce(v_state->'log','[]'::jsonb)||jsonb_build_array((v_team->p_index->>'name')||' entrou na batalha.');

  if v_team->p_index->>'ability'='Intimidate' then
    v_other_active:=coalesce((v_state->>(v_other_side||'Active'))::integer,0);
    if coalesce((v_state->(v_other_side||'Hp')->>v_other_active)::numeric,0)>0 then
      v_stage_amount:=greatest(-6,coalesce((v_state->v_other_stages_key->v_other_active->>'attack')::integer,0)-1);
      v_state:=jsonb_set(v_state,ARRAY[v_other_stages_key,v_other_active::text,'attack'],to_jsonb(v_stage_amount),true);
      v_logs:=v_logs||jsonb_build_array((v_team->p_index->>'name')||' intimidou o oponente: Ataque caiu 1 estagio.');
    end if;
  end if;
  v_state:=jsonb_set(v_state,'{log}',v_logs,true);

  update public.pvp_rooms set battle=v_state,updated_at=now() where id=v_room.id returning * into v_room;
  return to_jsonb(v_room);
end;
$$;

revoke execute on function public.pvp_forced_switch(text,integer) from public,anon;
grant execute on function public.pvp_forced_switch(text,integer) to authenticated;