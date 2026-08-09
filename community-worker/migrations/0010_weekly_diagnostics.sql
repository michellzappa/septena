-- Optional, opt-in Septask weekly diagnostics. The install token is HMACed
-- before storage; no raw token, task data, or account identity is retained.
create table if not exists telemetry_weekly_batch (
  install_hash text not null,
  batch_id text not null,
  period text not null,
  platform text not null check (platform in ('macos', 'ios', 'catalyst', 'unknown')),
  app_version text not null,
  build text not null,
  os_major integer not null check (os_major between 1 and 99),
  architecture text not null check (architecture in ('arm64', 'x86_64', 'unknown')),
  features_json text not null,
  received_at text not null default (datetime('now')),
  primary key (install_hash, period),
  unique (batch_id)
);

create index if not exists telemetry_weekly_batch_period_idx
  on telemetry_weekly_batch (period, received_at);
