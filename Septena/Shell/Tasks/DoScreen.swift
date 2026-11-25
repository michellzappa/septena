import SwiftData
import SwiftUI

// The Do screen (docs/DO_SPEC.md §4): one task and nothing else. The window
// root shows it in place of the lists while `DoStore.isFullHere`. The task
// itself is the task page's own form (`TaskComposerCard`, presentation
// `.doing`), so a block has one renderer.

struct DoScreen: View {
  let doing: DoState

  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  @Environment(TaskMutator.self) private var mutator
  @Environment(LogCommitCenter.self) private var logCommit
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @State private var task: SeptenaTask?
  /// Where the user stopped the last time. Read once: it does not change
  /// during this Do.
  @State private var lastNote: String?
  /// The task has no notes, no steps, no earlier note and no conversation.
  @State private var offersFirstStep = false
  /// The first-step line started Discuss here: the conversation shows.
  @State private var discussing = false
  @State private var discussWorking = false
  #if os(iOS)
  @State private var keyboardVisible = false
  #endif

  /// A readable column on iPad.
  private static let columnWidth: CGFloat = 680

  private var accent: Color { theme.color(for: "tasks") }

  /// The time and the exits stay in reach at the bottom. They scroll with the
  /// page when the text is too large for a fixed bar, and they leave while the
  /// software keyboard is up.
  private var pinsControls: Bool {
    guard !dynamicTypeSize.isAccessibilitySize else { return false }
    #if os(iOS)
    return !keyboardVisible
    #else
    return true
    #endif
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          lastTime
          if let task {
            TaskComposerCard(
              mode: .edit(task),
              areas: [],
              projects: [],
              accent: accent,
              presentation: .doing,
              onDone: { reload() }
            )
          }
          firstStep
          if discussing, let task {
            ConversationSection(task: task, accent: accent)
              .padding(.horizontal, 16)
          }
          if dynamicTypeSize.isAccessibilitySize { controls }
        }
        .frame(maxWidth: Self.columnWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
      }
      .scrollDismissesKeyboard(.interactively)
      .background(Theme.paperBackground.ignoresSafeArea())
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if pinsControls { controls.frame(maxWidth: .infinity).background(.bar) }
      }
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button { DoStore.shared.showList() } label: {
            DoActionLabel(.doShowList).labelStyle(.titleAndIcon)
          }
          .keyboardShortcut(.cancelAction) // Esc
        }
        ToolbarItem(placement: .primaryAction) {
          Button { nav.presentAddInfo() } label: { DoActionLabel(.appQuickAdd) }
        }
      }
    }
    .onAppear(perform: start)
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in reload() }
    .onReceive(NotificationCenter.default.publisher(for: DoStore.plannedEndReached)) { _ in
      Haptics.success()
    }
    #if os(iOS)
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
      keyboardVisible = true
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
      keyboardVisible = false
    }
    #endif
    .modifier(DoScreenRoutes())
  }

  // MARK: Parts

  @ViewBuilder
  private var lastTime: some View {
    if let lastNote {
      VStack(alignment: .leading, spacing: 4) {
        Text(RegistryDoing.lastTimeTitle)
          .font(.septenaLabel)
          .foregroundStyle(Theme.inkSecondary)
        Text(lastNote)
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 16)
      .accessibilityElement(children: .combine)
    }
  }

  @ViewBuilder
  private var firstStep: some View {
    if offersFirstStep, !discussing {
      Button(action: startDiscuss) {
        HStack(spacing: Theme.iconTextGap) {
          Image(systemName: RegistrySurfaces.taskAttribute(.discuss).sfSymbol)
            .accessibilityHidden(true)
          Text(RegistryDoing.firstStepTitle)
          if discussWorking { ProgressView().controlSize(.small) }
        }
        .font(.septenaTaskTitle)
        .contentShape(Rectangle())
      }
      .buttonStyle(.bordered)
      .disabled(discussWorking)
      .padding(.horizontal, 16)
    }
  }

  private var controls: some View {
    VStack(spacing: 12) {
      DoTimeControl(doing: doing, ownMinutes: task?.durationMinutes)
      // Side by side while the words fit, else one under the other.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { exits }
        VStack(spacing: 10) { exits }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: Self.columnWidth)
  }

  @ViewBuilder
  private var exits: some View {
    Button(action: done) { exitLabel(.doDone) }
      .buttonStyle(.borderedProminent)
    Button { DoFlow.stop(doing, nav: nav) } label: { exitLabel(.doStop) }
      .buttonStyle(.bordered)
    Button { DoFlow.openLater(doing, nav: nav) } label: { exitLabel(.doLater) }
      .buttonStyle(.bordered)
  }

  private func exitLabel(_ id: RegistryActionID) -> some View {
    Text(RegistryActions.title(id))
      .lineLimit(1)
      // Keeps its width, so `ViewThatFits` stacks the exits and never cuts one.
      .fixedSize()
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity)
  }

  // MARK: Actions

  private func done() {
    nav.doExitSince = doing.startedAt
    DoFlow.complete(doing, mutator: mutator, accent: accent,
                    logCommit: logCommit, context: modelContext)
    DoFlow.offerNeedsYou(nav: nav, context: modelContext)
  }

  private func startDiscuss() {
    guard let task, !discussWorking else { return }
    Haptics.press()
    discussWorking = true
    Task {
      _ = await ConversationEngine.advance(task: task)
      discussWorking = false
      reload()
      discussing = mutator.conversation(id: doing.taskID)?.hasStarted == true
    }
  }

  // MARK: Load

  private func start() {
    // The list's own page and selection state left with the list.
    nav.isTaskEditorOpen = false
    nav.isTaskMultiSelectActive = false
    lastNote = DoStore.shared.lastNote(taskID: doing.taskID)
    reload()
  }

  private func reload() {
    guard let fresh = LocalCache.liveTasks(ids: [doing.taskID], in: modelContext).first else { return }
    if fresh != task { task = fresh }
    offersFirstStep = OnDeviceAI.isAvailable
      && lastNote == nil
      && (fresh.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !fresh.conversation.hasStarted
      && LocalCache.checklistItems(forTaskID: doing.taskID, in: modelContext).isEmpty
  }
}

/// The time of the Do. A tap sets the length. Whole minutes, and one color:
/// past the planned end it counts on (docs/DO_SPEC.md §4).
private struct DoTimeControl: View {
  let doing: DoState
  /// The task's own duration, offered with the registry's lengths.
  let ownMinutes: Int?

  private var lengths: [Int] {
    var all = Set(RegistryDoing.lengths)
    if let ownMinutes, (1...RegistryEntityLimits.doPlannedMinutesMax).contains(ownMinutes) {
      all.insert(ownMinutes)
    }
    // A length set on another device stays in the list, so it shows as chosen.
    if let planned = doing.plannedMinutes { all.insert(planned) }
    return all.sorted()
  }

  private var length: Binding<Int?> {
    Binding(get: { doing.plannedMinutes }, set: { minutes in
      Haptics.selection()
      DoStore.shared.setLength(sessionID: doing.sessionID, minutes: minutes)
      if minutes != nil { Task { await DoEndAlert.requestAccess() } }
    })
  }

  var body: some View {
    Menu {
      Picker(RegistryDoing.lengthTitle, selection: length) {
        Text(RegistryDoing.noLengthTitle).tag(Int?.none)
        ForEach(lengths, id: \.self) { minutes in
          Text(RegistryDoing.lengthOption(count: minutes)).tag(Int?.some(minutes))
        }
      }
    } label: {
      TimelineView(.periodic(from: doing.startedAt, by: 60)) { timeline in
        Text(verbatim: doing.timeText(at: timeline.date))
          .font(.septenaSectionTitle)
          .monospacedDigit()
          .foregroundStyle(Theme.inkPrimary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 4)
          .contentShape(Rectangle())
      }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .accessibilityHint(Text(RegistryDoing.lengthTitle))
  }
}

/// What the rest of the app asks for while the Do screen is up. New Task is
/// Quick Add here, because there is no list to type in. A route from outside
/// (a notification, a widget, Quick Find) shows the list it names: that leaves
/// the screen, not the Do.
private struct DoScreenRoutes: ViewModifier {
  @Environment(NavigationState.self) private var nav

  func body(content: Content) -> some View {
    content
      .onChange(of: nav.shouldStartCreating) { _, want in
        guard want else { return }
        nav.shouldStartCreating = false
        nav.presentAddInfo()
      }
      .onChange(of: nav.path) { _, _ in DoStore.shared.showList() }
      .onChange(of: nav.pendingTaskReveal) { _, reveal in
        if reveal != nil { DoStore.shared.showList() }
      }
      .onChange(of: nav.shouldCreateProject) { _, want in
        guard want else { return }
        nav.shouldCreateProject = false
        DoStore.shared.showList()
      }
      .onChange(of: nav.shouldCreateArea) { _, want in
        guard want else { return }
        nav.shouldCreateArea = false
        DoStore.shared.showList()
      }
  }
}
