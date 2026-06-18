# Building Your Own Copy

Septena is an Apple-platform app with entitlements. A plain clone can generate
the Xcode project, but a fully signed build needs your own Apple Developer
account, bundle identifiers, CloudKit container, and app group.

## Prerequisites

- Xcode 26 or newer.
- XcodeGen (`brew install xcodegen`).
- An Apple Developer account if you want CloudKit, HealthKit, widgets, Watch,
  Live Activities, App Groups, or device builds.
- iCloud signed in on the simulator or device.

## Local Signing Settings

Copy the example config:

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
```

Set:

```xcconfig
SEPTENA_DEVELOPMENT_TEAM = YOURTEAMID
```

`Config/Secrets.xcconfig` is gitignored. Keep local signing and optional
integration credentials there.

## Identifiers To Replace

The repository keeps Septena's product identifiers as defaults. To ship or
sync under your own account, replace them consistently:

- Bundle IDs in `project.yml`.
- CloudKit containers in `*.entitlements` and Swift constants that reference
  `iCloud.com.septena.cloud`.
- App Groups in `*.entitlements` and shared-data constants that reference
  `group.com.septena.cloud`.
- URL schemes if you do not want to use `septena://`.
- Associated domains if you run your own MCP gateway.

After changing `project.yml`, regenerate:

```bash
xcodegen generate
```

## CloudKit

The app uses the private iCloud database and custom zone `septena-v1`.
Create your own iCloud container in the Apple Developer portal, enable CloudKit
for the relevant app targets, and update entitlements before relying on sync.

Schema creation happens from the app's CloudKit record writes. Review
`docs/CloudKitSchema.md` before deploying a production container.

## Optional Integrations

The app builds without these:

- Withings: set `WITHINGS_CLIENT_ID` and `WITHINGS_CLIENT_SECRET` in
  `Config/Secrets.xcconfig`.
- Claude MCP gateway: set `CLOUDKIT_WEB_API_TOKEN` only if you run your own
  gateway.
- Oura, GitHub, and Readwise tokens are entered in the app and stored locally.

## Report Worker

`reports-worker/wrangler.toml` is an open-source template. Replace the
Cloudflare account, route, KV namespace IDs, and App Attest app IDs before
deploying.

Keep `ATTEST_MODE = "enforce"` for production. Use `"audit"` only on a private
staging worker while validating App Attest with non-sensitive payloads.
