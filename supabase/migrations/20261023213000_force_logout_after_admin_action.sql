create table if not exists public.account_session_controls (
  user_id uuid primary key references auth.users(id) on delete cascade,
  force_logout_at timestamptz not null
);

alter table public.account_session_controls enable row level security;

revoke all on table public.account_session_controls from public, anon;
grant select on table public.account_session_controls to authenticated;

drop policy if exists "Users can read their own session control" on public.account_session_controls;
create policy "Users can read their own session control"
  on public.account_session_controls
  for select
  to authenticated
  using (user_id = (select auth.uid()));
