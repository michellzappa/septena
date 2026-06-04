import Foundation

/// Whether the process was launched in demo-seed mode — used by screenshot /
/// UI-test builds. When on, the app runs against a throwaway **in-memory**
/// SwiftData store, **skips CloudKit sync**, and loads curated demo data
/// (`DemoSeed`). Hard-wired OFF in release builds so a stray launch argument
/// can never touch a real user's data or disable their sync.
public enum DemoSeedMode {
  /// Launch with `-SeptenaSeed demo` (the `demo` value is free-form; presence
  /// of the flag is what matters). UI tests set this via `launchArguments`.
  public static var isOn: Bool {
    #if DEBUG
    return CommandLine.arguments.contains("-SeptenaSeed")
    #else
    return false
    #endif
  }
}
