-- Notify online trainers immediately when an administrator removes assets.
alter table public.admin_grant_events
  drop constraint if exists admin_grant_events_kind_check;

alter table public.admin_grant_events
  add constraint admin_grant_events_kind_check
  check (kind in ('money','pokeCoins','battlePoints','item','pokemon','remove','removeAllPokemon'));

create or replace function public.admin_remove_trainer_asset_notify(p_target uuid, p_kind text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_event_id uuid;
begin
  if not public.is_game_admin() then
    raise exception 'Acesso restrito ao administrador.';
  end if;
  v_result := public.admin_remove_trainer_asset(p_target, p_kind, p_payload);

  insert into public.admin_grant_events(user_id, kind, payload)
  values (p_target, 'remove', jsonb_build_object('operation', jsonb_build_object('kind', p_kind, 'payload', p_payload), 'result', v_result))
  returning id into v_event_id;

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object('event_id', v_event_id);
end;
$$;

revoke execute on function public.admin_remove_trainer_asset_notify(uuid,text,jsonb) from public, anon;
grant execute on function public.admin_remove_trainer_asset_notify(uuid,text,jsonb) to authenticated;

create or replace function public.admin_remove_all_trainer_pokemon_notify(p_target uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_event_id uuid;
begin
  if not public.is_game_admin() then
    raise exception 'Acesso restrito ao administrador.';
  end if;
  v_result := public.admin_remove_all_trainer_pokemon(p_target);

  insert into public.admin_grant_events(user_id, kind, payload)
  values (p_target, 'removeAllPokemon', v_result)
  returning id into v_event_id;

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object('event_id', v_event_id);
end;
$$;

revoke execute on function public.admin_remove_all_trainer_pokemon_notify(uuid) from public, anon;
grant execute on function public.admin_remove_all_trainer_pokemon_notify(uuid) to authenticated;
