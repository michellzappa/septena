# Open-Source Limitations

This repository is suitable for reading, forking, and building private copies,
but it is still a personal product codebase. These are the current limits that
matter before treating it as turnkey open-source software.

## Apple Account Coupling

Septena ships with product identifiers for the Septena app. Forks need their
own bundle IDs, App Groups, CloudKit containers, associated domains, and signing
team. See `docs/BUILDING_YOUR_OWN.md`.

## Report Sharing

Practitioner reports are health-adjacent shared links. The worker is designed
around App Attest, expiry, revocation, and rate limiting, and the public worker
template now defaults to `ATTEST_MODE = "enforce"`.

Before operating a public worker, validate App Attest on real hardware against
your bundle IDs. Use audit mode only on private staging infrastructure with
non-sensitive payloads.

## External Services

Defaults still point at Septena-branded services such as the hosted MCP gateway
and report endpoint. Forks should run their own services or disable those
features.

## Test Coverage

The existing core unit tests cover focused pure-Foundation logic. Broader
coverage is still needed around CloudKit sync, SwiftData migrations, mutators,
App Intents, import/export, report publishing, and end-to-end UI flows.

## Large Internal Files

Some areas grew as product surfaces expanded, especially Settings, dashboard,
persistence, and service orchestration. They work, but they are not yet as easy
for external contributors to modify as smaller modules would be.

## Brand

The MIT license covers the code. The Septena name, app icon, wordmark, and
third-party integration marks are not granted for derivative products. See
`NOTICE`.
