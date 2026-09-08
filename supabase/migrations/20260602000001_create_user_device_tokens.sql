-- Create user_device_tokens table to store FCM tokens
create table public.user_device_tokens (
  id uuid not null default gen_random_uuid (),
  user_id uuid not null,
  fcm_token text not null,
  device_type text null, -- 'android' or 'ios'
  created_at timestamp with time zone null default now(),
  updated_at timestamp with time zone null default now(),
  constraint user_device_tokens_pkey primary key (id),
  constraint user_device_tokens_user_id_fkey foreign key (user_id) references auth.users (id) on delete cascade,
  constraint user_device_tokens_token_key unique (fcm_token)
);

-- Indices for performance
create index if not exists idx_user_device_tokens_user_id on public.user_device_tokens using btree (user_id);
create index if not exists idx_user_device_tokens_token on public.user_device_tokens using btree (fcm_token);

-- Enable RLS
alter table public.user_device_tokens enable row level security;

-- Policy to allow authenticated users to perform operations on their own tokens
create policy "Users can manage their own device tokens"
on public.user_device_tokens
for all
to authenticated
using ( (select auth.uid()) = user_id )
with check ( (select auth.uid()) = user_id );
