-- Share the selected trainer avatar with friends in the social presence list.
alter table public.trainer_profiles
  add column if not exists trainer_avatar_id text;

grant select (trainer_avatar_id) on table public.trainer_profiles to authenticated;
grant insert (trainer_avatar_id), update (trainer_avatar_id)
  on table public.trainer_profiles to authenticated;

create or replace function public.social_presence_with_trainer(
  p_name text,
  p_pokemon_id integer,
  p_pokemon_name text,
  p_trainer_avatar_id text
) returns void
language plpgsql security definer set search_path='' as $$
declare
  v_name text;
  v_pokemon_id integer;
  v_pokemon_name text;
  v_avatar_id text;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;

  v_name:=left(trim(coalesce(p_name,'Treinador')),24);
  if v_name='' then v_name:='Treinador'; end if;
  if p_pokemon_id between 1 and 2000 then
    v_pokemon_id:=p_pokemon_id;
    v_pokemon_name:=nullif(left(trim(coalesce(p_pokemon_name,'')),40),'');
  end if;
  if p_trainer_avatar_id in ('red','leaf-gen3','brock','misty','ltsurge','erika','koga','sabrina','blaine','giovanni') then
    v_avatar_id:=p_trainer_avatar_id;
  end if;

  insert into public.trainer_profiles(user_id,trainer_name,last_seen,active_pokemon_id,active_pokemon_name,trainer_avatar_id)
    values(auth.uid(),v_name,now(),v_pokemon_id,v_pokemon_name,v_avatar_id)
  on conflict(user_id) do update set trainer_name=excluded.trainer_name,last_seen=excluded.last_seen,
    active_pokemon_id=excluded.active_pokemon_id,active_pokemon_name=excluded.active_pokemon_name,
    trainer_avatar_id=coalesce(excluded.trainer_avatar_id,public.trainer_profiles.trainer_avatar_id);
end;
$$;

revoke execute on function public.social_presence_with_trainer(text,integer,text,text) from public,anon;
grant execute on function public.social_presence_with_trainer(text,integer,text,text) to authenticated;

notify pgrst, 'reload schema';