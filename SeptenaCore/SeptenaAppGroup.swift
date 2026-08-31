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

  /// Falls back to `.standard` so a build without the entitlement (a bare
  /// clone, a test host) degrades to per-app behavior instead of crashing.
  public static let defaults = UserDefaults(suiteName: suite) ?? .standard

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
