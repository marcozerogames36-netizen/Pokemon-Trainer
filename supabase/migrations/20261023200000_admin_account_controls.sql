-- Restrict account resets to the original super administrator.
-- The Auth user and login credentials remain intact; only game progress is cleared.
create or replace function public.admin_reset_trainer_progress(p_target uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trainer_name text;
  v_had_save boolean := false;
begin
  if not public.is_game_super_admin()
     or lower(coalesce(auth.jwt()->>'email','')) is distinct from 'aleffantunes12@gmail.com' then
    raise exception 'Somente o administrador principal pode resetar o progresso de uma conta.';
  end if;
  if p_target is null then raise exception 'Selecione um treinador.'; end if;
  if p_target=auth.uid() then raise exception 'O progresso da conta administrativa atual não pode ser resetado por esta opção.'; end if;
  if exists(select 1 from public.game_admins a where a.user_id=p_target) then
    raise exception 'Contas administrativas protegidas não podem ser resetadas por esta opção.';
  end if;

  select coalesce(nullif(trim(tp.trainer_name),''),nullif(trim(gs.player->>'name'),''),'Treinador'),
         gs.user_id is not null
    into v_trainer_name,v_had_save
    from (select p_target as user_id) target
    left join public.game_saves gs on gs.user_id=target.user_id
    left join public.trainer_profiles tp on tp.user_id=target.user_id;

  delete from public.game_saves where user_id=p_target;
  delete from public.trainer_profiles where user_id=p_target;

  return jsonb_build_object('user_id',p_target,'trainer_name',v_trainer_name,'had_save',v_had_save);
end;
$$;

revoke execute on function public.admin_reset_trainer_progress(uuid) from public,anon;
grant execute on function public.admin_reset_trainer_progress(uuid) to authenticated;

notify pgrst, 'reload schema';
