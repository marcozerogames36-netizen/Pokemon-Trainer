-- Keep cooperative raid HP in sync with each authenticated trainer's own save.
-- Run after cooperative-boss-migration.sql.

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

create or replace function public.coop_boss_sync_hp(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_room public.coop_boss_rooms;
  v_member jsonb;
  v_state jsonb;
  v_team jsonb;
  v_hp jsonb;
  v_player jsonb;
  v_party jsonb;
  v_poke jsonb;
  v_poke_index integer;
  v_idx integer;
  v_raid_hp integer;
  v_raid_max_hp integer;
  v_party_max_hp integer;
  v_new_hp integer;
  v_entry jsonb;
  v_team_ordinal integer;
  v_updated jsonb;
  v_used integer[] := '{}'::integer[];
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para salvar o HP da raid.'; end if;
  select * into v_room from public.coop_boss_rooms where room_code=upper(trim(p_code)) for update;
  if not found then raise exception 'Sala da raid não encontrada.'; end if;
  select value into v_member from jsonb_array_elements(v_room.members) where value->>'user_id'=(select auth.uid())::text;
  if v_member is null then raise exception 'Você não participa desta raid.'; end if;
  v_state:=v_room.battle->'participants'->(auth.uid()::text);
  if v_state is null then raise exception 'A batalha ainda não começou.'; end if;
  v_team:=v_member->'team'; v_hp:=v_state->'hp';
  select gs.player into v_player from public.game_saves gs where gs.user_id=(select auth.uid()) for update;
  if v_player is null then raise exception 'Save do treinador não encontrado.'; end if;
  v_party:=v_player->'party';
  if jsonb_typeof(v_party) is distinct from 'array' then raise exception 'Equipe salva inválida.'; end if;

  if jsonb_typeof(v_player->'poke')='object' then
    select ordinality::integer-1 into v_poke_index
    from jsonb_array_elements(v_party) with ordinality p(value,ordinality)
    where case
      when coalesce(v_player->'poke'->>'tradeId','')<>'' then p.value->>'tradeId'=v_player->'poke'->>'tradeId'
      else p.value->>'id'=v_player->'poke'->>'id' and p.value->>'name'=v_player->'poke'->>'name' and p.value->>'level'=v_player->'poke'->>'level'
    end
    order by ordinality limit 1;
  end if;

  for v_entry,v_team_ordinal in select value,ordinality::integer from jsonb_array_elements(v_team) with ordinality loop
    if coalesce(v_entry->>'partyIndex','') ~ '^[0-5]$' then
      v_idx:=(v_entry->>'partyIndex')::integer;
    else
      select ordinality::integer-1 into v_idx
      from jsonb_array_elements(v_party) with ordinality p(value,ordinality)
      where p.value->>'id'=v_entry->>'id' and p.value->>'name'=v_entry->>'name' and p.value->>'level'=v_entry->>'level'
        and not ((ordinality::integer-1)=any(v_used))
      order by ordinality limit 1;
    end if;
    if v_idx is null or v_idx<0 or v_idx>=jsonb_array_length(v_party) then continue; end if;
    v_updated:=v_party->v_idx;
    if v_updated->>'id' is distinct from v_entry->>'id' or v_updated->>'level' is distinct from v_entry->>'level' then continue; end if;
    if coalesce(v_entry->>'tradeId','')<>'' and v_updated->>'tradeId' is distinct from v_entry->>'tradeId' then continue; end if;
    v_used:=array_append(v_used,v_idx);
    v_raid_max_hp:=greatest(1,coalesce((v_entry->>'maxHp')::integer,1));
    v_party_max_hp:=greatest(1,coalesce((v_updated->>'maxHp')::integer,(v_entry->>'sourceMaxHp')::integer,v_raid_max_hp));
    v_raid_hp:=greatest(0,least(v_raid_max_hp,coalesce((v_hp->>(v_team_ordinal-1))::integer,0)));
    v_new_hp:=greatest(0,least(v_party_max_hp,round(v_raid_hp::numeric*v_party_max_hp/v_raid_max_hp)::integer));
    v_updated:=jsonb_set(v_updated,'{hp}',to_jsonb(v_new_hp),true);
    v_party:=jsonb_set(v_party,array[v_idx::text],v_updated,false);
    if v_poke_index=v_idx then v_poke:=v_updated; end if;
  end loop;
  v_player:=jsonb_set(v_player,'{party}',v_party,true);
  if v_poke is not null then v_player:=jsonb_set(v_player,'{poke}',v_poke,true); end if;
  update public.game_saves set player=v_player,updated_at=now() where user_id=(select auth.uid());
  return jsonb_build_object('team',v_team,'hp',v_hp);
end $$;

revoke execute on function public.coop_boss_sync_hp(text) from public,anon;
grant execute on function public.coop_boss_sync_hp(text) to authenticated;
notify pgrst,'reload schema';
