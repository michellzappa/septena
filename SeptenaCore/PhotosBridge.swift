import Foundation
import Photos
import SwiftUI

// Mirrors CalendarBridge/RemindersBridge: a tiny wrapper around the
// PhotoKit authorization API so Settings → Integrations can show a state
// row and request access. Photos are used only to attach thumbnails to
// nutrition (meal) entries; the picker itself runs out-of-process, but
// reading the picked asset's `PHAsset` thumbnail needs read access.
@MainActor
@Observable
final class PhotosBridge {
  static let shared = PhotosBridge()

  private init() {}

  enum Access {
    case granted          // .authorized or .limited — we can read assets
    case denied           // .denied or .restricted
    case notDetermined
  }

  var access: Access {
    switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
    case .authorized, .limited: return .granted
    case .denied, .restricted:  return .denied
    case .notDetermined:        return .notDetermined
    @unknown default:           return .denied
    }
  }

  /// True when we can read picked assets' thumbnails. Callers that fetch
  /// `PHAsset` images should guard on this to avoid touching the library
  /// (and crashing) when access isn't available.
  var canRead: Bool { access == .granted }

  @discardableResult
  func requestAccess() async -> Bool {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    switch status {
    case .authorized, .limited: return true
    default:                    return false
    }
  }

  /// Prompt only if the user hasn't decided yet, then report whether reads are
  /// possible. The single entry point callers should use before touching a
  /// picked asset's `itemIdentifier` or thumbnail — so authorization never
  /// gets requested or read straight from `PHPhotoLibrary`, bypassing this
  /// bridge's view of the state.
  @discardableResult
  func ensureAccess() async -> Bool {
    if access == .notDetermined { _ = await requestAccess() }
    return canRead
  }
}
