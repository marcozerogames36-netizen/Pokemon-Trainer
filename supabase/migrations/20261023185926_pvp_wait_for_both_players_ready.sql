alter table public.pvp_rooms
  add column if not exists host_ready boolean not null default false,
  add column if not exists guest_ready boolean not null default false;

-- Partidas jÃ¡ iniciadas antes desta migraÃ§Ã£o jÃ¡ foram confirmadas pelos participantes.
update public.pvp_rooms set host_ready=true,guest_ready=true where status='battle';

do $$
begin
  if not exists(select 1 from pg_constraint where conname='pvp_battle_requires_both_ready') then
    alter table public.pvp_rooms add constraint pvp_battle_requires_both_ready
      check(status<>'battle' or (host_ready and guest_ready));
  end if;
end $$;

create or replace function public.pvp_join_room(p_code text,p_trainer text,p_team jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_room public.pvp_rooms;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para entrar em uma sala.'; end if;
  if not public.pvp_valid_team(p_team) then
    raise exception 'Escolha entre 1 e 6 PokÃ©mon.';
  end if;
  update public.pvp_rooms
    set guest_id=auth.uid(),guest_name=left(trim(coalesce(p_trainer,'Treinador')),24),
        guest_team=p_team,guest_ready=false,status='ready',updated_at=now()
    where room_code=upper(p_code) and status='waiting' and guest_id is null
      and host_id<>auth.uid() and expires_at>now()
    returning * into v_room;
  if not found then raise exception 'Sala nÃ£o encontrada, expirada ou jÃ¡ ocupada.'; end if;
  return to_jsonb(v_room);
end;
$$;

create or replace function public.pvp_confirm_ready(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_room public.pvp_rooms;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta.'; end if;
  select * into v_room from public.pvp_rooms where room_code=upper(p_code) for update;
  if not found or (v_room.host_id is distinct from auth.uid() and v_room.guest_id is distinct from auth.uid()) then
    raise exception 'VocÃª nÃ£o participa desta sala.';
  end if;
  if v_room.status<>'ready' or v_room.guest_id is null or v_room.expires_at<=now() then
    raise exception 'A sala ainda nÃ£o estÃ¡ pronta para confirmaÃ§Ã£o.';
  end if;
  if v_room.host_id=auth.uid() then
    update public.pvp_rooms set host_ready=true,updated_at=now() where id=v_room.id returning * into v_room;
  else
    update public.pvp_rooms set guest_ready=true,updated_at=now() where id=v_room.id returning * into v_room;
  end if;
  return to_jsonb(v_room);
end;
$$;

revoke execute on function public.pvp_confirm_ready(text) from public,anon;
grant execute on function public.pvp_confirm_ready(text) to authenticated;
