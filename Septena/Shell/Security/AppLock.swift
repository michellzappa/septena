// AppLock — whole-app privacy gate (Face ID / Touch ID / device passcode).
//
// Septena holds intimate logs (mood, gut, intake, nutrition, health). The
// device passcode already protects a *locked, lost* phone; this gate closes
// the other hole: a handed-over, already-unlocked device. It is a device-side
// privacy lens — it does NOT add at-rest encryption beyond what iOS Data
// Protection already gives the SwiftData store and CloudKit data.
//
// Mechanism: LocalAuthentication's `.deviceOwnerAuthentication` policy, which
// tries biometrics first and falls back to the device passcode automatically.
// We never hold a PIN ourselves — the OS owns the secret.
//
// State lives here; App.swift drives it from `scenePhase` and paints the
// `AppLockCover` overlay. Settings (Privacy pane) flips the two UserDefaults
// keys this reads. The lock is intentionally per-device (local @AppStorage),
// not synced account data — each device opts in independently.

import SwiftUI
import LocalAuthentication

@MainActor
@Observable
final class AppLock {
  enum Phase {
    case unlocked
    case locked          // needs auth; cover shown with a retry button
    case authenticating  // system biometric/passcode sheet is up
  }

  private(set) var phase: Phase = .unlocked
  /// True whenever the app content should be hidden behind the cover — both
  /// while locked and while merely backgrounded (so the app-switcher snapshot
  /// is blurred even within the grace window).
  private(set) var covering = false

  /// Wall-clock instant the app last left the foreground. Real `Date()` on
  /// purpose — the grace timer must not be affected by DayClock time-travel.
  private var backgroundedAt: Date?

  init() {
    // Cold launch: if the lock is on, come up covered and locked so the very
    // first frame never flashes content before authentication.
    if Self.enabled {
      phase = .locked
      covering = true
    }
  }

  // MARK: Scene-phase driving

  /// Called from the app scene's `onChange(of: scenePhase)`.
  func handle(scenePhase: ScenePhase) {
    guard Self.enabled else {
      // Toggled off (or never on): make sure we're never stuck covered.
      phase = .unlocked
      covering = false
      backgroundedAt = nil
      return
    }
    switch scenePhase {
    case .active:
      becameActive()
    case .inactive:
      // iOS snapshots the screen for the app switcher during `.inactive`, so
      // cover here to keep that thumbnail private. On macOS `.inactive` fires
      // whenever the window isn't frontmost, which would blur the window any
      // time you glance at it behind another app — so only cover on full
      // `.background` there.
      #if os(iOS)
      becameBackground()
      #endif
    case .background:
      becameBackground()
    @unknown default:
      break
    }
  }

  /// Re-trigger authentication after a launch or after the user cancelled.
  func authenticate() {
    guard Self.enabled else {
      phase = .unlocked
      covering = false
      return
    }
    guard phase != .authenticating else { return }

    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      // No biometrics and no passcode configured → nothing to evaluate
      // against. Fail open rather than brick the app.
      phase = .unlocked
      covering = false
      backgroundedAt = nil
      return
    }

    phase = .authenticating
    context.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "Unlock Septena") { success, _ in
      Task { @MainActor in
        if success {
          self.phase = .unlocked
          self.covering = false
          self.backgroundedAt = nil
        } else {
          // Cancelled / failed. Stay covered; the cover offers a retry button.
          self.phase = .locked
        }
      }
    }
  }

  private func becameBackground() {
    // Already locked or mid-auth → the cover is up and the timer doesn't
    // matter; don't reset it (the biometric sheet itself fires `.inactive`).
    guard phase == .unlocked else { return }
    // ASWebAuthenticationSession (Claude reconnect) also takes the scene
    // inactive while its sheet is up. Treating that as a real background
    // covers the app and — with "Lock after: Immediately" — re-arms Face ID
    // on top of the Apple sheet, which races the session and can leave its
    // completion never firing (`isRefreshing` stuck until restart).
    if ClaudeGatewayProvider.shared.isPresentingWebAuth { return }
    covering = true
    backgroundedAt = Date()
  }

  private func becameActive() {
    switch phase {
    case .locked:
      authenticate()
    case .authenticating:
      break // focus returning from the system sheet; await its callback
    case .unlocked:
      // Still inside an ASWebAuthenticationSession presentation — the scene
      // can flicker active/inactive around the sheet. Don't consume a stale
      // backgroundedAt or re-cover.
      if ClaudeGatewayProvider.shared.isPresentingWebAuth {
        backgroundedAt = nil
        covering = false
        return
      }
      guard let since = backgroundedAt else {
        covering = false
        return
      }
      backgroundedAt = nil
      if Date().timeIntervalSince(since) >= Self.graceSeconds {
        phase = .locked
        authenticate()
      } else {
        covering = false // back within the grace window — no prompt
      }
    }
  }

  // MARK: Settings-backed config

  static var enabled: Bool {
    UserDefaults.standard.bool(forKey: SettingsKey.appLockEnabled)
  }

  /// Seconds the app may sit backgrounded before the lock re-arms. Absent key
  /// means the feature default (60s), not 0 — `integer(forKey:)` alone would
  /// read absent as "immediately".
  static var graceSeconds: TimeInterval {
    let ud = UserDefaults.standard
    guard ud.object(forKey: SettingsKey.appLockGraceSeconds) != nil else { return 60 }
    return TimeInterval(ud.integer(forKey: SettingsKey.appLockGraceSeconds))
  }

  // MARK: Capability / labels (for Settings copy)

  /// Whether the device can evaluate the owner-authentication policy at all
  /// (some biometric or a passcode is enrolled).
  static var isAvailable: Bool {
    LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
  }

  /// "Face ID" / "Touch ID" / "Optic ID", or a generic fallback.
  static var biometryLabel: String {
    let context = LAContext()
    _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) // populates biometryType
    switch context.biometryType {
    case .faceID:  return "Face ID"
    case .touchID: return "Touch ID"
    case .opticID: return "Optic ID"
    default:       return "biometrics"
    }
  }

  /// SF Symbol matching the device's enrolled biometry — `faceid` / `touchid` /
  /// `opticid`, or a neutral lock when none is enrolled. Lets surfaces frame an
  /// auth checkpoint as "verify it's you" rather than an error.
  static var biometrySymbolName: String { BiometrySymbol.systemName }

  /// Toggle label, e.g. "Require Face ID" — or "Require passcode" when no
  /// biometry is enrolled.
  static var requireActionLabel: String {
    let context = LAContext()
    _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    switch context.biometryType {
    case .faceID, .touchID, .opticID: return "Require \(biometryLabel)"
    default:                          return "Require passcode"
    }
  }
}

// MARK: - Cover

/// Full-bleed privacy cover painted over the root while the app is locked or
/// backgrounded. Blocks interaction with the content behind it and offers a
/// retry button once a biometric attempt has been cancelled.
struct AppLockCover: View {
  @Environment(AppLock.self) private var lock

  var body: some View {
    if lock.covering {
      ZStack {
        Rectangle()
          .fill(.ultraThinMaterial)
          .ignoresSafeArea()

        VStack(spacing: 18) {
          Image(systemName: "lock.fill")
            .font(.system(size: 44, weight: .regular))
            .foregroundStyle(.secondary)
          Text("Septena is locked")
            .font(.headline)
            .foregroundStyle(.secondary)
          if lock.phase == .locked {
            Button {
              lock.authenticate()
            } label: {
              Label("Unlock", systemImage: AppLock.biometrySymbolName)
                .font(.body.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
          }
        }
        .padding()
      }
      // Intercept all hits so nothing behind the cover is tappable.
      .contentShape(Rectangle())
      .transition(.opacity)
      .a11yAnimation(.easeInOut(duration: 0.18), value: lock.phase)
    }
  }
}
