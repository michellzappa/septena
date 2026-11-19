import SwiftUI

/// Septask's one-time welcome (docs/SEPTASK.md P3): Septena's welcome design
/// language, Septask's own copy. No section picker, no life-OS framing, and
/// no mandatory task onboarding after it — the app lands straight in tasks.
/// Completion is tracked app-locally (a Septena user installing Septask still
/// sees this once, and resetting it here never touches Septena's welcome).
enum SeptaskWelcome {
  static let completedKey = "septask.welcome.completed"
}

extension View {
  /// First-run gate. Self-gating: a no-op once completed.
  func septaskWelcomeGate() -> some View {
    modifier(SeptaskWelcomeGate())
  }
}

private struct SeptaskWelcomeGate: ViewModifier {
  @AppStorage(SeptaskWelcome.completedKey) private var completed = false

  private var presented: Binding<Bool> {
    // Demo-seed (screenshot) launches land straight in tasks — the welcome
    // would otherwise cover a fresh simulator and block every capture.
    Binding(get: { !completed && !DemoSeedMode.isOn }, set: { if !$0 { completed = true } })
  }

  func body(content: Content) -> some View {
    #if os(macOS)
    content.sheet(isPresented: presented) {
      SeptaskWelcomeView()
        .macSheetFrame(width: 520, height: 620)
        .interactiveDismissDisabled()
    }
    #else
    content.fullScreenCover(isPresented: presented) {
      SeptaskWelcomeView()
    }
    #endif
  }
}

/// Internal, not private: the macOS AppKit shell hosts this same view in a
/// sheet (`SeptaskKitWelcome`) because the SwiftUI window it used to ride no
/// longer opens at launch. One welcome, two presenters — never a second copy.
struct SeptaskWelcomeView: View {
  @AppStorage(SeptaskWelcome.completedKey) private var completed = false

  /// Called after `completed` flips, so an AppKit host can end its sheet.
  /// `nil` for the SwiftUI gate, whose binding closes on the same flag.
  private let onComplete: (() -> Void)?

  /// Explicit init: the memberwise one is `private` (its stored properties
  /// are), so another file could not construct this view without it.
  init(onComplete: (() -> Void)? = nil) {
    self.onComplete = onComplete
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 28) {
          hero
          VStack(spacing: 20) {
            feature(icon: "tray",
                    title: "Your day, your call",
                    detail: "New tasks wait in the Inbox. Nothing lands on Today until you put it there.")
            feature(icon: "brain.head.profile",
                    title: "AI that asks first",
                    detail: "Stuck on a task? Septena asks a quick question and suggests the next step. Keep it on your device, or connect Claude to work your list together.")
            feature(icon: "lock",
                    title: "Yours to keep",
                    detail: "No ads, and we never sell your data. The code is open source, so you can read how your tasks are handled.")
          }
          .padding(.horizontal, 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 48)
        .padding(.bottom, 24)
      }
      bottomBar
    }
  }

  private var hero: some View {
    VStack(spacing: 14) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 56))
        .foregroundStyle(Color.accentColor)
      Text("Welcome to Septena")
        .font(.largeTitle.weight(.bold))
        .multilineTextAlignment(.center)
      Text("A task app that thinks with you, and asks before it acts.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
  }

  private func feature(icon: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(Color.accentColor)
        .frame(width: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
  }

  private var bottomBar: some View {
    VStack(spacing: 0) {
      Divider()
      signInRow
      Button {
        completed = true
        onComplete?()
      } label: {
        Text("Get Started")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
      }
      .buttonStyle(.borderedProminent)
      .tint(AdaptiveColor.fillForWhiteInk(Color.accentColor))
      .padding(20)
    }
  }

  /// Septask syncs through its own server, so the welcome asks for the one
  /// sign-in it needs. Skipping is allowed: tasks stay on this device and
  /// Today keeps asking (`SeptaskSignInNotice`).
  @ViewBuilder
  private var signInRow: some View {
    if !TaskSyncEngine.shared.signedIn {
      VStack(spacing: 8) {
        Text("Sign in with Apple to sync your tasks across your devices.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        SeptaskSignInButton()
      }
      .padding(.horizontal, 20)
      .padding(.top, 20)
    }
  }
}
