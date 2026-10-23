-- Restringe o Pokémon ativo ao círculo de amizades.
revoke select on table public.trainer_profiles from public, anon, authenticated;
grant select (user_id, trainer_name, last_seen)
  on table public.trainer_profiles to authenticated;

create or replace function public.social_friend_pokemon(p_friend_ids uuid[])
returns table (
  user_id uuid,
  active_pokemon_id integer,
  active_pokemon_name text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Entre na sua conta.';
  end if;

  return query
  select profile.user_id, profile.active_pokemon_id, profile.active_pokemon_name
  from public.trainer_profiles as profile
  join public.trainer_friends as friendship
    on friendship.user_id = auth.uid()
   and friendship.friend_id = profile.user_id
  where profile.user_id = any(coalesce(p_friend_ids, '{}'::uuid[]));
end;
$$;

revoke execute on function public.social_friend_pokemon(uuid[]) from public, anon;
grant execute on function public.social_friend_pokemon(uuid[]) to authenticated;
