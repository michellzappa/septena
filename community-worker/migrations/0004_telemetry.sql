-- Minimal anonymous telemetry state.
--
-- `telemetry_install` stores the current analytics preference per anonymous
-- app install. The Worker stores only an HMAC of the app-local install id.
-- Usage events are never recorded here when analytics is disabled.

create table if not exists telemetry_install (
  install_hash text primary key,
  first_seen_at text not null default (datetime('now')),
  last_seen_at text not null default (datetime('now')),
  last_consent_at text not null default (datetime('now')),
  analytics_enabled integer not null
    check (analytics_enabled in (0, 1)),
  platform text not null
    check (platform in ('iOS', 'macOS', 'Catalyst', 'Unknown')),
  app_version text,
  build text,
  check (app_version is null or length(app_version) <= 32),
  check (build is null or length(build) <= 32)
);

create index if not exists telemetry_install_enabled_idx
  on telemetry_install(analytics_enabled, platform, app_version);

create table if not exists telemetry_consent_event (
  id text primary key,
  install_hash text not null references telemetry_install(install_hash) on delete cascade,
  enabled integer not null
    check (enabled in (0, 1)),
  platform text not null
    check (platform in ('iOS', 'macOS', 'Catalyst', 'Unknown')),
  app_version text,
  build text,
  created_at text not null default (datetime('now'))
);

create index if not exists telemetry_consent_event_created_idx
  on telemetry_consent_event(created_at desc);

create table if not exists telemetry_daily_rollup (
  day text not null,
  event text not null
    check (event in ('app_open', 'screen_view')),
  screen text not null default '',
  platform text not null
    check (platform in ('iOS', 'macOS', 'Catalyst', 'Unknown')),
  app_version text not null default '',
  count integer not null default 0
    check (count >= 0),
  primary key (day, event, screen, platform, app_version)
);

create index if not exists telemetry_daily_rollup_day_idx
  on telemetry_daily_rollup(day desc, event, screen);
