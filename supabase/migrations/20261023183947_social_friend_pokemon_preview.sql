-- Guarda somente os dados públicos mínimos para mostrar o Pokémon ativo de amigos.
alter table public.trainer_profiles
  add column if not exists active_pokemon_id integer,
  add column if not exists active_pokemon_name text;

create or replace function public.social_presence_with_pokemon(
  p_name text,
  p_pokemon_id integer,
  p_pokemon_name text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trainer_name text;
  v_pokemon_id integer;
  v_pokemon_name text;
begin
  if auth.uid() is null then
    raise exception 'Entre na sua conta.';
  end if;

  v_trainer_name := left(trim(coalesce(p_name, 'Treinador')), 24);
  if v_trainer_name = '' then v_trainer_name := 'Treinador'; end if;

  if p_pokemon_id between 1 and 2000 then
    v_pokemon_id := p_pokemon_id;
    v_pokemon_name := nullif(left(trim(coalesce(p_pokemon_name, '')), 40), '');
  end if;

  insert into public.trainer_profiles(user_id, trainer_name, last_seen, active_pokemon_id, active_pokemon_name)
  values (auth.uid(), v_trainer_name, now(), v_pokemon_id, v_pokemon_name)
  on conflict (user_id) do update set
    trainer_name = excluded.trainer_name,
    last_seen = excluded.last_seen,
    active_pokemon_id = excluded.active_pokemon_id,
    active_pokemon_name = excluded.active_pokemon_name;
end;
$$;

revoke execute on function public.social_presence_with_pokemon(text, integer, text) from public, anon;
grant execute on function public.social_presence_with_pokemon(text, integer, text) to authenticated;
