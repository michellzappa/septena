import Foundation

/// The App Group Septena and Septask share.
///
/// Both apps are separate processes with separate bundle ids and separate
/// SwiftData mirrors — CloudKit is the convergence point for DATA. This group
/// is for the small amount of DEVICE-LOCAL state the two must agree on, where
/// disagreeing produces a visible defect rather than a difference of opinion
/// (the overdue badge is the first: two apps badging the same overdue tasks
/// reads as twice as many tasks).
///
/// The suite string was previously written out in seven places. New readers use
/// this; the existing literals in `SharedTaskCapture`, `ClaudeGatewayProvider`,
/// the widget snapshot stores, `DayBucket`, and `ThingsImportMapping` should
/// fold in here rather than an eighth copy appearing.
public enum SeptenaAppGroup {
  public static let suite = "group.com.septena.cloud"

  /// Where the shared defaults actually live.
  ///
  /// **macOS does NOT use the group container.** `~/Library/Group Containers/*`
  /// is guarded by the App Data TCC service (`kTCCServiceSystemPolicyAppData`),
  /// and the app-group entitlement only waives that for SANDBOXED apps —
  /// neither Mac app sets `com.apple.security.app-sandbox`. A group-suite
  /// `UserDefaults` read therefore raised "Septask would like to access data
  /// from other apps" on EVERY launch, and the grant never stuck. This is the
  /// same finding that moved the SwiftData store to `~/Library/Application
  /// Support/Septena/` (see `MacStoreLocation`) — that fix moved the store but
  /// left this suite behind, so the prompt came back the moment a correctly
  /// entitled Mac build ran.
  ///
  /// `com.septena.shared` is an ordinary preferences domain in
  /// `~/Library/Preferences/`, guarded by no TCC service, and BOTH Mac apps
  /// read and write it — so the one thing this type exists for (Septena and
  /// Septask agreeing on device-local state) is preserved exactly.
  ///
  /// iOS keeps the real group: its widgets, watch bridge, and share extension
  /// read the suite, and iOS has no App Data prompt.
  ///
  /// The Mac targets also DROP `com.apple.security.application-groups` from
  /// their entitlements, which is what finally stopped the prompt: for a
  /// non-sandboxed app `sandboxd` evaluates that entitlement at exec and asks
  /// TCC for App Data access to the group container whether or not the app
  /// ever reads it — verified in the tccd log, `requesting=/usr/libexec/
  /// sandboxd`, ~20ms after launch and before any file access. Removing every
  /// runtime access (this type, `SharedTaskCapture`, the store move) was
  /// necessary but NOT sufficient. Do not re-add the entitlement to a Mac
  /// target unless that target embeds an extension that needs the container.
  private static var suiteName: String {
    #if os(macOS)
    "com.septena.shared"
    #else
    suite
    #endif
  }

  /// Falls back to `.standard` so a build without the entitlement (a bare
  /// clone, a test host) degrades to per-app behavior instead of crashing.
  public static let defaults = UserDefaults(suiteName: suiteName) ?? .standard

  /// Carry a key's per-app value into the shared group once, the first time a
  /// build that reads the group runs. Without this, flipping a setting on and
  /// then updating would silently reset it to the default.
  ///
  /// Only migrates when the group has NO value yet, so a value already agreed
  /// between the two apps is never overwritten by whichever launches next.
  public static func migrateIfNeeded(key: String) {
    guard defaults !== UserDefaults.standard else { return }
    guard defaults.object(forKey: key) == nil,
          let local = UserDefaults.standard.object(forKey: key) else { return }
    defaults.set(local, forKey: key)
  }
}
