# Android releases & distribution

Septena Android (`app.septena.android`), published by **CENTAUR LABS OÜ**, ships
on two channels (mirroring [Mac releases](RELEASING-MAC.md)):

- **Google Play Store:** a signed Android App Bundle (`.aab`), uploaded from CI
  or manually to Play Console testing tracks and Production.
- **Direct APK download:** a signed release APK (`Septena.apk` /
  `Septena-X.Y.Z.apk` + `SHA256SUMS.txt` + `android-release.json`) published on
  GitHub Releases (`--latest=false`) for direct downloads (`septena.app/android/download`)
  and Obtainium.

Everyday CI ([`.github/workflows/android.yml`](../.github/workflows/android.yml))
keeps signing debug and release test APKs with the separate `septena-tester` key
(`scripts/android-tester-keystore.sh`) so existing developer phones continue
updating in place without colliding with public releases.

---

## One-time setup (Centaur Labs OÜ)

### 1. Google Play Console Organization account

1. Register a Google Play Developer account as an **Organization** (not
   Personal) at <https://play.google.com/console/signup>. Organization accounts
   skip the 12-tester / 14-day closed-test gate for Production.
2. Enter **CENTAUR LABS OÜ** and its existing **D-U-N-S number** (the same one
   registered for Apple Developer Team `992N457T8D`).
3. Verify the matching Google Payments profile ($25 one-time fee), website
   (`https://septena.app`), developer email, and phone.

### 2. Generate permanent Centaur Labs signing keys

Run once on mz's Mac:

```bash
scripts/android-release-keystore.sh
```

This creates two permanent 4096-bit PKCS12 keystores under
`~/.config/signing/centaur-labs/android/` (chmod `700`/`600`), backs them up in
the macOS login Keychain, syncs the four GitHub Actions secrets, and prints the
certificate fingerprints (never passwords):

| Keystore | Alias | GitHub secrets | Purpose |
|---|---|---|---|
| `septena-android-release.p12` | `septena-release` | `ANDROID_RELEASE_KEYSTORE_B64`, `ANDROID_RELEASE_KEYSTORE_PASSWORD` | Signs public direct-download APKs (and can be enrolled into Play App Signing via PEPK) |
| `septena-android-play-upload.p12` | `septena-play-upload` | `ANDROID_PLAY_UPLOAD_KEYSTORE_B64`, `ANDROID_PLAY_UPLOAD_KEYSTORE_PASSWORD` | Signs `.aab` bundles uploaded to Google Play Console |

**Back up both `.p12` files and their Keychain passwords into 1Password
immediately.** Losing `septena-android-release.p12` strands every direct-APK
install from future updates.

### 3. Choose Play App Signing mode (before the very first `.aab` upload)

In Google Play Console (**Create app** → **Test and release** → **Setup** →
**App signing**):

- **Option A (Recommended — unified certificate across Play & direct APK):**
  Choose *"Export and upload a key from Java keystore"*, download `pepk.jar` and
  Google's encryption public key, and run the `java -jar pepk.jar` command
  printed by `scripts/android-release-keystore.sh` against
  `septena-android-release.p12`. Then upload your first `.aab` signed with
  `septena-android-play-upload.p12` (the upload key). Result: direct APKs and
  Play Store builds share the exact same final certificate and update each other
  in place.
- **Option B (Separate keys):** Let Google manage and generate the Play app
  signing key, and upload your first `.aab` signed with
  `septena-android-play-upload.p12`. Direct APKs remain signed with
  `septena-android-release.p12` (users switching between channels must uninstall
  first).

### 4. First manual `.aab` upload & Play Developer API (optional CI uploads)

Google Play requires the **very first `.aab`** of a new app to be uploaded once
in the Play Console web UI (which permanently locks `app.septena.android`):

1. Trigger **Actions → Android Release → Run workflow** (`play_track: none`,
   `publish_github_release: false`).
2. Download the `septena-android-release-<version>` artifact and upload
   `Septena-<version>.aab` (plus `mapping-<version>.txt`) to Play Console's
   **Internal testing** track.
3. Fill in store listing copy, Data Safety, permissions, and graphics from
   `docs/PLAYSTORE.md` and `appstore/playstore/` in the private `septena/studio` repo.
4. To enable automated CI uploads for every subsequent release:
   - Create a service account in Google Cloud Console with a JSON key.
   - Enable the **Google Play Android Developer API** in that Cloud project.
   - In Play Console (**Users and permissions → Invite new users**), grant the
     service account *Release to testing tracks* (and optionally *Release to
     production*) for `Septena`.
   - Save the JSON key as GitHub Actions secret
     `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`.

---

## Cutting a release

`MARKETING_VERSION` in `project.yml` is the version across every platform
([VERSIONING.md](VERSIONING.md)); the Android `versionCode` is the git commit
count.

### Direct APK + build bundle (tag release)

```bash
git checkout main && git pull
git tag android-v0.9.0
git push origin android-v0.9.0
```

[`.github/workflows/android-release.yml`](../.github/workflows/android-release.yml)
runs `:core:test`, `:store:test`, and `:app:testDebugUnitTest`, builds both the
signed direct APK (`Septena-0.9.0.apk` + `Septena.apk`) and the signed Play App
Bundle (`Septena-0.9.0.aab` + `mapping-0.9.0.txt`), verifies the APK signature
and 16 KB ELF page alignment (`scripts/check-android-16kb.sh`), uploads all
files as a 30-day workflow artifact, and creates a GitHub Release with
**`--latest=false`**.

> **Why `--latest=false` is mandatory:** installed Mac copies read
> `https://septena.app/mac/appcast.xml`, which redirects to `/releases/latest`
> ([RELEASING-MAC.md](RELEASING-MAC.md)). The newest GitHub release must always
> remain a Mac release.

### Uploading to Google Play from CI

Once the first manual `.aab` is in Play Console and
`GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` is set, run **Actions → Android Release →
Run workflow** and select:

- `play_track`: `internal` (or `alpha` / `beta`)
- `play_status`: `draft` while the app is still in Play Console draft state
  (Google Play rejects `completed` API uploads before the first review), or
  `completed` once the app is published.

---

## Direct APK website redirect & Obtainium

- **Website download URL (`septena-site`):** point
  `https://septena.app/android/download` to the latest `android-v*` release's
  `Septena.apk` asset (or read `android-release.json`), keeping
  `https://septena.app/mac/appcast.xml` pinned to `/releases/latest`.
- **Obtainium:** users can track `https://github.com/septena/septena` with
  release filter `^android-v` and APK regex `^Septena-.*\.apk$`.

---

## 16 KB page alignment note (Android 15+ / Google Play)

Google Play enforces 16 KB ELF LOAD alignment on 64-bit native `.so` libraries
(`arm64-v8a`, `x86_64`) for `targetSdk >= 35`.

- `android/app/build.gradle.kts` sets `packaging.jniLibs.useLegacyPackaging = false`
  so `.so` files are stored uncompressed and 16 KB zip-aligned.
- `.github/workflows/core.yml` passes `-C link-arg=-Wl,-z,max-page-size=16384`
  for `aarch64-linux-android` and `x86_64-linux-android`.
- `scripts/check-android-16kb.sh` verifies every 64-bit `.so` in the built APK.
  If a pinned `core-v*` release predates the linker flag and triggers the
  warning in `android-release.yml`, cut and pin a new `core-v*` release
  (`core/release/README.md`) before uploading to Google Play.
