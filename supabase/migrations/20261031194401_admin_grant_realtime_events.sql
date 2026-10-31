-- Deliver administrator rewards to an online trainer without replacing their local save.
create table if not exists public.admin_grant_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('money','pokeCoins','battlePoints','item','pokemon')),
  payload jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists admin_grant_events_user_created_idx
  on public.admin_grant_events(user_id, created_at desc);

alter table public.admin_grant_events enable row level security;
revoke all on table public.admin_grant_events from public, anon, authenticated;
grant select on table public.admin_grant_events to authenticated;

drop policy if exists "Trainers can read their own reward events" on public.admin_grant_events;
create policy "Trainers can read their own reward events"
  on public.admin_grant_events for select to authenticated
  using ((select auth.uid()) = user_id);

do $$
begin
  if exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_catalog.pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'admin_grant_events'
     ) then
    execute 'alter publication supabase_realtime add table public.admin_grant_events';
  end if;
end;
$$;

create or replace function public.admin_grant_trainer_asset_notify(p_target uuid, p_kind text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_pokemon jsonb;
  v_event_payload jsonb;
  v_result jsonb;
  v_event_id uuid;
begin
  if not public.is_game_admin() then
    raise exception 'Acesso restrito ao administrador.';
  end if;
  if p_target is null then raise exception 'Selecione um treinador.'; end if;

  select player into v_before from public.game_saves where user_id = p_target for update;
  if not found then raise exception 'Save do treinador nao encontrado.'; end if;

  v_result := public.admin_grant_trainer_asset(p_target, p_kind, p_payload);
  select player into v_after from public.game_saves where user_id = p_target;

  if p_kind = 'pokemon' then
    with before_pokemon as (
      select value->>'tradeId' as trade_id
      from jsonb_array_elements(coalesce(v_before->'party', '[]'::jsonb)) as party(value)
      union all
      select slot.value->>'tradeId' as trade_id
      from jsonb_array_elements(coalesce(v_before->'pc'->'boxes', '[]'::jsonb)) as box(value)
      cross join lateral jsonb_array_elements(case when jsonb_typeof(box.value) = 'array' then box.value else '[]'::jsonb end) as slot(value)
    ), after_pokemon as (
      select value as pokemon
      from jsonb_array_elements(coalesce(v_after->'party', '[]'::jsonb)) as party(value)
      union all
      select slot.value as pokemon
      from jsonb_array_elements(coalesce(v_after->'pc'->'boxes', '[]'::jsonb)) as box(value)
      cross join lateral jsonb_array_elements(case when jsonb_typeof(box.value) = 'array' then box.value else '[]'::jsonb end) as slot(value)
    )
    select after_pokemon.pokemon into v_pokemon
    from after_pokemon
    where nullif(after_pokemon.pokemon->>'tradeId', '') is not null
      and not exists (
        select 1 from before_pokemon
        where before_pokemon.trade_id = after_pokemon.pokemon->>'tradeId'
      )
    limit 1;
    if v_pokemon is null then raise exception 'Nao foi possivel identificar o Pokemon enviado.'; end if;
    v_event_payload := jsonb_build_object('pokemon', v_pokemon);
  else
    v_event_payload := p_payload;
  end if;

  insert into public.admin_grant_events(user_id, kind, payload)
  values (p_target, p_kind, v_event_payload)
  returning id into v_event_id;

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object('event_id', v_event_id);
end;
$$;

revoke execute on function public.admin_grant_trainer_asset_notify(uuid,text,jsonb) from public, anon;
grant execute on function public.admin_grant_trainer_asset_notify(uuid,text,jsonb) to authenticated;
