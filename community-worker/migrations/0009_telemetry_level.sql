-- Graded telemetry level (none/minimal/balanced/full).
--
-- The app replaced the bare "share usage data" boolean with a privacy *level*.
-- The wire still carries `analyticsEnabled` for back-compat, but `level` is the
-- richer signal — persist it alongside the existing rows. Nullable so pre-level
-- clients keep working.
--
-- Also adds a counter for fully anonymized opt-out pings: when the user turns
-- analytics Off, the app sends a single identity-free ping (no install id,
-- version, build, or platform) so aggregate opt-out counts stay knowable without
-- a final identifying ping. Those land here, not in the per-install tables.

alter table telemetry_install
  add column level text
    check (level is null or level in ('none', 'minimal', 'balanced', 'full'));

alter table telemetry_consent_event
  add column level text
    check (level is null or level in ('none', 'minimal', 'balanced', 'full'));

create table if not exists telemetry_anon_optout_daily (
  day text primary key,
  count integer not null default 0
    check (count >= 0)
);
