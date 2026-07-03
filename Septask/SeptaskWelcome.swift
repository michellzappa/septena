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

private struct SeptaskWelcomeView: View {
  @Environment(SectionTheme.self) private var theme
  @AppStorage(SeptaskWelcome.completedKey) private var completed = false

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 28) {
          hero
          VStack(spacing: 20) {
            feature(icon: "lock",
                    title: "Private by design",
                    detail: "Your tasks live in your iCloud, synced by CloudKit. No accounts, no servers of ours, readable by no one else.")
            feature(icon: "arrow.triangle.2.circlepath",
                    title: "One dataset, two apps",
                    detail: "Runs side by side with Septena over the same tasks, areas, and projects — edits in one appear in the other.")
            feature(icon: "brain.head.profile",
                    title: "AI on your terms",
                    detail: "Connect your own Claude or use Apple's on-device intelligence. You set how far AI may reach — including not at all.")
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
        .foregroundStyle(theme.color(for: "tasks"))
      Text("Welcome to Septask")
        .font(.largeTitle.weight(.bold))
        .multilineTextAlignment(.center)
      Text("A focused, private task manager — calm lists, careful keyboarding, and an AI that answers to you.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
  }

  private func feature(icon: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(theme.color(for: "tasks"))
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
      Button {
        completed = true
      } label: {
        Text("Get Started")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
      }
      .buttonStyle(.borderedProminent)
      .tint(theme.color(for: "tasks"))
      .padding(20)
    }
  }
}
