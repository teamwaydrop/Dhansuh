-- Create feature_flags table
create table if not exists feature_flags (
  key varchar primary key,
  value jsonb not null,
  min_app_version varchar,
  description text,
  updated_at timestamp default now()
);

-- Enable RLS
alter table feature_flags enable row level security;

-- Create public read access policy
create policy "Allow public read access to feature flags" 
  on feature_flags for select 
  using (true);

-- Seed default feature flag values
insert into feature_flags (key, value, min_app_version, description) values
  ('wallet_enabled', 'true'::jsonb, '1.0.0', 'Enables rider wallet and ledger screens'),
  ('scheduled_rides_enabled', 'true'::jsonb, '1.0.0', 'Enables scheduled ride booking and dispatching'),
  ('heatmap_enabled', 'false'::jsonb, null, 'Enables WebGL demand heatmap overlays'),
  ('realtime_enabled', 'true'::jsonb, null, 'Emergency kill switch for realtime database channels'),
  ('trip_sharing_enabled', 'true'::jsonb, null, 'Enables sharing live trip details via secure links'),
  ('dispatch_enabled', 'true'::jsonb, null, 'Global switch for automatic driver assignment loops')
on conflict (key) do update set
  value = excluded.value,
  min_app_version = excluded.min_app_version,
  description = excluded.description;
