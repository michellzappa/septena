import SwiftUI

// The composer's elective-pill rail — a single row of icon + label capsules
// under the title & notes, in the registry's `taskAttributes` order. A picker
// pill opens the same sheet the row menu opens (TaskPickerSheets.swift, ADR
// 0029); the checklist and attachments render in the composer. Split out of
// TaskComposer.swift.

// MARK: - Attribute pill bar

/// The horizontal rail of elective pills under the title. Owns which date /
/// repeat editor is expanded inline; the List picker opens as a sheet.
struct TaskAttributeBar: View {
  @Binding var draft: TaskDraft
  let areas: [Area]
  let projects: [Project]
  let accent: Color
  /// Neutral chrome: the inline (Things-style) editor keeps the whole rail
  /// monochrome — filled pills wear a gray capsule, not the section accent — so
  /// the open editor reads as calm form, with color reserved for the checkbox.
  /// The drawer keeps the accent tint.
  var neutral: Bool = false
  /// The composer's shared keyboard cursor — pills bind to `.pill(attr)` so Tab
  /// can land on them and they can draw the focus ring.
  @FocusState.Binding var focus: TaskEditFocus?
  /// One-shot keyboard-activation channel: when the composer sets this to a
  /// pill (Space / Return on a focused pill), the bar runs `select` and clears
  /// it. Pointer taps call `select` directly.
  @Binding var activate: Attribute?
  /// Edit mode only — when set and no conversation exists yet, a Discuss pill
  /// joins the rail to kick off the on-device conversation flow.
  var discussTask: SeptenaTask? = nil
  /// Written whenever `showsDiscuss` changes so the composer can Tab to the pill.
  @Binding var discussVisible: Bool
  /// The composer's Tab loop, handed to the checklist so arrows and Tab walk
  /// out of the steps the same way they walk between them.
  var moveFocus: ((Bool) -> Void)? = nil
  /// The task page blocks this host shows (ADR 0029). Off hides the pill and
  /// its panel.
  var showsChecklist: Bool = true
  var showsAttachments: Bool = true
  /// The task page's `history` block is on at this depth (page only).
  var showsHistory: Bool = false
  /// A chip drawn at the front of the rail, before the pills: the Paste chip
  /// on a blank new task. The composer owns it (it reads the clipboard).
  var leading: AnyView? = nil
  /// How the attributes lay out (ADR 0029). `.rail` is the quick edit: one
  /// sideways row of pills. `.rows` is the task page: a column with one
  /// full-width row per attribute, then the checklist and attachments as
  /// their own sections. Both open the same pickers.
  enum Layout { case rail, rows }
  var layout: Layout = .rail

  /// The electives. Order, label and icon come from the registry
  /// (`registry/surfaces.json` `taskAttributes`, ADR 0020) so the AppKit
  /// composer and every other client show the same rail; per-attribute
  /// *values* are derived from the draft in `value(for:)` / `isSet(_:)`, and
  /// each editor lives in its own panel. So every pill is wired identically:
  /// one `ForEach`, one `select(_:)`. The raw value is the registry id.
  enum Attribute: String, Identifiable {
    case when, deadline, reminder, repeatRule = "repeat", star, list, tags, checklist, attachments
    /// Edit-mode AI kickoff — shown only before a conversation exists.
    case discuss
    /// The change log: opens `TaskHistoryPanel` under the rail. Read-only.
    case history
    var id: Self { self }

    private var registry: RegistryTaskAttribute { RegistrySurfaces.taskAttribute(rawValue) }

    /// Every pill that ships on this platform, in registry rail order.
    static let rail: [Attribute] = RegistrySurfaces.taskAttributePills(on: RegistryPlatform.current)
      .compactMap { Attribute(rawValue: $0.id) }
    /// The pills a draft without a saved task can use (registry `editOnly` false).
    static let draftCases: [Attribute] = rail.filter { !$0.editOnly }

    var icon: String { registry.sfSymbol }
    /// The symbol in the pill's state: the filled variant while set or on
    /// (`icons.json` `sfSymbolOn`; DesignSpec "a toggle that is on is filled").
    func icon(on: Bool) -> String { registry.sfSymbol(on: on) }
    var label: String { registry.label }
    /// Needs a saved task (tags, checklist, attachments, discuss).
    var editOnly: Bool { registry.editOnly }
    /// A `popover` attribute opens its picker: the same sheet the row menu,
    /// the menu bar and the shortcut open (ADR 0029: one picker per attribute).
    /// The rest act in place (Star) or expand a panel under the rail.
    var presentsSheet: Bool { registry.surfaceTier == "popover" }
  }

  /// Edit-only pill values, read once per render from the live task.
  private struct EditOnlyState {
    let tagNames: [String]
    let stepsDone: Int
    let stepsTotal: Int
    let attachments: Int

    @MainActor init(task: SeptenaTask) {
      let ctx = LocalStore.shared.container.mainContext
      let live = LocalCache.liveTasks(ids: [task.id], in: ctx).first ?? task
      tagNames = LocalCache.resolvedTags(for: live, tagsByID: LocalCache.tagsByID(in: ctx)).map(\.name)
      let steps = LocalCache.checklistItems(forTaskID: task.id, in: ctx)
      stepsDone = steps.filter(\.checked).count
      stepsTotal = steps.count
      attachments = SeptenaServices.shared.taskAttachmentStore.attachmentCount(taskID: task.id)
    }
  }

  /// The currently expanded inline pill (never a picker pill, which presents a sheet).
  @State private var expanded: Attribute?
  /// The picker sheet that shows, if any.
  @State private var picker: Attribute?
  /// A picker to open once the current sheet has gone (When's Repeat row).
  @State private var pendingPicker: Attribute?
  /// Bumped when the task changes outside the draft (tags from the picker,
  /// steps, attachments), so the edit-only pill values read the store again.
  @State private var editRevision = 0
  @State private var discussStarted: Bool
  @State private var discussWorking = false
  /// The Checklist pill was tapped on a task with no steps yet. A task WITH
  /// steps shows its checklist without this (same as the Mac composer).
  @State private var checklistOpened = false
  /// Bumped by the Checklist pill while the checklist already shows: the
  /// panel appends a step and focuses it (Mac `appendItemAndFocus`).
  @State private var checklistAddRequest = 0

  init(draft: Binding<TaskDraft>, areas: [Area], projects: [Project], accent: Color,
       neutral: Bool = false, focus: FocusState<TaskEditFocus?>.Binding,
       activate: Binding<Attribute?>, discussTask: SeptenaTask? = nil,
       discussVisible: Binding<Bool> = .constant(false),
       moveFocus: ((Bool) -> Void)? = nil,
       showsChecklist: Bool = true, showsAttachments: Bool = true,
       showsHistory: Bool = false, leading: AnyView? = nil, layout: Layout = .rail) {
    _draft = draft
    self.areas = areas
    self.projects = projects
    self.accent = accent
    self.neutral = neutral
    _focus = focus
    _activate = activate
    self.discussTask = discussTask
    _discussVisible = discussVisible
    self.moveFocus = moveFocus
    self.showsChecklist = showsChecklist
    self.showsAttachments = showsAttachments
    self.showsHistory = showsHistory
    self.leading = leading
    self.layout = layout
    _discussStarted = State(initialValue: discussTask?.conversation.hasStarted ?? true)
  }

  var body: some View {
    let _ = editRevision
    let edit = discussTask.map(EditOnlyState.init(task:))
    return Group {
      switch layout {
      case .rail: railBody(edit: edit)
      case .rows: rowsBody(edit: edit)
      }
    }
    .onAppear(perform: reloadDiscussState)
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      reloadDiscussState()
      editRevision += 1
    }
    .sheet(item: $picker, onDismiss: {
      editRevision += 1
      if let next = pendingPicker {
        pendingPicker = nil
        picker = next
      }
    }) { attr in
      pickerSheet(attr)
    }
    // Keyboard Space / Return on a focused pill arrives here.
    .onChange(of: activate) { _, attr in
      guard let attr else { return }
      activate = nil
      select(attr)
    }
  }

  // MARK: - Page layout (rows)

  /// The attributes that get a row on the page. Checklist, attachments and
  /// history are sections, not rows.
  private var rowAttributes: [Attribute] {
    Attribute.rail.filter { shows($0) && ![.checklist, .attachments, .history].contains($0) }
  }

  private func rowsBody(edit: EditOnlyState?) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      // Each attribute is its own card, so every one reads as its own place
      // on the page rather than a line in a list.
      VStack(spacing: 10) {
        ForEach(rowAttributes) { attr in
          AttributeRow(icon: attr.icon(on: isSet(attr, edit: edit)), label: attr.label,
                       value: value(for: attr, edit: edit), isSet: isSet(attr, edit: edit),
                       opensPicker: attr.presentsSheet,
                       isLoading: attr == .discuss && discussWorking,
                       accent: accent) { select(attr) }
            .background(Theme.secondaryGroupedBackground,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .focused($focus, equals: .pill(attr))
            .disabled(attr == .discuss && discussWorking)
        }
      }

      if showsChecklist, let task = discussTask {
        pageSection(.checklist) {
          VStack(alignment: .leading, spacing: 8) {
            if checklistOpened || (edit?.stepsTotal ?? 0) > 0 {
              TaskChecklistPanel(taskID: task.id, addRequest: checklistAddRequest,
                                 focus: $focus, moveFocus: moveFocus)
            }
            AttributeRow(icon: "plus", label: RegistryActions.title("task.addChecklistItem"),
                         value: nil, isSet: false, opensPicker: false, isLoading: false,
                         accent: accent) { select(.checklist) }
          }
        }
      }

      if showsAttachments, let task = discussTask {
        pageSection(.attachments) { TaskAttachmentsPanel(taskID: task.id) }
      }
    }
  }

  /// A page section: the block's registry heading over its content.
  private func pageSection<Content: View>(_ kind: RegistryTaskPageBlockKind,
                                          @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(RegistrySurfaces.taskPageBlock(kind).label ?? "")
        .font(.septenaLabel)
        .foregroundStyle(Theme.inkSecondary)
      content()
    }
  }

  // MARK: - Quick edit layout (rail)

  private func railBody(edit: EditOnlyState?) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      // Steps sit open under the notes whenever the task has any, so opening a
      // task shows its checklist without a tap. The pill only starts one.
      if showsChecklist, let task = discussTask, checklistOpened || (edit?.stepsTotal ?? 0) > 0 {
        TaskChecklistPanel(taskID: task.id, addRequest: checklistAddRequest,
                           focus: $focus, moveFocus: moveFocus)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }

      // Horizontal rail of icon + label capsules — scrolls sideways inside its
      // bounded slot so the rail never widens its card past the screen. "Today"
      // lives inside the When control rather than duplicating the rail.
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          if let leading { leading }
          ForEach(Attribute.rail) { attr in
            if shows(attr) {
              AttributePill(icon: attr.icon(on: isSet(attr, edit: edit)), label: attr.label,
                            value: value(for: attr, edit: edit), isSet: isSet(attr, edit: edit),
                            isActive: attr != .discuss && expanded == attr,
                            isLoading: attr == .discuss && discussWorking,
                            isFocused: focus == .pill(attr),
                            accent: accent, neutral: neutral) { select(attr) }
                .focused($focus, equals: .pill(attr))
                .disabled(attr == .discuss && discussWorking)
            }
          }
        }
        // Small inset so the capsule glass edge and focus ring don't clip
        // against the scroll viewport's bounds.
        .padding(.vertical, 2)
        .padding(.horizontal, 1)
      }
      .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

      inlineEditor
    }
  }

  private var showsDiscuss: Bool {
    discussTask != nil && !discussStarted && OnDeviceAI.isAvailable
  }

  /// Whether a pill is on the rail: edit-only pills need a saved task, and
  /// Discuss only shows before a conversation exists.
  private func shows(_ attr: Attribute) -> Bool {
    if attr == .discuss { return showsDiscuss }
    if attr == .checklist && !showsChecklist { return false }
    if attr == .attachments && !showsAttachments { return false }
    if attr == .history && !(showsHistory && TaskHistory.isAvailable) { return false }
    return !attr.editOnly || discussTask != nil
  }

  /// The value shown on a pill (its `nil` falls back to the plain label). All
  /// values are derived from the draft — the single read-side of the rail.
  private func value(for attr: Attribute, edit: EditOnlyState?) -> String? {
    switch attr {
    case .discuss:
      return discussWorking ? RegistrySurfaces.taskAttribute(attr.rawValue).workingLabel : nil
    case .tags:
      guard let names = edit?.tagNames, !names.isEmpty else { return nil }
      return names.count == 1 ? names[0] : RegistrySurfaces.taskAttributeCount(attr.rawValue, count: names.count)
    case .checklist:
      guard let edit, edit.stepsTotal > 0 else { return nil }
      return "\(edit.stepsDone)/\(edit.stepsTotal)"
    case .attachments:
      guard let count = edit?.attachments, count > 0 else { return nil }
      return RegistrySurfaces.taskAttributeCount(attr.rawValue, count: count)
    // "When" folds in Today: a task pinned to today (no date) reads "Today", a
    // future planning date reads its date, nothing set reads as Anytime (nil).
    case .when:
      let slot = TaskTimeSlot.format(startTime: draft.startTime, durationMinutes: draft.durationMinutes)
      if let s = draft.scheduled {
        let base = Self.dateLabel(s)
        return slot.map { "\(base) · \($0)" } ?? base
      }
      if draft.onToday {
        let today = String(localized: "Today", comment: "Relative date")
        return slot.map { "\(today) · \($0)" } ?? today
      }
      return slot
    case .deadline:
      return draft.deadline.map(Self.dateLabel)
    case .reminder:
      return draft.reminder?.badgeText()?.text
    case .repeatRule:
      return draft.recurrence?.shortLabel
    // The filled pill already says it; no second word for "starred".
    case .star:
      return nil
    // The List pill always names its destination — "Inbox" by default, the area
    // or project once filed (but tinted only when explicitly filed, see isSet).
    case .list:
      return draft.listLabel(areas: areas, projects: projects)
    // Read-only: the pill just names the log.
    case .history:
      return nil
    }
  }

  /// Whether a pill counts as "filled" — drives the accent tint.
  private func isSet(_ attr: Attribute, edit: EditOnlyState?) -> Bool {
    switch attr {
    case .discuss:     discussWorking
    case .history:     false
    case .tags:        !(edit?.tagNames.isEmpty ?? true)
    case .checklist:   (edit?.stepsTotal ?? 0) > 0
    case .attachments: (edit?.attachments ?? 0) > 0
    case .when:        draft.scheduled != nil || draft.onToday
    case .deadline:    draft.deadline != nil
    case .reminder:    draft.reminder != nil
    case .repeatRule:  draft.recurrence != nil
    case .star:        draft.starred
    case .list:        draft.areaId != nil || draft.projectId != nil
    }
  }

  @ViewBuilder
  private var inlineEditor: some View {
    // Attachments and History expand a panel under the rail. The checklist
    // renders above the rail; the pickers open as sheets.
    if expanded == .attachments, let task = discussTask {
      TaskAttachmentsPanel(taskID: task.id)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
    if expanded == .history, let task = discussTask {
      TaskHistoryPanel(taskID: task.id)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
  }

  /// The picker for a `popover` attribute. These are the same sheets, with the
  /// same detents, that `TaskListModalPresenter` opens from the row menu, so a
  /// pill and a menu row can never show different editors (ADR 0029). The pill
  /// writes the draft; the composer commits it.
  @ViewBuilder
  private func pickerSheet(_ attr: Attribute) -> some View {
    switch attr {
    case .when:
      DatePickerSheet(
        title: attr.label,
        initialDate: draft.scheduled,
        initialToday: draft.onToday && draft.scheduled == nil,
        clearLabel: "No Date",
        initialStartTime: draft.startTime,
        initialDurationMinutes: draft.durationMinutes,
        onTimeSlotChange: { start, minutes in
          draft.startTime = start
          draft.durationMinutes = minutes
          // A time with no day means today, as the AppKit composer does.
          if start != nil && !draft.onToday && draft.scheduled == nil { draft.setToday() }
        },
        // The same Repeat row the row menu's When picker shows (#300).
        repeatLabel: TaskRepeatLabel.title(draft.recurrence),
        onRepeat: { pendingPicker = .repeatRule }
      ) { date in
        if let date { draft.setScheduled(date) } else { draft.clearWhen() }
      }
      .taskPickerChrome(DatePickerSheet.detents(showsRepeat: true, showsTime: true))
    case .deadline:
      DatePickerSheet(title: attr.label, initialDate: draft.deadline,
                      clearLabel: "Remove Deadline") { date in
        draft.deadline = date
      }
      .taskPickerChrome(DatePickerSheet.detents(showsRepeat: false, showsTime: false))
    case .reminder:
      ReminderPickerSheet(initial: draft.reminder) { reminder in
        draft.reminder = reminder
      }
      .taskPickerChrome(TaskPickerDetents.standard)
    case .repeatRule:
      RecurrencePickerSheet(
        initial: draft.recurrence,
        hasScheduledDate: draft.scheduled != nil,
        scheduledDate: SeptenaDate.format(draft.scheduled),
        initialPaused: discussTask?.recurrencePaused ?? false,
        onPick: { rule in draft.recurrence = rule },
        // Pause is a field of the saved task, not of the draft.
        onPauseChanged: discussTask.map { task -> (Bool) -> Void in
          { paused in
            Haptics.commit()
            SeptenaServices.shared.taskMutator.setRecurrencePaused(id: task.id, paused: paused)
          }
        })
      .taskPickerChrome(TaskPickerDetents.standard)
    case .list:
      MovePickerSheet(areas: areas, projects: projects,
                      currentAreaId: draft.areaId, currentProjectId: draft.projectId) { a, p in
        draft.areaId = a; draft.projectId = p
      }
      .taskPickerChrome(TaskPickerDetents.move)
    case .tags:
      if let task = discussTask {
        TagPickerSheet(taskIDs: [task.id])
          .taskPickerChrome(TaskPickerDetents.standard)
      }
    case .star, .checklist, .attachments, .discuss, .history:
      EmptyView()
    }
  }

  /// The single dispatch for every pill: sheet-backed pills open their sheet,
  /// inline pills toggle the expanded panel. Per-attribute setup (Repeat seeding
  /// a default) lives in each panel's `onAppear`, so this stays uniform.
  private func select(_ attr: Attribute) {
    if attr == .discuss {
      startDiscuss()
      return
    }
    if attr == .star {
      focus = .pill(.star)
      Haptics.selection()
      a11yAnimate(.snappy(duration: 0.18)) { draft.starred.toggle() }
      return
    }
    // Checklist: open it (the panel seeds a first blank step and focuses it),
    // or, when it already shows, append a step and focus that.
    if attr == .checklist {
      let showing = checklistOpened
        || discussTask.map { EditOnlyState(task: $0).stepsTotal > 0 } == true
      a11yAnimate(.snappy(duration: 0.22)) {
        expanded = nil
        if showing { checklistAddRequest += 1 } else { checklistOpened = true }
      }
      return
    }
    // Move the keyboard cursor onto the pill (also drops the title field's
    // keyboard before a calendar opens — what `onInteractStart` used to do).
    focus = .pill(attr)
    a11yAnimate(.snappy(duration: 0.22)) {
      if attr.presentsSheet {
        expanded = nil
        picker = attr
      } else {
        expanded = (expanded == attr) ? nil : attr
      }
    }
  }

  private func startDiscuss() {
    guard let task = discussTask, showsDiscuss, !discussWorking else { return }
    focus = .pill(.discuss)
    discussWorking = true
    Task {
      _ = await ConversationEngine.advance(task: task)
      discussWorking = false
      reloadDiscussState()
    }
  }

  private func reloadDiscussState() {
    guard let id = discussTask?.id else {
      discussStarted = true
      discussVisible = false
      return
    }
    discussStarted = SeptenaServices.shared.taskMutator.conversation(id: id)?.hasStarted ?? false
    discussVisible = showsDiscuss
  }

  /// "Today" / "Tomorrow" / "May 14" for a pill value.
  static func dateLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return String(localized: "Today", comment: "Relative date") }
    if cal.isDateInTomorrow(d) { return String(localized: "Tomorrow", comment: "Relative date") }
    return SeptenaDate.monthDay(d)
  }
}

// MARK: - Page row

/// One attribute on the task page: icon, label, current value. A picker
/// attribute shows a chevron and opens the same sheet as its pill.
private struct AttributeRow: View {
  let icon: String
  let label: String
  let value: String?
  let isSet: Bool
  let opensPicker: Bool
  let isLoading: Bool
  let accent: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.iconTextGap) {
        Image(systemName: icon)
          .font(.septenaSidebarRow)
          .foregroundStyle(isSet ? accent : Theme.inkSecondary)
          .frame(width: 22)
        Text(label)
          .font(.septenaSidebarRow)
          .foregroundStyle(Theme.inkPrimary)
        Spacer(minLength: 8)
        if isLoading {
          ProgressView().controlSize(.small)
        } else if let value {
          Text(value)
            .font(.septenaSidebarRow)
            .foregroundStyle(isSet ? Theme.inkPrimary : Theme.inkSecondary)
            .lineLimit(1)
        }
        if opensPicker {
          Image(systemName: "chevron.right")
            .font(.septenaBadge)
            .foregroundStyle(Theme.inkSecondary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 11)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Pill

private struct AttributePill: View {
  let icon: String
  let label: String
  let value: String?
  let isSet: Bool
  let isActive: Bool
  var isLoading: Bool = false
  /// The keyboard cursor is on this pill — draw the focus ring (the system ring
  /// never shows with macOS keyboard navigation off).
  var isFocused: Bool = false
  let accent: Color
  /// Monochrome rail (inline editor): filled/active circles wear a neutral gray
  /// tint and the focus ring goes gray, so no section accent leaks into the
  /// open editor. See `TaskAttributeBar.neutral`.
  var neutral: Bool = false
  let action: () -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private static let height: CGFloat = 34
  /// A long value (a list name, a tag) truncates at this many characters
  /// instead of making one pill eat the rail. The rail's horizontal scroll
  /// proposes no width, so a frame cap would not truncate; cut the string.
  private static let maxChars = 24
  private var shownText: String {
    let text = value ?? label
    return text.count > Self.maxChars ? String(text.prefix(Self.maxChars - 1)) + "…" : text
  }

  /// Capsule fill — flat surface, no floating-glass elevation shadow.
  private var circleFill: Color {
    guard isSet || isActive else { return Theme.mutedSurface }
    if neutral {
      return Theme.inkPrimary.opacity(isActive ? 0.16 : 0.11)
    }
    return accent.opacity(isActive ? 0.42 : 0.30)
  }
  private var ringColor: Color { neutral ? Theme.selectionNeutral : accent }

  private var accessibleSummary: String {
    if let value { return "\(label): \(value)" }
    return label
  }

  var body: some View {
    Button(action: action) {
      // Icon + short label (the set value when there is one). An icon alone
      // was too obscure; the rail scrolls, so pills keep their natural width.
      HStack(spacing: 5) {
        if isLoading {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
        }
        Text(shownText)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
      }
      .foregroundStyle((isSet || isActive) ? Theme.inkPrimary : Theme.inkSecondary)
      .padding(.horizontal, 12)
      .frame(height: Self.height)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .modifier(AttributePillGlassBackground(
      circleFill: circleFill,
      tint: (isSet || isActive) ? (neutral ? Theme.inkPrimary.opacity(isActive ? 0.20 : 0.12) : accent.opacity(isActive ? 0.36 : 0.22)) : nil,
      reduceTransparency: reduceTransparency
    ))
    .overlay {
      Capsule()
        .strokeBorder(ringColor, lineWidth: 2)
        .opacity(isFocused ? 1 : 0)
        .allowsHitTesting(false)
    }
    .accessibilityLabel(accessibleSummary)
    .help(accessibleSummary)
  }
}

private struct AttributePillGlassBackground: ViewModifier {
  let circleFill: Color
  let tint: Color?
  let reduceTransparency: Bool

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(Capsule().fill(circleFill))
    } else {
      #if os(iOS)
      if let tint {
        content.glassEffect(.regular.tint(tint).interactive(), in: .capsule)
      } else {
        content.glassEffect(.regular.interactive(), in: .capsule)
      }
      #else
      content
        .background(.thinMaterial, in: Capsule())
        .background(Capsule().fill(tint ?? .clear))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
      #endif
    }
  }
}
// MARK: - Inline Checklist panel

/// The step ⌘K ticks instead of the task: set while a checklist step holds the
/// keyboard, nil otherwise. The task list's ⌘K handler reads it first (same
/// rule as the Mac's `KitChecklistView.toggleFocusedStep`).
@MainActor @Observable
final class FocusedChecklistStep {
  static let shared = FocusedChecklistStep()
  var toggle: (() -> Void)?
}

/// The task's checklist inside the SwiftUI task editor (iPhone, iPad). Drawn
/// and driven like the Mac composer's `KitChecklistView`: steps read as part
/// of the document under the notes (notes-size text, no card), ↑/↓ and Tab
/// walk title → notes → steps → rail, Return inserts below, Backspace on an
/// empty step deletes it, ⌘K ticks the focused step. Move and delete sit in
/// the row's context menu (long-press here, right-click on the Mac), with the
/// same × delete button on the row. Every edit records on `TaskUndo`.
private struct TaskChecklistPanel: View {
  let taskID: String
  /// Each change appends a step and focuses it (the Checklist pill).
  var addRequest: Int = 0
  @FocusState.Binding var focus: TaskEditFocus?
  /// The composer's focus loop (`TaskComposerCard.moveFocus`), which lists
  /// every step between notes and the rail.
  var moveFocus: ((Bool) -> Void)?

  @State private var items: [ChecklistItem] = []
  @State private var drafts: [String: String] = [:]

  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
        checklistRow(item: item, index: idx, total: items.count)
      }

      if !items.isEmpty {
        Button {
          addStep()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "plus")
              .font(.system(size: 11, weight: .medium))
              .frame(width: 24)
            Text("Add step")
              .font(.septenaLabel)
            Spacer(minLength: 0)
          }
          .foregroundStyle(Theme.inkSecondary)
          .padding(.vertical, 2)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add checklist step"))
      }
    }
    .onAppear {
      reload()
      if items.isEmpty { addStep() }
    }
    .onChange(of: addRequest) { _, _ in addStep() }
    .onChange(of: focus) { oldValue, newValue in
      if case .step(let id)? = oldValue, newValue != oldValue,
         let item = items.first(where: { $0.id == id }) {
        commitTitle(item)
      }
      publishFocusedStep(newValue)
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      reload()
    }
    .onDisappear {
      flushAllDrafts()
      FocusedChecklistStep.shared.toggle = nil
    }
  }

  private func checklistRow(item: ChecklistItem, index: Int, total: Int) -> some View {
    let binding = Binding<String>(
      get: { drafts[item.id] ?? item.title },
      set: { newValue in
        // Multi-line paste splits into 1 step per non-empty line.
        if newValue.contains("\n") || newValue.contains("\r") {
          let lines = newValue
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
          if lines.count > 1 {
            splitPaste(item, lines: lines)
            return
          }
          drafts[item.id] = lines.first ?? ""
        } else {
          drafts[item.id] = newValue
        }
      }
    )

    let spokenTitle = item.title.isEmpty ? "Untitled step" : item.title
    let spokenState = item.checked ? "checked" : "unchecked"

    return HStack(spacing: 6) {
      Button {
        toggle(item)
      } label: {
        Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 15, weight: .regular))
          .foregroundStyle(item.checked ? Theme.inkSecondary : Theme.iconMuted)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("\(spokenTitle), checklist item \(index + 1) of \(total), \(spokenState)"))

      TextField("Checklist item", text: binding)
        .textFieldStyle(.plain)
        .font(.septenaTaskTitle)
        .foregroundStyle(item.checked ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(item.checked, color: Theme.inkSecondary)
        .focused($focus, equals: .step(item.id))
        .onSubmit {
          commitTitle(item)
          insertBelow(item)
        }
        .onKeyPress(.upArrow) { moveFocus?(false); return .handled }
        .onKeyPress(.downArrow) { moveFocus?(true); return .handled }
        .onKeyPress(keys: [.tab]) { press in
          moveFocus?(!press.modifiers.contains(.shift)); return .handled
        }
        .onKeyPress(.delete) {
          guard (drafts[item.id] ?? item.title).isEmpty else { return .ignored }
          delete(item, focusPrevious: true)
          return .handled
        }
        .accessibilityLabel(Text("\(spokenTitle), checklist item \(index + 1) of \(total), \(spokenState)"))

      Button {
        delete(item, focusPrevious: false)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Theme.iconMuted)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Delete step"))
    }
    .contextMenu {
      if index > 0 {
        Button {
          moveOrder(itemID: item.id, delta: -1)
        } label: {
          Label("Move Up", systemImage: "arrow.up")
        }
      }
      if index + 1 < total {
        Button {
          moveOrder(itemID: item.id, delta: 1)
        } label: {
          Label("Move Down", systemImage: "arrow.down")
        }
      }
      Button(role: .destructive) {
        delete(item, focusPrevious: false)
      } label: {
        Label("Delete Step", systemImage: "trash")
      }
    }
  }

  /// ⌘K targets the focused step while one of THIS task's steps holds focus.
  private func publishFocusedStep(_ value: TaskEditFocus?) {
    if case .step(let id)? = value, items.contains(where: { $0.id == id }) {
      FocusedChecklistStep.shared.toggle = { [id] in
        guard let item = items.first(where: { $0.id == id }) else { return }
        toggle(item)
      }
    } else {
      FocusedChecklistStep.shared.toggle = nil
    }
  }

  private func reload() {
    let loaded = LocalCache.checklistItems(forTaskID: taskID, in: LocalStore.shared.container.mainContext)
    items = loaded
    for item in loaded where focus != .step(item.id) {
      drafts[item.id] = item.title
    }
  }

  private func flushAllDrafts() {
    for item in items { commitTitle(item) }
  }

  private func commitTitle(_ item: ChecklistItem) {
    guard let raw = drafts[item.id] else { return }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != item.title else { return }
    var after = item
    after.title = trimmed
    mutator.updateChecklistItem(id: item.id, title: trimmed)
    TaskUndo.recordChecklistUpdate(before: item, after: after, mutator: mutator)
    if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].title = trimmed }
  }

  private func addStep() {
    flushAllDrafts()
    guard let created = mutator.addChecklistItem(taskID: taskID, title: "") else { return }
    TaskUndo.recordChecklistAdd(created, mutator: mutator)
    drafts[created.id] = ""
    reload()
    focus = .step(created.id)
  }

  private func insertBelow(_ item: ChecklistItem) {
    flushAllDrafts()
    let idx = items.firstIndex(where: { $0.id == item.id }) ?? (items.count - 1)
    let pos: Double?
    if idx + 1 < items.count {
      let mid = (items[idx].position + items[idx + 1].position) / 2.0
      pos = (mid > items[idx].position && mid < items[idx + 1].position) ? mid : nil
    } else {
      pos = nil
    }
    guard let created = mutator.addChecklistItem(taskID: taskID, title: "", position: pos) else { return }
    TaskUndo.recordChecklistAdd(created, mutator: mutator)
    drafts[created.id] = ""
    reload()
    focus = .step(created.id)
  }

  private func toggle(_ item: ChecklistItem) {
    flushAllDrafts()
    Haptics.commit()
    var after = item
    after.checked.toggle()
    mutator.updateChecklistItem(id: item.id, checked: after.checked)
    TaskUndo.recordChecklistUpdate(before: item, after: after, mutator: mutator)
    a11yAnimate(.snappy(duration: 0.18)) { reload() }
  }

  private func moveOrder(itemID: String, delta: Int) {
    flushAllDrafts()
    guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
    let target = idx + delta
    guard items.indices.contains(target) else { return }
    let beforeIDs = items.map(\.id)
    var afterIDs = beforeIDs
    afterIDs.swapAt(idx, target)
    mutator.reorderChecklistItems(taskID: taskID, orderedIDs: afterIDs)
    TaskUndo.recordChecklistReorder(taskID: taskID, beforeIDs: beforeIDs, afterIDs: afterIDs, mutator: mutator)
    a11yAnimate(.snappy(duration: 0.18)) { reload() }
  }

  private func delete(_ item: ChecklistItem, focusPrevious: Bool) {
    let idx = items.firstIndex(where: { $0.id == item.id })
    let prevID = idx.flatMap { $0 > 0 ? items[$0 - 1].id : nil }
    let hadFocus = focus == .step(item.id)
    drafts.removeValue(forKey: item.id)
    mutator.deleteChecklistItem(id: item.id)
    TaskUndo.recordChecklistDelete(item, mutator: mutator)
    a11yAnimate(.snappy(duration: 0.18)) { reload() }
    if hadFocus { focus = (focusPrevious ? prevID : nil).map { .step($0) } }
  }

  private func splitPaste(_ item: ChecklistItem, lines: [String]) {
    guard let first = lines.first else { return }
    drafts[item.id] = first
    commitTitle(item)
    let rest = Array(lines.dropFirst())
    guard !rest.isEmpty else { return }
    let idx = items.firstIndex(where: { $0.id == item.id }) ?? (items.count - 1)
    let belowPos = idx + 1 < items.count
      ? items[idx + 1].position
      : (items[idx].position + TaskOrder.gap * Double(rest.count + 1))
    let span = belowPos - items[idx].position
    var lastID = item.id
    for (offset, text) in rest.enumerated() {
      let pos = items[idx].position + span * Double(offset + 1) / Double(rest.count + 1)
      if let created = mutator.addChecklistItem(taskID: taskID, title: text, position: pos) {
        TaskUndo.recordChecklistAdd(created, mutator: mutator)
        drafts[created.id] = text
        lastID = created.id
      }
    }
    reload()
    focus = .step(lastID)
  }
}
