import SwiftUI
import SwiftData

// First-run welcome. Shown once, over the dashboard, on a brand-new account
// (and never again once the synced `onboardedAt` marker exists — see
// `WelcomeGate` and `SettingsStore.reconcileOnboarding`).
//
// The screen is a blank-slate section picker: nothing is pre-selected, the
// user must enable at least one section to continue. On Continue we apply the
// selection to the synced `SectionEntity` rows (enable picked, disable the
// rest — never deletes data) and then chain into each picked section's own
// first-enable onboarding sheet, the same flow Settings runs when a section is
// toggled on. When the chain drains, we stamp the onboarding marker and the
// gate dismisses.
//
// Why a blank slate rather than the manifest's `defaultEnabled` six: the
// product intent is an intentional first run — the user chooses what their
// "life operating system" tracks instead of inheriting a fixed default set
// and trimming it. `SeptenaServices.start()` still seeds the default-enabled
// rows; this screen simply overrides them with the user's choices.

// MARK: - Gate

/// Decides whether to present `WelcomeView` over the app's root. Gated purely
/// on the device-local `welcomeCompleted` flag so the welcome appears on the
/// very first frame of a fresh install — no waiting on the network, nothing
/// else shown first. Established accounts never reach here: `SettingsStore`
/// sets the flag synchronously at launch when the local store already has the
/// user's data (`adoptWelcomeFlagIfEstablished`), and a returning user's brand
/// new device adopts the synced `onboardedAt` once it syncs in, dismissing the
/// welcome (the rare pre-sync flash on that path is acceptable).
private struct WelcomeGate: ViewModifier {
  @AppStorage(SettingsKey.welcomeCompleted) private var completed = false

  private var shouldPresent: Bool { !completed }

  func body(content: Content) -> some View {
    content
    #if os(macOS)
      .sheet(isPresented: Binding(get: { shouldPresent }, set: { _ in })) {
        WelcomeView()
          .frame(minWidth: 460, idealWidth: 520, minHeight: 600, idealHeight: 680)
      }
    #else
      .fullScreenCover(isPresented: Binding(get: { shouldPresent }, set: { _ in })) {
        WelcomeView()
      }
    #endif
  }
}

extension View {
  /// Present the first-run welcome over this view when the account hasn't
  /// been onboarded yet. Attach inside the environment chain so the gate can
  /// read `SettingsStore`.
  func welcomeGate() -> some View { modifier(WelcomeGate()) }
}

// MARK: - Welcome

struct WelcomeView: View {
  @Environment(SettingsStore.self) private var store
  @Environment(SectionTheme.self) private var theme
  @Environment(CKEngine.self) private var ckEngine
  @Environment(DayClock.self) private var dayClock
  @Environment(\.modelContext) private var modelContext

  /// Keys the user has chosen to enable. Empty at start — blank slate.
  @State private var selected: Set<String> = []
  /// Remaining picked sections whose plugin has a first-enable onboarding
  /// sheet still to present. Drained one at a time.
  @State private var onboardingQueue: [String] = []
  /// The onboarding step currently on screen (drives the chained sheet).
  @State private var currentStep: OnboardingStep?

  /// `.sheet(item:)` needs an Identifiable; a bare key string isn't.
  private struct OnboardingStep: Identifiable { let id: String }

  // Catalog split into the same three buckets the manifest's activation /
  // onboarding fields already encode — derived, not hand-maintained.
  private var coreSections: [SectionManifest] {
    SectionManifest.all.filter {
      $0.kind == .loggingDomain && $0.onboarding == .core
    }
  }
  private var moreSections: [SectionManifest] {
    SectionManifest.all.filter {
      $0.kind == .loggingDomain && $0.activation == .optional && $0.onboarding == .optional
    }
  }
  private var integrationSections: [SectionManifest] {
    SectionManifest.all.filter {
      $0.kind == .loggingDomain && $0.activation == .integration
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          hero.listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }

        sectionGroup("Core", "The everyday basics. Pick the ones you'll actually use.",
                     coreSections)
        sectionGroup("Track more", "Health, habits, and lifestyle logs.",
                     moreSections)
        sectionGroup("Connect", "Pull in data from apps you already use.",
                     integrationSections)
      }
      .formStyle(.grouped)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .safeAreaInset(edge: .bottom) { bottomBar }
      .sheet(item: $currentStep) { step in
        chainedOnboarding(for: step.id)
          .macSheetFrame()
          // The plugin's own Close / primary button is the only exit — it
          // calls `complete()` → `advance()`. Block swipe-to-dismiss so a
          // stray drag can't strand the chain (cover up, nothing presented).
          .interactiveDismissDisabled()
      }
    }
  }

  // MARK: Pieces

  private var hero: some View {
    VStack(spacing: 12) {
      ZStack {
        Circle()
          .fill(Color.accentColor.opacity(0.15))
          .frame(width: 76, height: 76)
        Image("Discs")
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
          .frame(width: 40, height: 40)
          .foregroundStyle(Color.accentColor)
      }
      .accessibilityHidden(true)

      Text("Welcome to Septena")
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)

      Text("One private place for every part of your life. Choose what you'd like to track — you can add, rename, or hide sections anytime in Settings.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private func sectionGroup(_ title: LocalizedStringKey, _ footer: LocalizedStringKey,
                            _ manifests: [SectionManifest]) -> some View {
    if !manifests.isEmpty {
      Section {
        ForEach(manifests) { manifest in
          row(for: manifest)
        }
      } header: {
        Text(title)
      } footer: {
        Text(footer)
      }
    }
  }

  private func row(for manifest: SectionManifest) -> some View {
    let isOn = selected.contains(manifest.key)
    let accent = theme.color(for: manifest.key)
    return Button {
      if isOn { selected.remove(manifest.key) } else { selected.insert(manifest.key) }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: manifest.iconSymbol)
          .font(.title3)
          .foregroundStyle(accent)
          .frame(width: 28, alignment: .center)
        VStack(alignment: .leading, spacing: 2) {
          Text(manifest.defaultLabel)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
          Text(manifest.shortDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(isOn ? accent : Color.secondary.opacity(0.4))
      }
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
  }

  private var bottomBar: some View {
    VStack(spacing: 6) {
      Button(action: start) {
        Text(selected.isEmpty ? "Choose at least one"
             : "Continue with \(selected.count) section\(selected.count == 1 ? "" : "s")")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(selected.isEmpty)
    }
    .padding()
    .background(.bar)
  }

  /// The picked section's first-enable onboarding view, presented as the next
  /// step in the chain. Falls back to nothing (chain advances) if the plugin
  /// has no onboarding — but the queue only ever holds keys that do.
  @ViewBuilder
  private func chainedOnboarding(for key: String) -> some View {
    if let plugin = SectionRegistry.plugin(forKey: key),
       let view = plugin.onboarding(complete: { advance() }) {
      view
    } else {
      // Defensive: shouldn't happen (queue is pre-filtered). Advance on appear.
      Color.clear.onAppear { advance() }
    }
  }

  // MARK: Flow

  /// Apply the selection to the synced section rows, then kick off the chain
  /// of per-section onboarding sheets (if any). If nothing picked has an
  /// onboarding flow, finish immediately.
  private func start() {
    store.applyWelcomeSelection(enabledKeys: selected,
                                context: modelContext, engine: ckEngine)
    #if os(iOS)
    // Selected sections' items should appear in Siri / Spotlight now.
    SeptenaShortcuts.updateAppShortcutParameters()
    #endif

    // Queue in catalog order so the chain feels deliberate (core first).
    onboardingQueue = SectionManifest.all
      .map(\.key)
      .filter { selected.contains($0) }
      .filter { SectionRegistry.plugin(forKey: $0)?.onboarding(complete: {}) != nil }

    if let first = onboardingQueue.first {
      currentStep = OnboardingStep(id: first)
    } else {
      finish()
    }
  }

  /// Advance the onboarding chain: dismiss the current step, present the next,
  /// or finish when the queue drains.
  private func advance() {
    if !onboardingQueue.isEmpty { onboardingQueue.removeFirst() }
    if let next = onboardingQueue.first {
      currentStep = OnboardingStep(id: next)
    } else {
      currentStep = nil
      finish()
    }
  }

  /// Stamp the onboarding marker. Sets the device-local `welcomeCompleted`
  /// flag the gate watches, so the welcome dismisses; pushes the synced
  /// `onboardedAt` so the user's other devices skip it too.
  private func finish() {
    store.markOnboardingComplete(now: dayClock.now,
                                 context: modelContext, engine: ckEngine)
  }
}
