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
