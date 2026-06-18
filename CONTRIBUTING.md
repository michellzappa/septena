# Contributing

Septena is currently maintained as a personal app that is open for reading,
forking, and focused patches. Contributions are welcome when they fit the
existing architecture and keep user data private by default.

## Before Changing Code

- Read `README.md` for the architecture overview.
- Read `docs/BUILDING_YOUR_OWN.md` if you are building under your own Apple
  account.
- Prefer current code over older handoff docs when they disagree.

## Development

Use XcodeGen as the project source of truth:

```bash
xcodegen generate
```

Run the core test scheme before opening a PR:

```bash
xcodebuild -project Septena.xcodeproj -scheme SeptenaCoreTests -destination 'platform=macOS,name=My Mac' test
```

## Code Guidelines

- Route writes through mutators when a mutator exists.
- Keep SwiftData and CloudKit behavior local-first: local mirror first, sync
  second.
- Keep section identity in `SectionManifest` and section behavior in
  `SectionPlugin`.
- Avoid broad network/security exceptions. Add narrowly scoped exceptions with
  comments when required.
- Do not commit personal signing settings, API credentials, screenshots,
  generated build output, or dependency folders.

## Security

Report vulnerabilities privately using `SECURITY.md`. Do not open public issues
for leaked credentials, auth bypasses, CloudKit exposure, report-link issues, or
anything involving private user data.
