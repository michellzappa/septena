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
  @Environment(NavigationState.self) private var nav
  @AppStorage(SettingsKey.welcomeCompleted) private var completed = false
  /// Dev override (Settings ▸ About ▸ Advanced) — re-show the welcome on an
  /// established account for testing. Always false in normal use.
  @AppStorage(SettingsKey.welcomeForce) private var force = false

  private var shouldPresent: Bool { force || !completed }

  func body(content: Content) -> some View {
    content
    #if os(macOS)
      .sheet(isPresented: Binding(get: { shouldPresent }, set: { _ in }),
             onDismiss: openFirstLog) {
        WelcomeView()
          .frame(minWidth: 460, idealWidth: 520, minHeight: 600, idealHeight: 680)
      }
    #else
      .fullScreenCover(isPresented: Binding(get: { shouldPresent }, set: { _ in }),
                       onDismiss: openFirstLog) {
        WelcomeView()
      }
    #endif
  }

  /// Fired once the welcome cover is fully gone: if it queued a first-log
  /// section, open the Add Info quick-add for it. Sequencing through
  /// `onDismiss` avoids presenting the quick-add sheet while the cover is
  /// still animating out (which SwiftUI would drop).
  private func openFirstLog() {
    guard let section = nav.pendingFirstLog else { return }
    nav.pendingFirstLog = nil
    nav.addInfoRequestedSection = section
    nav.showAddInfo = true
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
  @Environment(NavigationState.self) private var nav
  @Environment(\.modelContext) private var modelContext

  /// Optional first name for the homepage greeting. Bound straight to the
  /// @AppStorage key `WelcomeHeader` reads, so the greeting personalizes the
  /// moment the welcome dismisses; `start()` also pushes it to the synced
  /// payload so it follows the user across devices.
  @AppStorage(SettingsKey.welcomeName) private var name = ""

  /// Keys the user has chosen to enable. Empty at start — blank slate.
  @State private var selected: Set<String> = []
  /// Remaining picked sections whose plugin has a first-enable onboarding
  /// sheet still to present. Drained one at a time.
  @State private var onboardingQueue: [String] = []
  /// Total length of the onboarding chain at kickoff — drives "Step N of M".
  @State private var chainTotal = 0
  /// The onboarding step currently on screen (drives the chained sheet).
  @State private var currentStep: OnboardingStep?
  /// The final "Set your starting targets" step, presented once the per-section
  /// chain drains (only when the picked sections suggest any goals).
  @State private var showTargets = false
  @State private var targetSuggestions: [SuggestedGoal] = []

  /// `.sheet(item:)` needs an Identifiable; a bare key string isn't.
  private struct OnboardingStep: Identifiable { let id: String }

  // Core vs. optional logging domains, derived from the manifest. Integration
  // sections (`activation == .integration` — Activity, GitHub) are deliberately
  // NOT offered here: they can't connect from the welcome (HealthKit grant /
  // token paste live in the section itself), so picking them would only seed a
  // dead tile. They're introduced later via the dashboard discovery card.
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

  var body: some View {
    NavigationStack {
      Form {
        Section {
          hero.listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }

        Section {
          TextField("Your name", text: $name)
            .textContentType(.givenName)
            #if os(iOS)
            .submitLabel(.done)
            #endif
        } header: {
          Text("What should we call you?")
        } footer: {
          Text("Optional — used to personalize your daily greeting. Change it anytime in Settings.")
        }

        sectionGroup("Core", "The everyday basics. Pick the ones you'll actually use.",
                     coreSections)
        sectionGroup("Track more", "Health, habits, and lifestyle logs.",
                     moreSections)
      }
      .formStyle(.grouped)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .safeAreaInset(edge: .bottom) { bottomBar }
      .sheet(item: $currentStep) { step in
        chainedOnboarding(for: step.id)
          .environment(\.onboardingChain, OnboardingChainContext(
            step: chainTotal - onboardingQueue.count + 1,
            total: chainTotal,
            skipAll: skipRemainingOnboarding))
          .macSheetFrame()
          // The plugin's own Close / primary button is the only exit — it
          // calls `complete()` → `advance()`. Block swipe-to-dismiss so a
          // stray drag can't strand the chain (cover up, nothing presented).
          .interactiveDismissDisabled()
      }
      .sheet(isPresented: $showTargets) {
        OnboardingTargetsView(suggestions: targetSuggestions) {
          showTargets = false
          finish()
        }
        .macSheetFrame()
        .interactiveDismissDisabled()
      }
    }
  }

  // MARK: Pieces

  private var hero: some View {
    VStack(spacing: 12) {
      AppIconPreview(option: .default, size: 72)
        .accessibilityHidden(true)

      Text("Welcome to Septena")
        .font(.septenaWordmark)
        .multilineTextAlignment(.center)

      Text("Every entry is a quiet vote for who you're becoming — private, and yours alone. Choose what you'd like to track; add, rename, or hide sections anytime.")
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
    // Persist the name to the synced payload (the @AppStorage binding already
    // wrote the local mirror the greeting reads). Trim first; empty is fine.
    store.setWelcomeName(name.trimmingCharacters(in: .whitespacesAndNewlines),
                         context: modelContext, engine: ckEngine)

    store.applyWelcomeSelection(enabledKeys: selected,
                                context: modelContext, engine: ckEngine)
    // applyWelcomeSelection auto-assigned accents to the newly enabled
    // sections; repaint the theme cache from the mirror so their tiles show
    // those colors immediately instead of the launch-time gray.
    theme.paintFromCache()
    #if os(iOS)
    // Selected sections' items should appear in Siri / Spotlight now.
    SeptenaShortcuts.updateAppShortcutParameters()
    #endif

    // Queue in catalog order so the chain feels deliberate (core first).
    onboardingQueue = SectionManifest.all
      .map(\.key)
      .filter { selected.contains($0) }
      .filter { SectionRegistry.plugin(forKey: $0)?.onboarding(complete: {}) != nil }
    chainTotal = onboardingQueue.count

    if let first = onboardingQueue.first {
      currentStep = OnboardingStep(id: first)
    } else {
      proceedToTargetsOrFinish()
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
      proceedToTargetsOrFinish()
    }
  }

  /// Once the per-section chain drains, offer the consolidated targets step if
  /// the picked sections suggest any goals; otherwise complete straight away.
  private func proceedToTargetsOrFinish() {
    let suggestions = SuggestedGoal.all(forSections: selected, context: modelContext)
    guard !suggestions.isEmpty else { finish(); return }
    targetSuggestions = suggestions
    showTargets = true
  }

  /// "Skip all" from a chained sheet: abandon the remaining intros and finish.
  /// The picked sections are already enabled (applied in `start`), so skipping
  /// only forgoes their explainers — nothing is lost.
  private func skipRemainingOnboarding() {
    onboardingQueue = []
    currentStep = nil
    finish()
  }

  /// Stamp the onboarding marker (sets the device-local `welcomeCompleted` flag
  /// the gate watches, so the welcome dismisses, and pushes the synced
  /// `onboardedAt`), and queue the first-log quick-add so the gate's `onDismiss`
  /// drops the user straight into logging once the cover is gone.
  private func finish() {
    nav.pendingFirstLog = firstLogSection()
    store.markOnboardingComplete(now: dayClock.now,
                                 context: modelContext, engine: ckEngine)
  }

  /// The section to open the first-log quick-add for: the first picked section
  /// (in catalog order) that the Add Info palette can log. Nil if none of the
  /// picks are quick-add-capable (e.g. only Mood/Body) — then no nudge fires.
  private func firstLogSection() -> AddInfoSection? {
    SectionManifest.all
      .map(\.key)
      .first { selected.contains($0) && AddInfoSection(rawValue: $0) != nil }
      .flatMap(AddInfoSection.init(rawValue:))
  }
}
