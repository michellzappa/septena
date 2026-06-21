-- Current section state and section enable/disable history.
--
-- Section telemetry stores only catalog keys plus enabled/disabled state for an
-- anonymous install hash. It does not store user labels, colors, content, log
-- counts, or any section entry data.

create table if not exists telemetry_section_state (
  install_hash text not null references telemetry_install(install_hash) on delete cascade,
  section text not null check (length(section) between 1 and 48),
  enabled integer not null check (enabled in (0, 1)),
  platform text not null
    check (platform in ('iOS', 'macOS', 'Catalyst', 'Unknown')),
  app_version text not null default '',
  first_seen_at text not null default (datetime('now')),
  last_seen_at text not null default (datetime('now')),
  primary key (install_hash, section)
);

create index if not exists telemetry_section_state_section_idx
  on telemetry_section_state(section, enabled, platform, app_version);

create table if not exists telemetry_section_change_event (
  id text primary key,
  install_hash text not null references telemetry_install(install_hash) on delete cascade,
  section text not null check (length(section) between 1 and 48),
  enabled integer not null check (enabled in (0, 1)),
  platform text not null
    check (platform in ('iOS', 'macOS', 'Catalyst', 'Unknown')),
  app_version text,
  build text,
  created_at text not null default (datetime('now'))
);

create index if not exists telemetry_section_change_created_idx
  on telemetry_section_change_event(created_at desc, section, enabled);
