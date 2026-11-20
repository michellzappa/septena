import Foundation

/// The name a user sees for the app this process is (ADR 0007).
///
/// Shared files compile into both apps: the task app is "Septena" and the
/// life OS is "Septena Life". A sentence in a shared file that names the app
/// interpolates `AppDisplayName.current` so each app says its own name. A
/// sentence in a file that only one app compiles writes the name out.
///
/// It names the app, not the brand: "Septena+", "Support Septena", a
/// "Septena server" and the "Septena export" format keep the brand name.
public enum AppDisplayName {
  #if SEPTASK
  public static let current = "Septena"
  #else
  public static let current = "Septena Life"
  #endif
}
