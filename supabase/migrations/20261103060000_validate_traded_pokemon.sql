-- Validate Pokémon at the server-side trade boundary. Saves remain client-authored,
-- so this prevents malformed/duplicated transfer records but does not make game
-- rewards or the player's own save server-authoritative.
create or replace function public.social_get_valid_trade_pokemon(p_player jsonb, p_trade_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matches jsonb;
  v_count integer;
  v_pokemon jsonb;
  v_stat text;
  v_value integer;
begin
  if p_player is null or jsonb_typeof(p_player) <> 'object'
     or nullif(trim(p_trade_id), '') is null then
    raise exception 'Pokémon indisponível para troca.';
  end if;

  with owned as (
    select value as pokemon
    from jsonb_array_elements(
      case when jsonb_typeof(p_player->'party') = 'array' then p_player->'party' else '[]'::jsonb end
    )
    union all
    select member.value as pokemon
    from jsonb_array_elements(
      case when jsonb_typeof(p_player->'pc'->'boxes') = 'array' then p_player->'pc'->'boxes' else '[]'::jsonb end
    ) as box(value)
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(box.value) = 'array' then box.value else '[]'::jsonb end
    ) as member(value)
  ), matches as (
    select pokemon from owned where pokemon->>'tradeId' = p_trade_id
  )
  select count(*)::integer, coalesce(jsonb_agg(pokemon), '[]'::jsonb)
  into v_count, v_matches
  from matches;

  if v_count <> 1 then
    raise exception 'O Pokémon precisa existir uma única vez na equipe ou no PC.';
  end if;
  v_pokemon := v_matches->0;

  if jsonb_typeof(v_pokemon) is distinct from 'object'
     or nullif(trim(v_pokemon->>'name'), '') is null
     or coalesce(v_pokemon->>'id', '') !~ '^[0-9]{1,4}$'
     or coalesce(v_pokemon->>'level', '') !~ '^[0-9]{1,3}$'
     or jsonb_typeof(v_pokemon->'ivs') is distinct from 'object'
     or jsonb_typeof(v_pokemon->'evs') is distinct from 'object'
     or jsonb_typeof(v_pokemon->'moves') is distinct from 'array' then
    raise exception 'Os dados do Pokémon estão incompletos ou fora dos limites.';
  end if;
  if (v_pokemon->>'id')::integer not between 1 and 1025
     or (v_pokemon->>'level')::integer not between 1 and 100
     or jsonb_array_length(v_pokemon->'moves') > 4 then
    raise exception 'Os dados do Pokémon estão fora dos limites.';
  end if;

  foreach v_stat in array array['hp','attack','defense','specialAttack','specialDefense','speed'] loop
    if coalesce(v_pokemon->'ivs'->>v_stat, '') !~ '^[0-9]{1,2}$' then
      raise exception 'Os IVs do Pokémon estão inválidos.';
    end if;
    v_value := (v_pokemon->'ivs'->>v_stat)::integer;
    if v_value not between 0 and 31 then raise exception 'Os IVs do Pokémon estão fora dos limites.'; end if;

    if coalesce(v_pokemon->'evs'->>v_stat, '') !~ '^[0-9]{1,3}$' then
      raise exception 'Os EVs do Pokémon estão inválidos.';
    end if;
    v_value := (v_pokemon->'evs'->>v_stat)::integer;
    if v_value not between 0 and 252 then raise exception 'Os EVs do Pokémon estão fora dos limites.'; end if;
  end loop;

  select sum((v_pokemon->'evs'->>stat)::integer)::integer
  into v_value
  from unnest(array['hp','attack','defense','specialAttack','specialDefense','speed']) as stat;
  if v_value > 510 then raise exception 'A soma dos EVs do Pokémon excede 510.'; end if;

  return v_pokemon;
end;
$$;

revoke execute on function public.social_get_valid_trade_pokemon(jsonb,text) from public, anon, authenticated;

create or replace function public.social_send_trade(p_target uuid,p_pokemon_id text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_save jsonb; v_id uuid; v_pokemon jsonb; v_pokemon_name text;
begin
  if auth.uid() is null or not exists(
    select 1 from public.trainer_friends
    where user_id=auth.uid() and friend_id=p_target
  ) then
    raise exception 'Trocas só podem ser propostas a amigos.';
  end if;

  select player into v_save
  from public.game_saves where user_id=auth.uid() for update;
  if not found then raise exception 'Salvamento não encontrado.'; end if;

  v_pokemon := public.social_get_valid_trade_pokemon(v_save,p_pokemon_id);
  v_pokemon_name := v_pokemon->>'name';

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

  v_a := public.social_get_valid_trade_pokemon(v_sender,v_offered);
  v_b := public.social_get_valid_trade_pokemon(v_receiver,p_pokemon_id);

  select array['party',(owned.ordinality-1)::text]
    into v_sender_path
  from jsonb_array_elements(
    case when jsonb_typeof(v_sender->'party')='array' then v_sender->'party' else '[]'::jsonb end
  ) with ordinality as owned(value,ordinality)
  where owned.value->>'tradeId'=v_offered limit 1;
  if v_sender_path is null then
    select array['pc','boxes',(box.ordinality-1)::text,(owned.ordinality-1)::text]
      into v_sender_path
    from jsonb_array_elements(
      case when jsonb_typeof(v_sender->'pc'->'boxes')='array' then v_sender->'pc'->'boxes' else '[]'::jsonb end
    ) with ordinality as box(value,ordinality)
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(box.value)='array' then box.value else '[]'::jsonb end
    ) with ordinality as owned(value,ordinality)
    where owned.value->>'tradeId'=v_offered limit 1;
  end if;

  select array['party',(owned.ordinality-1)::text]
    into v_receiver_path
  from jsonb_array_elements(
    case when jsonb_typeof(v_receiver->'party')='array' then v_receiver->'party' else '[]'::jsonb end
  ) with ordinality as owned(value,ordinality)
  where owned.value->>'tradeId'=p_pokemon_id limit 1;
  if v_receiver_path is null then
    select array['pc','boxes',(box.ordinality-1)::text,(owned.ordinality-1)::text]
      into v_receiver_path
    from jsonb_array_elements(
      case when jsonb_typeof(v_receiver->'pc'->'boxes')='array' then v_receiver->'pc'->'boxes' else '[]'::jsonb end
    ) with ordinality as box(value,ordinality)
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(box.value)='array' then box.value else '[]'::jsonb end
    ) with ordinality as owned(value,ordinality)
    where owned.value->>'tradeId'=p_pokemon_id limit 1;
  end if;
  if v_sender_path is null or v_receiver_path is null then
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

revoke execute on function public.social_send_trade(uuid,text) from public,anon;
revoke execute on function public.social_accept_trade(uuid,text) from public,anon;
grant execute on function public.social_send_trade(uuid,text) to authenticated;
grant execute on function public.social_accept_trade(uuid,text) to authenticated;
