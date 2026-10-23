-- Permite atualizar apenas a própria presença; o perfil continua visível aos treinadores autenticados.
grant insert (user_id, trainer_name, last_seen, active_pokemon_id, active_pokemon_name),
      update (trainer_name, last_seen, active_pokemon_id, active_pokemon_name)
  on table public.trainer_profiles to authenticated;

drop policy if exists "Create own trainer presence" on public.trainer_profiles;
create policy "Create own trainer presence"
  on public.trainer_profiles for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists "Update own trainer presence" on public.trainer_profiles;
create policy "Update own trainer presence"
  on public.trainer_profiles for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

alter function public.social_presence_with_pokemon(text, integer, text) security invoker;
