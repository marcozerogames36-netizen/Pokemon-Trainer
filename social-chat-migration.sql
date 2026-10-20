-- Execute no SQL Editor do Supabase para habilitar o chat entre amigos.
create table if not exists public.trainer_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 500),
  created_at timestamptz not null default now(),
  check (sender_id <> recipient_id)
);

create index if not exists trainer_messages_sender_idx
  on public.trainer_messages(sender_id,recipient_id,created_at desc);
create index if not exists trainer_messages_recipient_idx
  on public.trainer_messages(recipient_id,sender_id,created_at desc);

alter table public.trainer_messages enable row level security;
revoke all on table public.trainer_messages from public,anon,authenticated;
grant select on table public.trainer_messages to authenticated;
grant insert (sender_id,recipient_id,body) on table public.trainer_messages to authenticated;

drop policy if exists "Friends can read their messages" on public.trainer_messages;
create policy "Friends can read their messages" on public.trainer_messages
  for select to authenticated
  using (
    ((select auth.uid())=sender_id or (select auth.uid())=recipient_id)
    and exists (
      select 1 from public.trainer_friends f
      where f.user_id=(select auth.uid())
        and f.friend_id=case when sender_id=(select auth.uid()) then recipient_id else sender_id end
    )
  );

drop policy if exists "Friends can send messages" on public.trainer_messages;
create policy "Friends can send messages" on public.trainer_messages
  for insert to authenticated
  with check (
    sender_id=(select auth.uid())
    and exists (
      select 1 from public.trainer_friends f
      where f.user_id=(select auth.uid()) and f.friend_id=recipient_id
    )
  );
