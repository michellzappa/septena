-- Keep opt-out semantics strict for per-install section telemetry.

delete from telemetry_section_state
where install_hash in (
  select install_hash from telemetry_install where analytics_enabled = 0
);

delete from telemetry_section_change_event
where install_hash in (
  select install_hash from telemetry_install where analytics_enabled = 0
);
