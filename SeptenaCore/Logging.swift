import Foundation

// App-wide logger + a couple of shared error / notification types that
// the rest of the codebase relies on. These used to live in
// `SeptenaClient.swift` alongside the FastAPI proxy; that file has
// been removed now that every backend interaction is either direct
// (OuraProvider / WithingsProvider) or CloudKit-mirrored, so this
// file is the new home for the bits that outlived it.

// MARK: - Change notification

extension Notification.Name {
  /// Posted after task mutations and CloudKit task-sync batches complete.
  static let septenaTasksChanged = Notification.Name("septena.tasksChanged")
  /// Posted after area / project structure changes and CloudKit batches
  /// that update those records. Lets task-centric views avoid reloading
  /// when only navigation structure changed.
  static let septenaStructureChanged = Notification.Name("septena.structureChanged")
  /// Generic mutation broadcast — fires after any non-task mutation (habits,
  /// supplements, chores, gut, nutrition, caffeine, cannabis, groceries).
  /// Destinations that show those sections subscribe to refresh themselves
  /// without each call site wiring its own reload.
  static let septenaDataChanged = Notification.Name("septena.dataChanged")
  /// Posted by the macOS menu bar's "New To-Do" item. ContentView
  /// listens and starts an inline draft on Inbox — same flow as ⌘N.
  static let septenaOpenQuickAdd = Notification.Name("septena.openQuickAdd")
}

// MARK: - Logger

enum SeptenaLog {
  #if DEBUG
  static var enabled = true
  #else
  static var enabled = false
  #endif

  static func info(_ msg: @autoclosure () -> String) {
    guard enabled else { return }
    print("[Septena] \(msg())")
  }

  static func error(_ msg: @autoclosure () -> String, _ error: Error? = nil) {
    guard enabled else { return }
    if let error { print("[Septena] ❌ \(msg()) → \(error.localizedDescription)") }
    else { print("[Septena] ❌ \(msg())") }
  }
}

// MARK: - Errors

/// Shared error type used by OuraProvider / WithingsProvider for HTTP
/// + decoding failures. Pre-dates those providers; lived in
/// SeptenaClient.swift originally.
enum SeptenaError: LocalizedError {
  case server(Int, String)
  case decoding(String)
  case invalidURL

  var errorDescription: String? {
    switch self {
    case .server(let code, let body): return "Server \(code): \(body)"
    case .decoding(let s): return "Decode failed: \(s)"
    case .invalidURL: return "Invalid URL"
    }
  }
}
