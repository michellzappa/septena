import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

// The first run: welcome, account, move in, connect Claude, done. Every step,
// its copy, its icons, its platforms and what each button does come from
// `registry/surfaces.json` (`firstRun`, generated as `RegistryFirstRun`). This
// file renders a step by its `kind` and runs the closed set of button actions
// the registry may name; it holds no copy of its own (ADR 0015).
//
// Whether the first run has happened is the synced `onboardedAt` setting
// (`RegistryFirstRun.completionSetting`), mirrored into the device-local
// `SettingsKey.welcomeCompleted` flag by `SettingsStore`. A second device
// cannot know before it signs in, so it shows Welcome and the account step;
// once sign-in pulls a finished first run or existing tasks, it jumps to the
// "Welcome back" finish.

// MARK: - Gate

@MainActor
enum SeptaskFirstRunGate {
  /// The registry platform name for this device.
  static var platform: String {
    #if os(macOS)
    return "macos"
    #else
    return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
    #endif
  }

  /// True when this device still owes the user a first run: not done here,
  /// not done on another device (as far as this device knows), and the
  /// account has nothing in it. `welcomeForce` (Settings ▸ About ▸ Show
  /// Welcome Again) overrides all of that on this device only.
  static func needsFirstRun(settings: SettingsStore, context: ModelContext) -> Bool {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: SettingsKey.welcomeForce) { return true }
    if defaults.bool(forKey: SettingsKey.welcomeCompleted) { return false }
    if settings.serverSettings?.onboardedAt != nil { return false }
    return !SettingsMirror.accountHasExistingContent(context: context)
  }

  /// Settles the decision once per launch, then sets
  /// `settings.onboardingResolved`. Signed in with an empty local store (a
  /// reinstall keeps the session in the keychain), the answer arrives with
  /// the first pull, so pull before deciding: showing the welcome to a
  /// returning account is the bug `onboardingResolved` exists to prevent.
  static func resolve(settings: SettingsStore) async {
    guard !settings.onboardingResolved else { return }
    let context = LocalStore.shared.container.mainContext
    if needsFirstRun(settings: settings, context: context), TaskSyncEngine.shared.signedIn {
      await TaskSyncEngine.shared.syncNow()
      settings.reloadFromMirror(context: context)
    }
    let engine = SeptenaServices.shared.ckEngine
    settings.reconcileOnboarding(context: context, engine: engine)
    settings.grandfatherOnboardingIfEstablished(now: .now, context: context, engine: engine)
    settings.onboardingResolved = true
  }

  static func shouldPresent(settings: SettingsStore, context: ModelContext) -> Bool {
    settings.onboardingResolved && needsFirstRun(settings: settings, context: context)
  }
}

// MARK: - View

/// The first-run flow. `onFinish` dismisses it; the completion stamp is
/// written before it runs.
struct SeptaskFirstRunView: View {
  var onFinish: () -> Void

  @Environment(SettingsStore.self) private var settings
  @Environment(DayClock.self) private var dayClock
  @Environment(\.modelContext) private var modelContext
  @State private var currentID: String = RegistryFirstRun.steps.first?.id ?? ""
  @State private var history: [String] = []
  /// Sign-in found an account that already finished its first run.
  @State private var returning = false
  @State private var checkingAccount = false
  /// Step ids whose work is done (paired, imported): they show `afterDone`.
  @State private var doneSteps: Set<String> = []
  @State private var copiedAction: String?
  @State private var showingThings = false
  @State private var showingReminders = false
  @State private var taskCountBeforeImport = 0
  private var sync: TaskSyncEngine { .shared }

  private var step: RegistryFirstRunStep? {
    RegistryFirstRun.steps.first { $0.id == currentID }
  }

  var body: some View {
    VStack(spacing: 0) {
      topBar
      ScrollView {
        if let step {
          stepContent(step)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .id(step.id)
            .transition(.opacity)
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      if let step { buttons(for: step) }
    }
    .background(Theme.paperBackground.ignoresSafeArea())
    .onChange(of: sync.signedIn) { _, signedIn in
      if signedIn, step?.kind == "account" { Task { await afterSignIn() } }
    }
    .sheet(isPresented: $showingThings, onDismiss: afterImport) {
      importSheet { ThingsImportView() }
    }
    .sheet(isPresented: $showingReminders, onDismiss: afterImport) {
      importSheet { RemindersInboxDetail() }
    }
    #if os(macOS)
    .frame(minWidth: 520, idealWidth: 560, minHeight: 600, idealHeight: 680)
    #endif
  }

  // MARK: Chrome

  private var topBar: some View {
    HStack {
      if !history.isEmpty, step?.kind != "finish" {
        Button {
          a11yAnimate(.easeInOut(duration: 0.2)) { currentID = history.removeLast() }
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
        .buttonStyle(.borderless)
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
    .frame(minHeight: 44)
  }

  @ViewBuilder
  private func stepContent(_ step: RegistryFirstRunStep) -> some View {
    VStack(spacing: 20) {
      stepIcon(step.icon)
        .frame(width: 64, height: 64)
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      VStack(spacing: 10) {
        Text(title(for: step))
          .font(.largeTitle.bold())
          .multilineTextAlignment(.center)
        let body = body(for: step)
        if !body.isEmpty {
          Text(body)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }
      .frame(maxWidth: .infinity)
      kindContent(step)
    }
  }

  @ViewBuilder
  private func kindContent(_ step: RegistryFirstRunStep) -> some View {
    switch step.kind {
    case "intro":
      VStack(alignment: .leading, spacing: 18) {
        ForEach(step.points, id: \.title) { point in
          HStack(alignment: .top, spacing: 14) {
            Image(systemName: RegistryIcons.sfSymbol(for: point.icon))
              .font(.title2)
              .foregroundStyle(.tint)
              .frame(width: 32)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(point.title).font(.headline)
              Text(point.detail).font(.subheadline).foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 8)
    case "choices":
      VStack(spacing: 10) {
        ForEach(step.choices.filter { $0.platforms.contains(SeptaskFirstRunGate.platform) }) { choice in
          Button { perform(choice.action, in: step) } label: {
            HStack(spacing: 14) {
              Image(systemName: RegistryIcons.sfSymbol(for: choice.icon))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
              VStack(alignment: .leading, spacing: 2) {
                Text(choice.title).font(.headline).foregroundStyle(.primary)
                Text(choice.detail).font(.subheadline).foregroundStyle(.secondary)
                  .multilineTextAlignment(.leading)
              }
              Spacer(minLength: 0)
              Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.top, 8)
    case "connectAgent":
      VStack(alignment: .leading, spacing: 14) {
        ForEach(Array(step.instructions.enumerated()), id: \.offset) { index, line in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index + 1).").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
            Text(line).font(.body)
          }
        }
        if let tertiary = step.tertiary {
          Button(copiedAction == tertiary.action ? "Copied" : tertiary.title) {
            perform(tertiary.action, in: step)
          }
          .buttonStyle(.bordered)
        }
        SeptaskPairingCodeField { doneSteps.insert(step.id) }
          .padding(.top, 4)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 8)
    default:
      EmptyView()
    }
  }

  // MARK: Buttons

  @ViewBuilder
  private func buttons(for step: RegistryFirstRunStep) -> some View {
    VStack(spacing: 10) {
      if step.kind == "account" {
        if checkingAccount {
          ProgressView().controlSize(.regular).frame(height: 50)
        } else {
          SeptaskSignInButton()
            .frame(maxWidth: 400)
        }
      } else if let primary = step.primary {
        Button { perform(primary.action, in: step) } label: {
          Text(copiedAction == primary.action ? "Copied" : primary.title)
            .frame(maxWidth: 400)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
      let secondary = doneSteps.contains(step.id) ? (step.afterDone ?? step.secondary) : step.secondary
      if let secondary {
        Button(secondary.title) { perform(secondary.action, in: step) }
          .buttonStyle(.borderless)
          .controlSize(.large)
          .disabled(checkingAccount)
      }
      if let footnote = step.footnote {
        Text(footnote)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 400)
      }
    }
    .padding(.horizontal, 24)
    .padding(.top, 12)
    .padding(.bottom, 24)
  }

  // MARK: Actions (the closed set `scripts/gen-registries.mjs` allows)

  private func perform(_ action: String, in step: RegistryFirstRunStep) {
    switch action {
    case "next":
      advance(from: step)
    case "finish":
      finish()
    case "signIn":
      // The Apple button starts sign-in itself; `onChange(of: signedIn)`
      // continues the flow.
      break
    case "importThings":
      taskCountBeforeImport = taskCount()
      showingThings = true
    case "importReminders":
      taskCountBeforeImport = taskCount()
      showingReminders = true
    case "copySetupPrompt":
      SeptaskClipboard.copy(RegistryFirstRun.setupPrompt)
      copiedAction = action
    case "copyFirstPrompt":
      SeptaskClipboard.copy(RegistryFirstRun.firstPrompt)
      copiedAction = action
    default:
      break
    }
  }

  /// The next step that applies on this device in the current state.
  private func advance(from step: RegistryFirstRunStep) {
    let steps = RegistryFirstRun.steps
    guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
    let next = steps[(index + 1)...].first(where: applies) ?? steps.last
    guard let next, next.id != step.id else { return }
    if let mark = step.completesGetStartedStep, doneSteps.contains(step.id),
       let id = TaskNoticeStep.ID(rawValue: mark) {
      TaskNotices.completeStep(id, context: modelContext)
    }
    copiedAction = nil
    a11yAnimate(.easeInOut(duration: 0.2)) {
      history.append(step.id)
      currentID = next.id
    }
  }

  private func applies(_ step: RegistryFirstRunStep) -> Bool {
    if step.skipWhen == "signedIn", sync.signedIn { return false }
    if step.requires == "signedIn", !sync.signedIn { return false }
    if step.kind == "choices",
       !step.choices.contains(where: { $0.platforms.contains(SeptaskFirstRunGate.platform) }) {
      return false
    }
    return true
  }

  /// Signed in on the account step: pull, then either carry on, or jump to
  /// the "Welcome back" finish when the account already finished its first
  /// run (on another device) or already holds tasks.
  private func afterSignIn() async {
    guard let step, step.kind == "account" else { return }
    checkingAccount = true
    await sync.syncNow()
    settings.reloadFromMirror(context: modelContext)
    checkingAccount = false
    let finished = settings.serverSettings?.onboardedAt != nil
      || SettingsMirror.accountHasExistingContent(context: modelContext)
    if finished, let last = RegistryFirstRun.steps.last {
      returning = true
      a11yAnimate(.easeInOut(duration: 0.2)) {
        history.append(step.id)
        currentID = last.id
      }
    } else {
      advance(from: step)
    }
  }

  /// Back from an importer: a run that added tasks counts as done.
  private func afterImport() {
    guard let step, step.kind == "choices" else { return }
    if taskCount() > taskCountBeforeImport {
      doneSteps.insert(step.id)
      advance(from: step)
    }
  }

  private func finish() {
    settings.markOnboardingComplete(now: dayClock.now, context: modelContext,
                                    engine: SeptenaServices.shared.ckEngine)
    onFinish()
  }

  // MARK: Helpers

  private func title(for step: RegistryFirstRunStep) -> String {
    returning ? (step.returningTitle ?? step.title) : step.title
  }

  private func body(for step: RegistryFirstRunStep) -> String {
    returning ? (step.returningBody ?? step.body) : step.body
  }

  @ViewBuilder
  private func stepIcon(_ id: String) -> some View {
    if id == "settings.claude" {
      // Claude's mark is an asset, not an SF Symbol (same as Settings).
      Image("ClaudeMark").renderingMode(.template).resizable().scaledToFit()
    } else {
      Image(systemName: RegistryIcons.sfSymbol(for: id)).resizable().scaledToFit()
    }
  }

  private func taskCount() -> Int {
    (try? modelContext.fetchCount(FetchDescriptor<TaskEntity>())) ?? 0
  }

  private func importSheet<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    NavigationStack {
      content()
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              showingThings = false
              showingReminders = false
            }
          }
        }
    }
    #if os(macOS)
    .frame(minWidth: 520, minHeight: 560)
    #endif
  }
}
