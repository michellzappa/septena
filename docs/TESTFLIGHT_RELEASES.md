# iOS TestFlight release cadence

The iOS, Mac and watchOS build gate continues to run on every push to `main`
and pull request. TestFlight publication is a separate, manual promotion so
testers receive a small number of coherent updates.

## Regular promotions

Plan a release window for Tuesday and Friday.

1. Review the changes on `main` and the TestFlight notes.
2. Confirm the latest `main` commit has a successful run in the **CI** workflow.
   The TestFlight workflow checks the exact commit again before archiving.
3. In GitHub Actions, run **Septena iOS TestFlight** from the `main` ref and
   leave the `branch` input empty. This selects the latest `main` commit for
   the regular external beta build.
4. Follow the workflow through App Store Connect processing and beta review.
   Apple's review can delay when testers can install a build; the release
   windows are targets, not an availability guarantee.

There is no automatic TestFlight upload on a `main` push and no cron release.
The operator starts the regular promotion during the two weekly windows. A
manual promotion outside those windows is fine for an urgent fix.

## Device builds

`device/<name>` builds stay on the separate internal-only path in
[DEVICE_BUILDS.md](DEVICE_BUILDS.md). They are not regular beta releases and do
not go to the external `Public beta` group.
