# Mac releases

The Mac app ships on two channels (ADR 0026):

- **The download:** a Developer ID signed and Apple-notarized app on GitHub
  Releases. It updates itself with Sparkle. This page is about this channel.
- **The Mac App Store:** planned for launch (#266). It sells Plus through
  Apple. The download cannot, and honors a Plus bought anywhere else.

## Release

MZ decides when a release goes out. Then, in one session on mz-mini:

1. Set `MARKETING_VERSION` in `project.yml` (`docs/VERSIONING.md`), run
   `xcodegen generate`, and land it on `main`. Every user-visible change needs
   its file in `changelog/updates/`: the release notes come from there.
2. In a clean checkout of `origin/main`:
   - `scripts/release-macos.sh` builds, signs, notarizes and checks. It
     publishes nothing. The files are in `dist/`.
   - `scripts/release-macos.sh --publish` does the same, then pushes the tag
     `vX.Y.Z` and publishes the GitHub release.

The version is `MARKETING_VERSION`. The build number is the git commit count.
A tag is used once: a bad release is fixed by the next version.

A release has three files:

| File | For |
| --- | --- |
| `Septena.dmg` | People. `https://septena.app/mac/download` always gives the newest. |
| `Septena-X.Y.Z.zip` | Sparkle. |
| `appcast.xml` | The update feed. |

## The update feed

Installed copies read `https://septena.app/mac/appcast.xml`. The site redirects
it (`septena-site/public/_redirects`) to `appcast.xml` on the newest GitHub
release. So **the newest release must be a Mac release**: anything else
published in this repo uses `gh release create --latest=false`
(`core-release.yml` does).

Two values are permanent, because every installed copy holds them: the feed
address, and the public update key in `scripts/release-macos.sh`.

## Signing material

Signing runs on the Mac mini. GitHub holds no Developer ID key and no update
key. `~/.config/signing/README.md` lists the files:

| What | Where |
| --- | --- |
| Developer ID Application (team 992N457T8D) | login keychain |
| Provisioning profile `Septena Mac Developer ID` | `centaur-labs/profiles/` |
| Sparkle private key | `centaur-labs/septena-sparkle-ed25519.key` |
| App Store Connect key, for notarization | `centaur-labs/asc-centaur.env` |

The Developer ID certificate expires on 2027-02-01. Only the account holder
can make the next one. Published apps keep running after that date; a new
release needs the new certificate and a profile that names it.

## What the download does not have

- **Sign in with Apple.** Apple never grants that entitlement to Developer ID.
  The app sees that it is missing (`SeptaskSignIn.appleAvailable`) and signs in
  with a code that a signed-in Septena approves (ADR 0016). A person with no
  signed-in device cannot make an account in the download until email codes
  exist (#169).
- **Buying Plus**, until the Mac App Store build.
