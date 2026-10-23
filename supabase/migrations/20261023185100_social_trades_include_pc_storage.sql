create or replace function public.social_send_trade(p_target uuid,p_pokemon_id text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_save jsonb; v_id uuid; v_pokemon_name text;
begin
  if auth.uid() is null or not exists(
    select 1 from public.trainer_friends
    where user_id=auth.uid() and friend_id=p_target
  ) then
    raise exception 'Trocas só podem ser propostas a amigos.';
  end if;
  if nullif(trim(p_pokemon_id),'') is null then
    raise exception 'Pokémon indisponível.';
  end if;

  select player into v_save
  from public.game_saves where user_id=auth.uid() for update;
  if not found then raise exception 'Salvamento não encontrado.'; end if;

  select owned.value->>'name' into v_pokemon_name
  from jsonb_array_elements(
    case when jsonb_typeof(v_save->'party')='array' then v_save->'party' else '[]'::jsonb end
  ) as owned(value)
  where owned.value->>'tradeId'=p_pokemon_id
  limit 1;

  if v_pokemon_name is null then
    select owned.slot->>'name' into v_pokemon_name
    from jsonb_array_elements(
      case when jsonb_typeof(v_save->'pc'->'boxes')='array' then v_save->'pc'->'boxes' else '[]'::jsonb end
    ) with ordinality as box(value,box_index)
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(box.value)='array' then box.value else '[]'::jsonb end
    ) with ordinality as owned(slot,slot_index)
    where owned.slot->>'tradeId'=p_pokemon_id
    limit 1;
  end if;
  if v_pokemon_name is null then
    raise exception 'Pokémon indisponível na equipe ou no PC.';
  end if;

  if exists(
    select 1 from public.social_requests
    where kind='trade' and status='pending'
      and (payload->>'offered_id'=p_pokemon_id or payload->>'requested_id'=p_pokemon_id)
  ) then
    raise exception 'Pokémon já reservado em outra troca.';
  end if;

  insert into public.social_requests(sender_id,receiver_id,kind,payload)
  values(auth.uid(),p_target,'trade',jsonb_build_object('offered_id',p_pokemon_id,'offered_name',v_pokemon_name))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.social_accept_trade(p_request uuid,p_pokemon_id text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  v_req public.social_requests;
  v_sender jsonb;
  v_receiver jsonb;
  v_a jsonb;
  v_b jsonb;
  v_sender_path text[];
  v_receiver_path text[];
  v_offered text;
begin
  select * into v_req from public.social_requests where id=p_request for update;
  if not found or v_req.receiver_id is distinct from auth.uid()
     or v_req.kind<>'trade' or v_req.status<>'pending' then
    raise exception 'Oferta indisponível.';
  end if;

  v_offered:=v_req.payload->>'offered_id';
  if nullif(trim(p_pokemon_id),'') is null or p_pokemon_id=v_offered then
    raise exception 'Escolha outro Pokémon.';
  end if;

  perform 1 from public.game_saves
  where user_id in(v_req.sender_id,v_req.receiver_id)
  order by user_id for update;
  select player into v_sender from public.game_saves where user_id=v_req.sender_id;
  select player into v_receiver from public.game_saves where user_id=v_req.receiver_id;
  if v_sender is null or v_receiver is null then
    raise exception 'Um dos salvamentos não foi encontrado.';
  end if;

  select array['party',(owned.ordinality-1)::text],owned.value
    into v_sender_path,v_a
  from jsonb_array_elements(
    case when jsonb_typeof(v_sender->'party')='array' then v_sender->'party' else '[]'::jsonb end
  ) with ordinality as owned(value,ordinality)
  where owned.value->>'tradeId'=v_offered limit 1;
  if v_a is null then
    select array['pc','boxes',(box.ordinality-1)::text,(owned.ordinality-1)::text],owned.value
      into v_sender_path,v_a
    from jsonb_array_elements(
      case when jsonb_typeof(v_sender->'pc'->'boxes')='array' then v_sender->'pc'->'boxes' else '[]'::jsonb end
    ) with ordinality as box(value,ordinality)
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(box.value)='array' then box.value else '[]'::jsonb end
    ) with ordinality as owned(value,ordinality)
    where owned.value->>'tradeId'=v_offered limit 1;
  end if;

  select array['party',(owned.ordinality-1)::text],owned.value
    into v_receiver_path,v_b
  from jsonb_array_elements(
    case when jsonb_typeof(v_receiver->'party')='array' then v_receiver->'party' else '[]'::jsonb end
  ) with ordinality as owned(value,ordinality)
  where owned.value->>'tradeId'=p_pokemon_id limit 1;
  if v_b is null then
    select array['pc','boxes',(box.ordinality-1)::text,(owned.ordinality-1)::text],owned.value
      into v_receiver_path,v_b
    from jsonb_array_elements(
      case when jsonb_typeof(v_receiver->'pc'->'boxes')='array' then v_receiver->'pc'->'boxes' else '[]'::jsonb end
    ) with ordinality as box(value,ordinality)
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(box.value)='array' then box.value else '[]'::jsonb end
    ) with ordinality as owned(value,ordinality)
    where owned.value->>'tradeId'=p_pokemon_id limit 1;
  end if;
  if v_a is null or v_b is null then
    raise exception 'Um Pokémon não está mais disponível na equipe ou no PC.';
  end if;

  v_sender:=jsonb_set(v_sender,v_sender_path,v_b,false);
  v_receiver:=jsonb_set(v_receiver,v_receiver_path,v_a,false);
  if v_sender->'poke'->>'tradeId'=v_offered then
    v_sender:=jsonb_set(v_sender,'{poke}',v_b,false);
  end if;
  if v_receiver->'poke'->>'tradeId'=p_pokemon_id then
    v_receiver:=jsonb_set(v_receiver,'{poke}',v_a,false);
  end if;

  update public.game_saves set player=v_sender,updated_at=now() where user_id=v_req.sender_id;
  update public.game_saves set player=v_receiver,updated_at=now() where user_id=v_req.receiver_id;
  update public.social_requests
    set status='accepted',responded_at=now(),payload=payload||jsonb_build_object('requested_id',p_pokemon_id)
    where id=p_request;
  return jsonb_build_object('player',v_receiver);
end;
$$;
