-- Valid supporter codes for the PokéCoins package selector.
-- Run after supabase-schema.sql and admin-panel-migration.sql.

create table if not exists public.poke_coin_supporter_codes (
  code text primary key check (code ~ '^[A-Z0-9]{2,24}$'),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.poke_coin_supporter_codes enable row level security;
revoke all on table public.poke_coin_supporter_codes from public, anon, authenticated;

insert into public.poke_coin_supporter_codes(code)
values ('MARCO'),('TELA'),('SINGLE'),('GATO')
on conflict (code) do nothing;

create or replace function public.poke_coins_validate_supporter_code(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_code text := upper(trim(coalesce(p_code,'')));
  v_valid boolean := false;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para validar o código.'; end if;
  if v_code !~ '^[A-Z0-9]{2,24}$' then return jsonb_build_object('valid',false); end if;

  select c.is_active into v_valid
  from public.poke_coin_supporter_codes c
  where c.code=v_code;

  return jsonb_build_object('valid',coalesce(v_valid,false),'code',case when coalesce(v_valid,false) then v_code else null end);
end;
$$;

create or replace function public.admin_list_supporter_codes()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_game_admin() then raise exception 'Acesso restrito ao administrador.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('code',c.code,'is_active',c.is_active,'created_at',c.created_at) order by c.code)
    from public.poke_coin_supporter_codes c
  ),'[]'::jsonb);
end;
$$;

create or replace function public.admin_create_supporter_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text := upper(trim(coalesce(p_code,'')));
  v_rows integer;
begin
  if not public.is_game_admin() then raise exception 'Acesso restrito ao administrador.'; end if;
  if v_code !~ '^[A-Z0-9]{2,24}$' then raise exception 'Use de 2 a 24 letras ou números, sem espaços ou símbolos.'; end if;

  insert into public.poke_coin_supporter_codes(code,created_by)
  values(v_code,auth.uid())
  on conflict (code) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows=0 then raise exception 'Esse código já está cadastrado.'; end if;

  return jsonb_build_object('code',v_code,'is_active',true);
end;
$$;

create or replace function public.admin_set_supporter_code_active(p_code text,p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text := upper(trim(coalesce(p_code,'')));
  v_active boolean;
begin
  if not public.is_game_admin() then raise exception 'Acesso restrito ao administrador.'; end if;
  if v_code !~ '^[A-Z0-9]{2,24}$' then raise exception 'Código inválido.'; end if;
  if p_active is null then raise exception 'Informe se o código deve ficar ativo.'; end if;

  update public.poke_coin_supporter_codes c
  set is_active=p_active,updated_at=now()
  where c.code=v_code
  returning c.is_active into v_active;
  if not found then raise exception 'Código não encontrado.'; end if;

  return jsonb_build_object('code',v_code,'is_active',v_active);
end;
$$;

revoke execute on function public.poke_coins_validate_supporter_code(text) from public,anon;
revoke execute on function public.admin_list_supporter_codes() from public,anon;
revoke execute on function public.admin_create_supporter_code(text) from public,anon;
revoke execute on function public.admin_set_supporter_code_active(text,boolean) from public,anon;
grant execute on function public.poke_coins_validate_supporter_code(text) to authenticated;
grant execute on function public.admin_list_supporter_codes() to authenticated;
grant execute on function public.admin_create_supporter_code(text) to authenticated;
grant execute on function public.admin_set_supporter_code_active(text,boolean) to authenticated;

notify pgrst,'reload schema';
