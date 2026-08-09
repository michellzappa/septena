# Septask Mac releases

Septask Mac is distributed outside the Mac App Store as a Developer ID signed
and Apple-notarized ZIP attached to a GitHub Release. Sparkle checks the signed
feed at `https://updates.centaur-labs.io/appcast.xml`.

The appcast is deployed as a GitHub Pages site from the `release-macos` workflow;
the ZIP remains a GitHub Release asset. Sparkle verifies both the Apple code
signature and its Ed25519 archive signature before installing an update.

## Release flow

1. Bump `MARKETING_VERSION` in `project.yml` and update the release entry in
   `Septena/Resources/changelog.json` when appropriate.
2. Commit the clean tree.
3. Run `scripts/cut-macos-release.sh` (or push a matching `vX.Y.Z` tag).
4. GitHub Actions builds `Septask.app`, signs it with Developer ID, notarizes
   and staples it, creates the GitHub Release, then publishes the appcast and
   release landing page to GitHub Pages.

The Mac app exposes **Check for Updates…** in the application menu and in
Settings → About. Sparkle owns the download, verification, installation, and
relaunch UI.

## One-time secrets

Configure these GitHub Actions secrets:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE_P12` / `MACOS_CERTIFICATE_PASSWORD` | Developer ID Application certificate |
| `KEYCHAIN_PASSWORD` | Temporary CI keychain password |
| `APPLE_API_KEY` / `APPLE_API_KEY_ID` / `APPLE_API_ISSUER_ID` | notarization |
| `SPARKLE_PUBLIC_ED_KEY` | Public Sparkle Ed25519 key compiled into the app |
| `SPARKLE_PRIVATE_ED_KEY` | Private key used only to sign update archives/appcast |
| `SEPTASK_PROVISION_PROFILE_BASE64` | Optional CloudKit provisioning profile |
| `SEPTASK_TEAM_ID` | Apple team ID used when expanding app-group entitlements |

Generate the Sparkle key pair with Sparkle's `generate_keys`. Store the private
key in GitHub Actions only. The public value is not secret and may also be put
in a local `Config/Secrets.xcconfig` for release testing.

The custom domain also needs a one-time DNS CNAME from
`updates.centaur-labs.io` to the GitHub Pages hostname for this repository, and
GitHub repository Settings → Pages must use **GitHub Actions** as its source.
