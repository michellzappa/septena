-- Daily aggregate section usage.
--
-- This records counts of section drawer opens by catalog section key. It is a
-- rollup only: no per-install rows or per-use event log are stored.

create table if not exists telemetry_section_daily_rollup (
  day text not null,
  section text not null check (length(section) between 1 and 48),
  platform text not null
    check (platform in ('iOS', 'macOS', 'Catalyst', 'Unknown')),
  app_version text not null default '',
  count integer not null default 0
    check (count >= 0),
  primary key (day, section, platform, app_version)
);

create index if not exists telemetry_section_daily_rollup_day_idx
  on telemetry_section_daily_rollup(day desc, section);
