-- Administrative roles and trainer tools. Role checks are enforced in Postgres.
create table if not exists public.game_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  granted_by uuid references auth.users(id) on delete set null,
  granted_at timestamptz not null default now(),
  is_super_admin boolean not null default false
);

alter table public.game_admins enable row level security;
revoke all on table public.game_admins from public, anon, authenticated;

-- Keep the original owner as the only account allowed to grant admin access.
insert into public.game_admins(user_id,granted_by,is_super_admin)
values ('c1224d4d-f533-4991-8c05-27d7ae3202e6'::uuid,'c1224d4d-f533-4991-8c05-27d7ae3202e6'::uuid,true)
on conflict (user_id) do update set is_super_admin=true;

create or replace function public.is_game_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists(select 1 from public.game_admins a where a.user_id=(select auth.uid()))
$$;

create or replace function public.is_game_super_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists(select 1 from public.game_admins a where a.user_id=(select auth.uid()) and a.is_super_admin)
$$;

create or replace function public.admin_access_status()
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object('is_admin',public.is_game_admin(),'can_manage_admins',public.is_game_super_admin())
$$;

revoke execute on function public.is_game_admin() from public,anon;
revoke execute on function public.is_game_super_admin() from public,anon;
revoke execute on function public.admin_access_status() from public,anon;
grant execute on function public.admin_access_status() to authenticated;

-- Administrative trainer grants. RPCs enforce the registered admin role server-side.
create or replace function public.admin_search_trainers(p_query text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_result jsonb;
begin
  if not public.is_game_admin() then
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
  if not public.is_game_admin() then
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

-- Read a limited trainer save summary for the allowlisted administrator.
create or replace function public.admin_get_trainer_details(p_target uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player jsonb;
  v_party jsonb;
  v_pc jsonb;
  v_items jsonb;
  v_key text;
begin
  if not public.is_game_admin() then
    raise exception 'Acesso restrito ao administrador.';
  end if;
  if p_target is null then raise exception 'Selecione um treinador.'; end if;
  select gs.player into v_player from public.game_saves gs where gs.user_id=p_target;
  if not found then raise exception 'Save do treinador nao encontrado.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('index',p.ordinality-1,'pokemon',p.value) order by p.ordinality),'[]'::jsonb)
    into v_party
    from jsonb_array_elements(case when jsonb_typeof(v_player->'party')='array' then v_player->'party' else '[]'::jsonb end)
      with ordinality as p(value,ordinality)
    where jsonb_typeof(p.value)='object';

  select coalesce(jsonb_agg(jsonb_build_object('box_index',b.ordinality-1,'slot_index',s.ordinality-1,'pokemon',s.value)
      order by b.ordinality,s.ordinality),'[]'::jsonb)
    into v_pc
    from jsonb_array_elements(case when jsonb_typeof(v_player#>'{pc,boxes}')='array' then v_player#>'{pc,boxes}' else '[]'::jsonb end)
      with ordinality as b(value,ordinality)
    cross join lateral jsonb_array_elements(case when jsonb_typeof(b.value)='array' then b.value else '[]'::jsonb end)
      with ordinality as s(value,ordinality)
    where jsonb_typeof(s.value)='object';

  v_items:=case when jsonb_typeof(v_player->'items')='object' then v_player->'items' else '{}'::jsonb end;
  foreach v_key in array array['balls','potions','antidote','antiparalyze','antiburn'] loop
    if jsonb_typeof(v_player->v_key)='number' then
      v_items:=jsonb_set(v_items,array[v_key],v_player->v_key,true);
    end if;
  end loop;
  select coalesce(jsonb_object_agg(i.key,i.value),'{}'::jsonb) into v_items
    from jsonb_each(v_items) as i(key,value)
    where jsonb_typeof(i.value)='number' and (i.value#>>'{}')::numeric>0;

  return jsonb_build_object(
    'user_id',p_target,
    'trainer_name',coalesce(nullif(trim(v_player->>'name'),''),'Treinador'),
    'money',case when jsonb_typeof(v_player->'money')='number' then greatest(0,(v_player->>'money')::numeric) else 0 end,
    'pokeCoins',case when jsonb_typeof(v_player->'pokeCoins')='number' then greatest(0,(v_player->>'pokeCoins')::numeric) else 0 end,
    'battlePoints',case when jsonb_typeof(v_player->'battlePoints')='number' then greatest(0,(v_player->>'battlePoints')::numeric) else 0 end,
    'party',v_party,'pc',v_pc,'items',v_items
  );
end;
$$;

-- Remove currencies, items, or an exact Pokemon entry without exposing table write access.
create or replace function public.admin_remove_trainer_asset(p_target uuid,p_kind text,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player jsonb;
  v_key text;
  v_amount integer;
  v_current numeric;
  v_new numeric;
  v_party jsonb;
  v_boxes jsonb;
  v_target jsonb;
  v_updated_party jsonb;
  v_index integer;
  v_box_index integer;
  v_slot_index integer;
  v_location text;
begin
  if not public.is_game_admin() then
    raise exception 'Acesso restrito ao administrador.';
  end if;
  if p_target is null then raise exception 'Selecione um treinador.'; end if;
  select gs.player into v_player from public.game_saves gs where gs.user_id=p_target for update;
  if not found then raise exception 'Save do treinador nao encontrado.'; end if;

  if p_kind in ('currency','item') then
    if coalesce(p_payload->>'amount','') !~ '^[0-9]{1,10}$' then raise exception 'Quantidade invalida.'; end if;
    v_amount:=(p_payload->>'amount')::integer;
    if v_amount<1 then raise exception 'Quantidade deve ser maior que zero.'; end if;
    if p_kind='currency' then
      v_key:=p_payload->>'field';
      if v_key is null or v_key not in ('money','pokeCoins','battlePoints') then raise exception 'Moeda invalida.'; end if;
      v_current:=case when jsonb_typeof(v_player->v_key)='number' then greatest(0,(v_player->>v_key)::numeric) else 0 end;
      if v_amount>v_current then raise exception 'Saldo insuficiente.'; end if;
      v_new:=v_current-v_amount;
      v_player:=jsonb_set(v_player,array[v_key],to_jsonb(v_new),true);
    else
      v_key:=p_payload->>'key';
      if v_key is null or v_key !~ '^[a-z0-9_]{1,50}$' then raise exception 'Item invalido.'; end if;
      v_current:=case
        when jsonb_typeof(v_player->v_key)='number' then greatest(0,(v_player->>v_key)::numeric)
        when jsonb_typeof(v_player->'items'->v_key)='number' then greatest(0,(v_player->'items'->>v_key)::numeric)
        else 0 end;
      if v_amount>v_current then raise exception 'Quantidade de item insuficiente.'; end if;
      v_new:=v_current-v_amount;
      v_player:=jsonb_set(v_player,'{items}',case when jsonb_typeof(v_player->'items')='object' then v_player->'items' else '{}'::jsonb end,true);
      v_player:=jsonb_set(v_player,array['items',v_key],to_jsonb(v_new),true);
      if jsonb_typeof(v_player->v_key)='number' then v_player:=jsonb_set(v_player,array[v_key],to_jsonb(v_new),true); end if;
    end if;
  elsif p_kind='pokemon' then
    v_location:=p_payload->>'location';
    if jsonb_typeof(p_payload->'expected') is distinct from 'object' then raise exception 'Pokemon selecionado invalido.'; end if;
    if v_location='party' then
      if coalesce(p_payload->>'index','') !~ '^[0-9]{1,3}$' then raise exception 'Posicao invalida.'; end if;
      v_index:=(p_payload->>'index')::integer;
      v_party:=case when jsonb_typeof(v_player->'party')='array' then v_player->'party' else '[]'::jsonb end;
      if v_index<0 or v_index>=jsonb_array_length(v_party) then raise exception 'Equipe alterada; atualize os dados.'; end if;
      v_target:=v_party->v_index;
      if v_target is distinct from p_payload->'expected' then raise exception 'Pokemon alterado; atualize os dados.'; end if;
      if jsonb_array_length(v_party)<=1 then raise exception 'O treinador precisa manter pelo menos um Pokemon na equipe.'; end if;
      select coalesce(jsonb_agg(p.value order by p.ordinality),'[]'::jsonb) into v_updated_party
        from jsonb_array_elements(v_party) with ordinality as p(value,ordinality)
        where p.ordinality<>v_index+1;
      v_player:=jsonb_set(v_player,'{party}',v_updated_party,true);
      if v_player->'poke'=v_target then v_player:=jsonb_set(v_player,'{poke}',v_updated_party->0,true); end if;
    elsif v_location='pc' then
      if coalesce(p_payload->>'box_index','') !~ '^[0-9]{1,3}$' or coalesce(p_payload->>'slot_index','') !~ '^[0-9]{1,3}$' then raise exception 'Posicao do PC invalida.'; end if;
      v_box_index:=(p_payload->>'box_index')::integer;
      v_slot_index:=(p_payload->>'slot_index')::integer;
      v_boxes:=case when jsonb_typeof(v_player#>'{pc,boxes}')='array' then v_player#>'{pc,boxes}' else '[]'::jsonb end;
      if v_box_index<0 or v_box_index>=jsonb_array_length(v_boxes) then raise exception 'PC alterado; atualize os dados.'; end if;
      if jsonb_typeof(v_boxes->v_box_index) is distinct from 'array' or v_slot_index<0 or v_slot_index>=jsonb_array_length(v_boxes->v_box_index) then raise exception 'Posicao do PC invalida.'; end if;
      v_target:=v_boxes->v_box_index->v_slot_index;
      if v_target is distinct from p_payload->'expected' then raise exception 'Pokemon alterado; atualize os dados.'; end if;
      v_player:=jsonb_set(v_player,array['pc','boxes',v_box_index::text,v_slot_index::text],'null'::jsonb,false);
    else
      raise exception 'Localizacao do Pokemon invalida.';
    end if;
  else
    raise exception 'Tipo de recurso invalido.';
  end if;

  update public.game_saves set player=v_player,updated_at=now() where user_id=p_target;
  return jsonb_build_object('user_id',p_target,'kind',p_kind);
end;
$$;

revoke execute on function public.admin_get_trainer_details(uuid) from public,anon;
revoke execute on function public.admin_remove_trainer_asset(uuid,text,jsonb) from public,anon;
grant execute on function public.admin_get_trainer_details(uuid) to authenticated;
grant execute on function public.admin_remove_trainer_asset(uuid,text,jsonb) to authenticated;

-- The original owner can promote an existing account by its login email.
create or replace function public.admin_promote_account(p_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(trim(coalesce(p_email,'')));
  v_target uuid;
  v_trainer_name text;
  v_already_admin boolean := false;
begin
  if not public.is_game_super_admin()
     or lower(coalesce(auth.jwt()->>'email','')) is distinct from 'aleffantunes12@gmail.com' then
    raise exception 'Somente o administrador principal pode conceder acesso administrativo.';
  end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Informe um e-mail valido.';
  end if;

  select u.id into v_target
  from auth.users u
  where lower(coalesce(u.email,''))=v_email
  order by u.created_at desc
  limit 1;
  if v_target is null then raise exception 'Nao existe uma conta cadastrada com esse e-mail.'; end if;
  if v_target=auth.uid() then raise exception 'Sua conta ja e administradora.'; end if;

  select exists(select 1 from public.game_admins a where a.user_id=v_target) into v_already_admin;
  insert into public.game_admins(user_id,granted_by,is_super_admin)
  values (v_target,auth.uid(),false)
  on conflict (user_id) do nothing;

  select coalesce(nullif(trim(tp.trainer_name),''),nullif(trim(gs.player->>'name'),''),'Conta')
    into v_trainer_name
  from public.game_saves gs
  left join public.trainer_profiles tp on tp.user_id=gs.user_id
  where gs.user_id=v_target;

  return jsonb_build_object('user_id',v_target,'email',v_email,'trainer_name',coalesce(v_trainer_name,'Conta'),'already_admin',v_already_admin);
end;
$$;

revoke execute on function public.admin_promote_account(text) from public,anon;
grant execute on function public.admin_promote_account(text) to authenticated;

notify pgrst, 'reload schema';
