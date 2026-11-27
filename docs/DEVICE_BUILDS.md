# Device builds: a branch on mz's phone, with no Mac

Any machine that can push a branch can put it on mz's iPhone. No Mac is
involved: GitHub builds and signs, TestFlight delivers.

1. Push the work to `device/<name>`:
   `git push -f origin HEAD:device/<name>`
2. mz approves the run (GitHub app or the run page). Nothing is signed before.
3. The build arrives in TestFlight for the internal group **Device builds**.
   "What to Test" names the branch.
4. Delete the branch when done: `git push origin --delete device/<name>`.

A manual run works too: Actions, Septena iOS TestFlight, `branch`.

## What it guarantees

- A device build never reaches **Public beta** and never goes to beta review.
  `scripts/testflight-distribute.mjs` refuses a device build when the group is
  not internal.
- The workflow that signs is always the copy on `main` (`workflow_run`). A
  branch cannot change it.
- It runs the branch's own build scripts next to the signing key. That is why
  the environment `apple-device` asks mz first. Read the diff before approving.
- Device builds use the version `<major>.999.<n>`, so they never collide with a
  build from `main`. TestFlight shows them as newer. To go back, pick the
  normal version under Previous Builds.

## One-time setup

| What | Where |
| --- | --- |
| Environment `apple-release`: deploys from `main` only | GitHub |
| Environment `apple-device`: deploys from `main` only, mz approves | GitHub |
| Environment `cloudflare-deploy`: deploys from `main` only | GitHub |
| Ruleset `main: require PR (block deploy keys)`: Admin-only bypass | GitHub |
| Internal group "Device builds" with only mz in it | App Store Connect |

## Before another machine gets push access

A branch push can run its own workflow file, and a workflow on any branch can
read **repository** secrets. Move every secret that matters to an environment
limited to `main` first, and delete the repository copy. Then block that
machine's key from `main` with a ruleset. Without both, push access to a branch
equals the signing key and the deploy token.

## Other platforms

- Android: `android.yml` builds the APK on a pull request.
- Mac: `scripts/release-macos.sh` on the mini, when mz says release.
- Watch: off while `WATCH_EMBED_DISABLED` is set in `project.yml`.
