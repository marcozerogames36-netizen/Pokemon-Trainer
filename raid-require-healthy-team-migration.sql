-- Prevent the host from starting a raid if any participant's selected team is all fainted.
-- Run after raid-hp-persistence-migration.sql.
create or replace function public.coop_boss_start(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_room public.coop_boss_rooms; v_member jsonb; v_states jsonb:='{}'::jsonb; v_user text; v_hps jsonb; v_pp jsonb; v_team jsonb;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para iniciar a raid.'; end if;
  select * into v_room from public.coop_boss_rooms where room_code=upper(p_code) for update;
  if not found or v_room.host_id<>auth.uid() then raise exception 'Somente quem criou a sala pode iniciar.'; end if;
  if v_room.status<>'waiting' or v_room.expires_at<=clock_timestamp() then raise exception 'Sala expirada ou raid indisponível.'; end if;
  for v_member in select value from jsonb_array_elements(v_room.members) loop
    v_user:=v_member->>'user_id'; v_team:=v_member->'team';
    if not exists(select 1 from jsonb_array_elements(v_team) p where coalesce((p.value->>'hp')::integer,(p.value->>'maxHp')::integer)>0) then
      raise exception '% está sem Pokémon consciente. Cure a equipe antes de iniciar.',coalesce(v_member->>'name','Treinador');
    end if;
    select coalesce(jsonb_agg(greatest(0,least((p.value->>'maxHp')::integer,coalesce((p.value->>'hp')::integer,(p.value->>'maxHp')::integer))) order by p.ordinality),'[]'::jsonb) into v_hps
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
notify pgrst,'reload schema';
