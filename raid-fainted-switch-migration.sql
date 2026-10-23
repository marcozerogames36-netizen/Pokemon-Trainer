-- Let a fainted raid Pokemon be replaced without spending the trainer's move.
create or replace function public.coop_boss_switch(p_code text,p_index integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.coop_boss_rooms;
  v_user uuid;
  v_member jsonb;
  v_battle jsonb;
  v_states jsonb;
  v_state jsonb;
  v_team jsonb;
  v_hp jsonb;
  v_active integer;
  v_log jsonb;
begin
  v_user:=auth.uid();
  if v_user is null then raise exception 'Sign in to switch a raid Pokemon.'; end if;

  select * into v_room
  from public.coop_boss_rooms
  where room_code=upper(trim(p_code))
  for update;
  if not found or v_room.status<>'battle' then raise exception 'The raid is not in progress.'; end if;
  if v_room.turn_deadline is not null and clock_timestamp()>=v_room.turn_deadline then
    raise exception 'The turn deadline has passed.';
  end if;
  if coalesce(v_room.actions,'{}'::jsonb) ? v_user::text then
    raise exception 'Your action for this turn was already submitted.';
  end if;

  select value into v_member
  from jsonb_array_elements(v_room.members)
  where value->>'user_id'=v_user::text;
  if v_member is null then raise exception 'You are not a participant in this raid.'; end if;

  v_battle:=v_room.battle;
  v_states:=v_battle->'participants';
  v_state:=v_states->v_user::text;
  if v_state is null then raise exception 'Raid trainer state was not found.'; end if;
  v_team:=v_member->'team';
  v_hp:=v_state->'hp';
  v_active:=coalesce((v_state->>'active')::integer,0);

  if v_active<0 or v_active>=jsonb_array_length(v_team) then
    raise exception 'The active Pokemon is invalid.';
  end if;
  if coalesce((v_hp->>v_active)::integer,0)>0 then
    raise exception 'Only a fainted Pokemon can be replaced without using a turn.';
  end if;
  if p_index is null or p_index<0 or p_index>=jsonb_array_length(v_team) then
    raise exception 'Choose a valid Pokemon.';
  end if;
  if p_index=v_active or coalesce((v_hp->>p_index)::integer,0)<=0 then
    raise exception 'Choose a different Pokemon with HP remaining.';
  end if;

  v_state:=jsonb_set(v_state,'{active}',to_jsonb(p_index),true);
  v_state:=jsonb_set(v_state,'{stages}','{}'::jsonb,true);
  v_state:=jsonb_set(v_state,'{protect}','false'::jsonb,true);
  v_state:=jsonb_set(v_state,'{protect_chain}','0'::jsonb,true);
  v_states:=jsonb_set(v_states,array[v_user::text],v_state,true);
  v_log:=coalesce(v_battle->'log','[]'::jsonb)||jsonb_build_array(
    (v_member->>'name')||' trocou para '||(v_team->p_index->>'name')||'.'
  );
  v_battle:=jsonb_set(v_battle,'{participants}',v_states,true);
  v_battle:=jsonb_set(v_battle,'{log}',(
    select coalesce(jsonb_agg(entry order by ordinality),'[]'::jsonb)
    from jsonb_array_elements(v_log) with ordinality as entries(entry,ordinality)
    where ordinality>greatest(0,jsonb_array_length(v_log)-20)
  ),true);

  update public.coop_boss_rooms
  set battle=v_battle,updated_at=now()
  where id=v_room.id
  returning * into v_room;
  return to_jsonb(v_room);
end;
$$;

revoke execute on function public.coop_boss_switch(text,integer) from public,anon;
grant execute on function public.coop_boss_switch(text,integer) to authenticated;
notify pgrst,'reload schema';
