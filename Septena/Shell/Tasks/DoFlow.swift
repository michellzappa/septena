import SwiftData
import SwiftUI

// The gestures of Do (docs/DO_SPEC.md) that the Do screen and the notice
// share: start, the exits and what follows an exit. `DoStore` owns the
// session. This file owns what the task and the window do at the gesture:
// undo, haptics, and the sheets (Later, "Where did you stop?", "N things need
// you"). The sheets hang off the window root, so they stay when an exit takes
// the Do screen away.

/// A sheet of the Do flow, one at a time per window (`NavigationState.doSheet`).
enum DoSheet: Identifiable, Equatable {
  case later(DoState)
  case stopNote(sessionID: String)
  case needsYou(count: Int)

  var id: String {
    switch self {
    case .later(let doing): return "later.\(doing.sessionID)"
    case .stopNote(let sessionID): return "stopNote.\(sessionID)"
    case .needsYou: return "needsYou"
    }
  }
}

@MainActor
enum DoFlow {
  /// False where the capability is planned: no Do screen and no notice there.
  static var isAvailable: Bool { RegistryActions.isAvailableOnPlatform(.taskDo) }

  /// `task.do` acts on one open task. Headings and closed tasks cannot be done.
  static func canDo(_ task: SeptenaTask) -> Bool {
    isAvailable && task.status == .open && !task.isHeading && task.deletedAt == nil
  }

  /// Starts a Do, or shows the one this task already has. No dialog when
  /// another Do is open: it ends as replaced.
  static func begin(_ taskID: String) {
    Haptics.press()
    DoStore.shared.begin(taskID: taskID)
  }

  // MARK: Exits

  /// Done: the same write, undo entry and completion feel as a row's checkbox.
  static func complete(_ doing: DoState, mutator: TaskMutator, accent: Color,
                       logCommit: LogCommitCenter?, context: ModelContext) {
    let task = LocalCache.liveTasks(ids: [doing.taskID], in: context).first
    TaskCelebration.completed(isToday: task?.isOnToday == true, clearedToday: false,
                              accent: accent, logCommit: logCommit)
    mutator.complete(id: doing.taskID)
    TaskUndo.recordCompletion(ids: [doing.taskID], wasDone: false, mutator: mutator)
    mutator.acknowledge(id: doing.taskID)
  }

  /// Stop for Now. Not on the undo stack; the task does not change.
  static func stop(_ doing: DoState, nav: NavigationState) {
    Haptics.commit()
    DoStore.shared.stop(sessionID: doing.sessionID)
    nav.doExitSince = doing.startedAt
    nav.doSheet = .stopNote(sessionID: doing.sessionID)
  }

  static func openLater(_ doing: DoState, nav: NavigationState) {
    Haptics.press()
    nav.doSheet = .later(doing)
  }

  /// Later saved a date: the normal date write with its undo entry, then the
  /// Do ends.
  static func saveLater(_ doing: DoState, date: Date, mode: RecurrenceRescheduleMode,
                        mutator: TaskMutator, context: ModelContext, nav: NavigationState) {
    Haptics.commit()
    recordingSchedule(String(localized: "Schedule Task", comment: "Undo action name"),
                      doing.taskID, mutator: mutator, context: context) {
      mutator.apply(.scheduleFor(date), to: doing.taskID, mode: mode)
    }
    mutator.acknowledge(id: doing.taskID)
    DoStore.shared.endForLater(sessionID: doing.sessionID)
    nav.doExitSince = doing.startedAt
  }

  static func recordingSchedule(_ name: String, _ taskID: String, mutator: TaskMutator,
                                context: ModelContext, _ body: () -> Void) {
    let before = LocalCache.liveTasks(ids: [taskID], in: context).map(TaskUndo.ScheduleSnapshot.init)
    body()
    TaskUndo.recordScheduleChange(name: name, before: before, context: context, mutator: mutator)
  }

  // MARK: After an exit

  /// One line when agent requests came in during the Do. Nothing otherwise.
  static func offerNeedsYou(nav: NavigationState, context: ModelContext) {
    guard let since = nav.doExitSince else { return }
    nav.doExitSince = nil
    let count = openRequests(since: since, context: context)
    if count > 0 { nav.doSheet = .needsYou(count: count) }
  }

  /// Open agent requests (Review and questions) that arrived since `since`.
  static func openRequests(since: Date, context: ModelContext) -> Int {
    LocalCache.liveAggregateEntities(in: context).filter { task in
      // The raw column first, so only rows that carry JSON decode it.
      guard task.status == .open, task.conversationJSON != nil else { return false }
      let convo = task.conversation
      if convo.needsHumanReview { return (convo.endStateAt ?? .distantPast) >= since }
      guard convo.hasOpenProviderQuestion, let asked = convo.thread.last?.ts else { return false }
      return asked >= since
    }.count
  }
}

extension View {
  /// The sheets of the Do flow. Attach once per window, at the root.
  func doFlowSheets() -> some View { modifier(DoFlowSheets()) }
}

private struct DoFlowSheets: ViewModifier {
  @Environment(NavigationState.self) private var nav
  @Environment(TaskMutator.self) private var mutator
  @Environment(\.modelContext) private var modelContext

  /// A fixed repeat rule needs a choice before the date lands, the same one
  /// the task list asks. It waits until the When sheet has gone.
  private struct Reschedule {
    let doing: DoState
    let date: Date
  }
  @State private var pendingReschedule: Reschedule?
  @State private var reschedule: Reschedule?

  func body(content: Content) -> some View {
    @Bindable var nav = nav
    content
      .sheet(item: $nav.doSheet, onDismiss: sheetClosed) { sheet in
        switch sheet {
        case .later(let doing):
          whenPicker(doing)
        case .stopNote(let sessionID):
          DoStopNoteSheet(sessionID: sessionID)
        case .needsYou(let count):
          DoNeedsYouSheet(count: count)
        }
      }
      .confirmationDialog(
        RegistryPrompts.prompt(.rescheduleFixedRepeat).title,
        isPresented: Binding(get: { reschedule != nil }, set: { if !$0 { reschedule = nil } }),
        titleVisibility: .visible
      ) {
        Button(RegistryPrompts.prompt(.rescheduleFixedRepeat).optionTitle(.exception)) {
          answerReschedule(.makeException)
        }
        Button(RegistryPrompts.prompt(.rescheduleFixedRepeat).optionTitle(.updateRule)) {
          answerReschedule(.updateRule)
        }
        Button(RegistryPrompts.cancelTitle, role: .cancel) { reschedule = nil }
      } message: {
        Text(RegistryPrompts.prompt(.rescheduleFixedRepeat).message)
      }
  }

  /// The one When picker (ADR 0029), for this task. Only a picked day ends the
  /// Do. A time, or Clear, is a plain write.
  private func whenPicker(_ doing: DoState) -> some View {
    let task = LocalCache.liveTasks(ids: [doing.taskID], in: modelContext).first
    return DatePickerSheet(
      title: RegistrySurfaces.taskAttribute(.when).label,
      attribute: .when,
      initialDate: SeptenaDate.parse(task?.scheduled ?? ""),
      initialToday: task?.today == true,
      initialStartTime: task?.startTime,
      initialDurationMinutes: task?.durationMinutes,
      onTimeSlotChange: { start, minutes in
        DoFlow.recordingSchedule(String(localized: "Change Time", comment: "Undo action name"),
                                 doing.taskID, mutator: mutator, context: modelContext) {
          mutator.apply(.setTimeSlot(startTime: start, durationMinutes: minutes, timeZone: nil),
                        to: doing.taskID)
        }
      }
    ) { date in
      guard let date else { return clearWhen(doing) }
      if let rule = task?.recurrence, !rule.afterCompletion,
         SeptenaDate.format(date) != task?.scheduled {
        pendingReschedule = Reschedule(doing: doing, date: date)
      } else {
        saveLater(doing, date: date, mode: .makeException)
      }
    }
    .taskPickerChrome(DatePickerSheet.detents(showsRepeat: false, showsTime: true))
  }

  private func clearWhen(_ doing: DoState) {
    Haptics.commit()
    DoFlow.recordingSchedule(String(localized: "Schedule Task", comment: "Undo action name"),
                             doing.taskID, mutator: mutator, context: modelContext) {
      mutator.apply(.clearWhenDate, to: doing.taskID)
    }
  }

  private func saveLater(_ doing: DoState, date: Date, mode: RecurrenceRescheduleMode) {
    DoFlow.saveLater(doing, date: date, mode: mode, mutator: mutator,
                     context: modelContext, nav: nav)
  }

  private func answerReschedule(_ mode: RecurrenceRescheduleMode) {
    guard let answer = reschedule else { return }
    reschedule = nil
    saveLater(answer.doing, date: answer.date, mode: mode)
    DoFlow.offerNeedsYou(nav: nav, context: modelContext)
  }

  /// Runs once a sheet is off screen, so the next one can open.
  private func sheetClosed() {
    DoStore.shared.dismissStopNote()
    if let pendingReschedule {
      self.pendingReschedule = nil
      reschedule = pendingReschedule
      return
    }
    DoFlow.offerNeedsYou(nav: nav, context: modelContext)
  }
}

// MARK: - Sheets

/// "Where did you stop?" after Stop for Now. One optional field: closing it
/// any way is fine.
private struct DoStopNoteSheet: View {
  let sessionID: String

  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @FocusState private var focused: Bool

  private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    NavigationStack {
      Form {
        TextField(RegistryDoing.stopNoteTitle, text: $text, axis: .vertical)
          .lineLimit(4)
          .focused($focused)
      }
      .formStyle(.grouped)
      .navigationTitle(RegistryDoing.stopNoteTitle)
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(RegistryDoing.stopNoteSkipTitle) { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(RegistryDoing.stopNoteSaveTitle) {
            Haptics.commit()
            DoStore.shared.setNote(sessionID: sessionID, text)
            dismiss()
          }
          .disabled(isBlank)
        }
      }
    }
    .presentationDetents([.medium, .large])
    .macSheetFrame(width: 420, height: 240)
    .onAppear {
      // Focus after the sheet settles: an immediate focus is dropped before
      // the field joins the responder chain.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
    }
  }
}

/// The one line after an exit: agent requests came in. It opens Review.
private struct DoNeedsYouSheet: View {
  let count: Int

  @Environment(NavigationState.self) private var nav
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Button {
          dismiss()
          nav.go(to: .filter(.review))
        } label: {
          Label(RegistryDoing.needsYou(count: count), systemImage: Route.filter(.review).icon)
        }
      }
      .formStyle(.grouped)
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          DrawerCloseButton { dismiss() }
        }
      }
    }
    .presentationDetents([.fraction(0.25), .medium])
    .macSheetFrame(width: 360, height: 180)
  }
}
