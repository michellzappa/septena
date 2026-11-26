import SwiftUI
import UniformTypeIdentifiers

// MARK: - Task drag payload (sidebar re-home + in-list reorder)

/// Drag payload for re-homing one or more tasks onto a sidebar destination,
/// or reordering them within a manually-ordered list (`TaskReorderDrop`).
/// Also carries the floating Magic Plus sentinel (`newTask`) so native drag-
/// and-drop from `+` reuses every existing row gap, heading, group, date, and
/// sidebar drop target.
struct TaskDragIDs: Codable, Hashable, Transferable {
  static let newTaskSentinel = "__septena_magic_plus_new_task__"
  static let newTask = TaskDragIDs(ids: [newTaskSentinel])

  let ids: [String]

  static func isNewTaskPayload(_ ids: [String]) -> Bool {
    ids == [newTaskSentinel]
  }

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .septenaTaskDragIDs)
  }
}

/// The payload of a section heading's drag. Every drop target reads it as
/// `TaskDragIDs`. The second type only tells a hovered row that headings, not
/// tasks, are dragged: a `DropDelegate` sees the types before the drop, never
/// the data.
struct HeadingDragIDs: Codable, Transferable {
  let ids: [String]

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .septenaTaskDragIDs)
    CodableRepresentation(contentType: .septenaHeadingDragIDs)
  }
}

/// Drag payload for reordering Areas and Projects, and moving Projects between
/// Areas (or out to No Area) in the SwiftUI sidebar (`SidebarView`). Kept
/// distinct from `TaskDragIDs` so task-filing drops and structure-arrangement
/// drops never collide.
enum SidebarStructureDragItem: Codable, Hashable, Transferable {
  case area(String)
  case project(String)

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .septenaStructureDragItem)
  }
}

extension UTType {
  static let septenaTaskDragIDs = UTType(exportedAs: "com.septena.task-drag-ids")
  static let septenaHeadingDragIDs = UTType(exportedAs: "com.septena.heading-drag-ids")
  static let septenaStructureDragItem = UTType(exportedAs: "com.septena.structure-drag-item")
}

/// Row-level reorder target for manually-ordered lists — the in-list
/// counterpart of the sidebar's `SidebarTaskDrop`, same `TaskDragIDs`
/// payload. While a drag hovers, the row shows the `TaskInsertionMark` on the
/// side the drop would land (top half = insert above, bottom half = below).
/// The list does not move. `perform` is nil on rows that aren't reorderable
/// (date/tier-sorted lists), which makes the modifier a pass-through.
///
/// Uses `onDrop(of:delegate:)` rather than `.dropDestination` deliberately:
/// only `DropDelegate.dropUpdated` exposes the hover location live (needed
/// for the insertion side) and the drop proposal (`.move`, so the cursor
/// doesn't wear the green copy badge).
struct TaskReorderDrop: ViewModifier {
  /// On a heading row only a heading can land above it. A task goes under the
  /// heading, so its mark is always below.
  var isHeading = false
  let perform: ((_ ids: [String], _ before: Bool) -> Bool)?
  /// nil = no drag hovering; true = would insert above this row; false = below.
  @State private var hoverBefore: Bool? = nil
  @State private var rowHeight: CGFloat = 0

  func body(content: Content) -> some View {
    if let perform {
      content
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeight = $0 }
        .taskInsertionMark(before: hoverBefore)
        .onDrop(of: [.septenaTaskDragIDs],
                delegate: TaskReorderDropDelegate(hoverBefore: $hoverBefore,
                                                  rowHeight: { rowHeight },
                                                  isHeading: isHeading,
                                                  perform: perform))
    } else {
      content
    }
  }
}

private struct TaskReorderDropDelegate: DropDelegate {
  @Binding var hoverBefore: Bool?
  let rowHeight: () -> CGFloat
  let isHeading: Bool
  let perform: (_ ids: [String], _ before: Bool) -> Bool

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.septenaTaskDragIDs])
  }

  func dropEntered(info: DropInfo) { update(info) }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    update(info)
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) { hoverBefore = nil }

  func performDrop(info: DropInfo) -> Bool {
    let before = hoverBefore ?? true
    hoverBefore = nil
    // A drag carries ONE payload holding the whole selection (see
    // `dragPayload(for:)`), so the first provider is the drop.
    guard let provider = info.itemProviders(for: [.septenaTaskDragIDs]).first
    else { return false }
    provider.loadDataRepresentation(forTypeIdentifier: UTType.septenaTaskDragIDs.identifier) { data, _ in
      guard let data,
            let payload = try? JSONDecoder().decode(TaskDragIDs.self, from: data)
      else { return }
      DispatchQueue.main.async { _ = perform(payload.ids, before) }
    }
    return true
  }

  /// Which side of the row the pointer is on.
  private func update(_ info: DropInfo) {
    let canLandAbove = !isHeading || info.hasItemsConforming(to: [.septenaHeadingDragIDs])
    hoverBefore = canLandAbove && info.location.y < rowHeight() / 2
  }
}


// MARK: - Shared task row
//
// Canonical closed (non-editing) task row: checkbox + title + optional
// inline notes glyph + trailing date. Used by the Tasks drawer
// (`TasksDestinationView`) and intended to become the single row the deep
// `TaskListView` surface renders too, so both surfaces stay visually
// identical. Carries its own h/v padding so it drops straight into a
// `DrawerSection(padding: .none)` the same way `LogEntryRow` does.

/// Trailing provenance cue for an MCP/Claude-created row the user hasn't
/// engaged yet. Calm and peripheral (Things-style): it clears on contact via
/// `TaskMutator.acknowledge` and auto-decays after `AgentCue.decayWindow`.
/// Shares the row's single trailing agent-signal slot with `ConvoBadgeView` —
/// a live conversation's status badge wins, so the two never show at once.
/// Deliberately NOT a sparkle — a small accent dot reads as an unread marker,
/// drawn as a `circle.fill` at `.caption2` so it matches `ConvoBadgeView`'s
/// size and baseline exactly (they share the slot — all the dots read as one
/// family, differing only in color). To change the glyph, swap the symbol name.
struct AgentCueMarker: View {
  var tint: Color
  var body: some View {
    Image(systemName: "circle.fill")
      .font(.caption2)
      .foregroundStyle(tint)
      .accessibilityLabel(Text(TaskA11y.agentCue))
  }
}

/// Trailing cue for a row that *arrived in Today on its own* — a future-dated
/// plan whose day came, so it surfaced at the rollover rather than being added
/// by hand today (see `SeptenaTask.showsArrivedToday`). Same dot family as
/// `AgentCueMarker`/`ConvoBadgeView` so they read as one system, but drawn
/// hollow (`circle`) to say "newly here" rather than the agent cue's filled
/// "unseen by you". Calm and peripheral; it self-clears at the next rollover.
struct ArrivedTodayMarker: View {
  var tint: Color
  var body: some View {
    Image(systemName: "circle")
      .font(.caption2)
      .foregroundStyle(tint)
      .accessibilityLabel(Text(TaskA11y.arrivedToday))
  }
}

// MARK: - Checkable row primitive
//
// The shared skeleton behind every row with a checkbox — tasks, habits,
// supplements, chores. Owns the checkbox (+ baseline guide), an optional
// leading emoji (the checklist sections), the title with its inactive
// (done / skipped / deferred / cancelled) treatment, an optional subtitle,
// and the h/v padding so it drops into a
// `DrawerSection(padding: .none)` the same way `LogEntryRow` does. The only
// genuinely per-type piece — the trailing region (dates, time, badges) — is a
// `@ViewBuilder` slot the caller fills. Per-type toggle side-effects
// (celebrations, haptics) live in `onToggle`; per-type long-press actions are
// attached by the caller via `.contextMenu` on the returned row.
extension VerticalAlignment {
  private enum RowTitleCenter: AlignmentID {
    static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
  }
  /// Vertical center of a row's *title* text. The checkbox pins to this so it
  /// stays optically centered whether the title is a single line or wraps to
  /// two — `.firstTextBaseline` only ever tracks the first line, so a two-line
  /// title left the checkbox riding high. A subtitle below the title does not
  /// pull the guide down, since it's set on the title line alone.
  static let rowTitleCenter = VerticalAlignment(RowTitleCenter.self)
}

/// Default leading slot for `CheckableRow`: the standard `TaskCheckbox` with
/// its optional hero-animation anchor. Kept as a concrete wrapper type so
/// `CheckableRow` can accept a custom leading control (such as the Reminders
/// import arrow) without losing static typing or `AnyView` erasure.
struct TaskCheckboxSlot: View {
  let tint: Color
  let isDone: Bool
  let dashed: Bool
  let cornerDot: Color?
  let isToday: Bool
  let tenureFill: Double?
  let promoteFlashTrigger: Int
  let feel: CheckFeel
  let checkboxMatchID: String?
  let heroMatchNS: Namespace.ID?
  let heroMatchIsSource: Bool
  let onToggle: () -> Void

  var body: some View {
    TaskCheckbox(
      tint: tint,
      isDone: isDone,
      dashed: dashed,
      cornerDot: cornerDot,
      isToday: isToday,
      tenureFill: tenureFill,
      promotePulseTrigger: promoteFlashTrigger,
      feel: feel,
      onToggle: onToggle
    )
    .matchedHeroGeometry(checkboxMatchID, heroMatchNS, isSource: heroMatchIsSource)
  }
}

struct CheckableRow<Leading: View, Trailing: View>: View {
  /// Days carried on Today as 0…1, or nil. Fades the row's text and trailing
  /// cluster and leading control, all by the same amount (`TaskFade`).
  var tenureFill: Double? = nil
  /// Strikethrough + dimmed title. Usually `isDone`, but habits fold in
  /// skipped and chores fold in deferred, so the caller decides.
  var isInactive: Bool = false
  /// Optional leading emoji (checklist sections). Off → the title sits next
  /// to the box. Tasks leave this nil; their agent cue rides the trailing slot.
  var leadingEmoji: String? = nil
  let title: String
  /// Whether the row's accessibility label mentions notes. The visible notes
  /// marker lives in `TaskRow`'s trailing cluster (right-aligned), not here.
  var showsNotesGlyph: Bool = false
  var subtitle: String? = nil
  /// Fixed minimum height for the title's single-line box, centered on the
  /// checkbox line. Task rows opt in (via `TaskRow`) so the CLOSED row's title
  /// `Text` and the OPEN inline editor's title field (`InlineTitleTextView` on
  /// iOS, plain `TextField` on macOS) occupy an identical, centered band on the
  /// same checkbox line with zero vertical jump. nil (non-task rows) keeps the
  /// intrinsic height. See `TaskComposerCard.titleField`.
  var titleBandHeight: CGFloat? = nil
  /// How many lines the title may occupy before it truncates. Task rows pass
  /// the user's Settings ▸ Tasks ▸ "Title lines" choice on iOS (see
  /// `SettingsKey.tasksTitleLines`); everything else keeps the two-line default.
  var titleLineLimit: Int = 2
  /// Neutral selection capsule while this row's detail/edit modal is open
  /// (drawer surfaces — the deep list paints via `listRowBackground` instead).
  var isSelected: Bool = false
  /// Native `List(selection:)` cursor — keep title ink dark on the gray capsule.
  var isListSelected: Bool = false
  /// Soften the leading checkbox while touch multi-select is active so the row
  /// visually cues "tap anywhere to select" rather than "tap to complete".
  var checkboxDimmed: Bool = false
  /// Rising-edge counter from `PromoteFlashStore` — plays a brief amber row wash.
  var promoteFlashTrigger: Int = 0
  /// Optional hero-animation anchors (`matchedGeometryEffect`): the Things-style
  /// inline editor reuses the same id + namespace on ITS title and checkbox, so
  /// on expand/collapse they GLIDE between the closed row and the open editor
  /// instead of cross-fading into a new position. Shared namespace, distinct
  /// ids. Nil everywhere else.
  var titleMatchID: String? = nil
  var heroMatchNS: Namespace.ID? = nil
  /// Which endpoint of the hero glide is the `matchedGeometryEffect` source.
  /// Closed row and open editor must never both be `true` during a transition.
  var heroMatchIsSource: Bool = true
  @ViewBuilder var leading: () -> Leading
  @ViewBuilder var trailing: () -> Trailing
  var onTap: (() -> Void)? = nil

  @Environment(\.rowHInset) private var rowHInset
  @Environment(\.rowVInset) private var rowVInset
  @Environment(\.a11yMotion) private var motion
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(SettingsKey.loggingAnimationsEnabled) private var animationsEnabled = true
  @State private var washOpacity: Double = 0

  private var titleInk: Color {
    if isInactive { return Theme.inkSecondary }
    if isListSelected { return Theme.listSelectedInk }
    return Theme.inkPrimary
  }

  private var titleLine: some View {
    Text(title)
      .foregroundStyle(titleInk)
      .font(.septenaTaskTitle)
      .strikethrough(isInactive)
      .opacity(isInactive ? 0.5 : 1)
      .lineLimit(titleLineLimit)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .matchedHeroGeometry(titleMatchID, heroMatchNS, isSource: heroMatchIsSource)
      .accessibilityLabel(TaskA11y.rowLabel(title: title, hasNotes: showsNotesGlyph, isHeading: false))
  }

  var body: some View {
    HStack(alignment: .rowTitleCenter, spacing: Theme.iconTextGap) {
      leading()
        .alignmentGuide(.rowTitleCenter) { d in d[VerticalAlignment.center] }
        // The leading control fades with the row, by the same amount (mz, 2026-11-20),
        // so a slipping task reads as one fading line. It stays tappable.
        .opacity(TaskFade.rowOpacity(tenureFill) * (checkboxDimmed ? 0.45 : 1))

      if let leadingEmoji {
        Text(leadingEmoji).font(.body)
      }

      VStack(alignment: .leading, spacing: 4) {
        titleLine
          // Equal, centered title box across view ↔ edit (see `titleBandHeight`).
          // `minHeight: 0` (non-task rows) is a no-op, preserving intrinsic size.
          .frame(minHeight: titleBandHeight ?? 0, alignment: .center)
          .alignmentGuide(.rowTitleCenter) { d in d[VerticalAlignment.center] }
        if let subtitle {
          Text(subtitle)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .opacity(TaskFade.rowOpacity(tenureFill))

      trailing()
        .opacity(TaskFade.rowOpacity(tenureFill))
    }
    .a11yAnimation(Theme.Motion.quick, value: tenureFill)
    .padding(.horizontal, rowHInset)
    .padding(.vertical, rowVInset)
    .background(selectionHighlight)
    .contentShape(Rectangle())
    .modifier(OptionalTap(action: onTap))
    .onChange(of: promoteFlashTrigger) { old, new in
      guard new > old, !reduceMotion, animationsEnabled else { return }
      playPromoteWash()
    }
  }

  private func playPromoteWash() {
    washOpacity = 0.22
    motion.run(Theme.Motion.promote) { washOpacity = 0 }
  }

  @ViewBuilder private var selectionHighlight: some View {
    ZStack {
      if isSelected {
        RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
          .fill(Theme.listSelectionFill)
          .padding(.horizontal, max(0, rowHInset - 6))
      }
      if washOpacity > 0 {
        RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
          .fill(Theme.todayAccent.opacity(washOpacity))
          .padding(.horizontal, max(0, rowHInset - 6))
      }
    }
  }
}

extension CheckableRow where Leading == TaskCheckboxSlot {
  init(
    tint: Color,
    isDone: Bool,
    isToday: Bool = false,
    dashed: Bool = false,
    cornerDot: Color? = nil,
    tenureFill: Double? = nil,
    feel: CheckFeel = .stamp,
    isInactive: Bool,
    leadingEmoji: String? = nil,
    title: String,
    showsNotesGlyph: Bool = false,
    subtitle: String? = nil,
    titleBandHeight: CGFloat? = nil,
    titleLineLimit: Int = 2,
    isSelected: Bool = false,
    isListSelected: Bool = false,
    checkboxDimmed: Bool = false,
    promoteFlashTrigger: Int = 0,
    titleMatchID: String? = nil,
    checkboxMatchID: String? = nil,
    heroMatchNS: Namespace.ID? = nil,
    heroMatchIsSource: Bool = true,
    @ViewBuilder trailing: @escaping () -> Trailing,
    onToggle: @escaping () -> Void,
    onTap: (() -> Void)? = nil
  ) {
    self.init(
      tenureFill: tenureFill,
      isInactive: isInactive,
      leadingEmoji: leadingEmoji,
      title: title,
      showsNotesGlyph: showsNotesGlyph,
      subtitle: subtitle,
      titleBandHeight: titleBandHeight,
      titleLineLimit: titleLineLimit,
      isSelected: isSelected,
      isListSelected: isListSelected,
      checkboxDimmed: checkboxDimmed,
      promoteFlashTrigger: promoteFlashTrigger,
      titleMatchID: titleMatchID,
      heroMatchNS: heroMatchNS,
      heroMatchIsSource: heroMatchIsSource,
      leading: {
        TaskCheckboxSlot(
          tint: tint,
          isDone: isDone,
          dashed: dashed,
          cornerDot: cornerDot,
          isToday: isToday,
          tenureFill: tenureFill,
          promoteFlashTrigger: promoteFlashTrigger,
          feel: feel,
          checkboxMatchID: checkboxMatchID,
          heroMatchNS: heroMatchNS,
          heroMatchIsSource: heroMatchIsSource,
          onToggle: onToggle
        )
      },
      trailing: trailing,
      onTap: onTap
    )
  }
}

extension CheckableRow where Leading == TaskCheckboxSlot, Trailing == EmptyView {
  init(tint: Color, isDone: Bool, isToday: Bool = false,
       isInactive: Bool, leadingEmoji: String? = nil,
       title: String, subtitle: String? = nil, isSelected: Bool = false,
       onToggle: @escaping () -> Void, onTap: (() -> Void)? = nil) {
    self.init(tint: tint, isDone: isDone, isToday: isToday,
              isInactive: isInactive,
              leadingEmoji: leadingEmoji, title: title, subtitle: subtitle,
              isSelected: isSelected,
              trailing: { EmptyView() }, onToggle: onToggle, onTap: onTap)
  }
}

extension View {
  /// Conditionally tag a view as a `matchedGeometryEffect` source/target so it
  /// GLIDES between the closed row and the open inline editor instead of
  /// cross-fading. Only position is matched (`.position`) — e.g. the closed-row
  /// title `Text` and the editor's `TextField` have different intrinsic sizes —
  /// so we glide the top-leading corner and let each keep its own size. No-op
  /// when either arg is nil. Used for both the title and the checkbox.
  @ViewBuilder
  func matchedHeroGeometry(_ id: String?, _ ns: Namespace.ID?, isSource: Bool = true) -> some View {
    if let id, let ns {
      matchedGeometryEffect(
        id: id, in: ns, properties: .position, anchor: .topLeading, isSource: isSource)
    } else {
      self
    }
  }
}

/// Adds an `onTapGesture` only when an action is supplied. Rows inside a
/// SwiftUI `List` (the deep `TaskListView`) pass `nil` so the row's own tap
/// gesture never swallows List selection — they wire tap externally instead.
private struct OptionalTap: ViewModifier {
  let action: (() -> Void)?
  func body(content: Content) -> some View {
    if let action {
      content.onTapGesture(perform: action)
    } else {
      content
    }
  }
}

// MARK: - Task checkbox model
//
// The SINGLE source of truth for how a `SeptenaTask` maps to its checkbox
// chrome. Both the closed `TaskRow` and the open inline editor's title-line
// checkbox (`TaskComposerCard`) derive their box from this, so the two can
// never drift in logic — the box looks/behaves identically in view-row mode and
// edit mode. Pure derivation from the task + the surface's `showsTodayIndicator`
// (the one piece of context the box needs that isn't on the task itself).

struct TaskCheckboxModel {
  var tint: Color
  var isDone: Bool
  var isToday: Bool
  var dashed: Bool
  var cornerDot: Color?
  var tenureFill: Double?

  init(task: SeptenaTask, accent: Color, showsTodayIndicator: Bool,
       showsFadedIndicator: Bool = false) {
    // A volunteered, still-unratified agent proposal — the dashed "not a task
    // yet" form. Human captures stay solid; only MCP triage-band rows read so.
    let isProposal = task.isInTriageBand && task.source == TaskSource.mcp
    tint = accent
    isDone = task.status == .done
    // A row in Recently Deleted is out of every list, Today included, so it
    // never shows Today status or fading.
    let isDeleted = task.deletedAt != nil
    isToday = task.isOnToday && showsTodayIndicator && !isDeleted && !task.isFaded
    dashed = TaskRowFlags.languageV2 && isProposal
    // Accent corner dot for an open, committed task with an active or finished
    // conversation (agent work or Discuss). Proposals read as dashed instead,
    // and completed/cancelled or stopped tasks hide the dot.
    cornerDot = {
      guard TaskRowFlags.languageV2, task.status == .open, !isProposal else { return nil }
      if task.conversation.hasStarted, deriveConvo(task.conversation).badge != nil { return accent }
      return nil
    }()
    // Countdown toward the 14-day fade window in every open list
    // (`docs/TASK_FADE_SPEC.md` §4). Inside the Faded pile itself
    // (`showsFadedIndicator == false`), faded rows stay at full opacity; inside
    // a project or area (`showsFadedIndicator == true`), they render visibly
    // faded at `TaskFade.minOpacity`.
    if task.isFaded && showsFadedIndicator && !isDeleted {
      tenureFill = 1.0
    } else {
      tenureFill = TaskRowFlags.agingEnabled && !isDeleted ? task.fadeFill() : nil
    }
  }
}

extension TaskCheckbox {
  /// Build the row checkbox from the shared model. Selection / promote-pulse /
  /// feel stay per-call — they're surface chrome (list highlight, pin flash),
  /// not task identity, so they don't belong in the shared model.
  init(model: TaskCheckboxModel, promotePulseTrigger: Int = 0, feel: CheckFeel = .stamp,
       onToggle: @escaping () -> Void) {
    self.init(tint: model.tint, isDone: model.isDone, dashed: model.dashed,
              cornerDot: model.cornerDot,
              isToday: model.isToday, tenureFill: model.tenureFill,
              promotePulseTrigger: promotePulseTrigger,
              feel: feel, onToggle: onToggle)
  }
}

/// Compact notes marker for the task row's right-aligned trailing cluster.
enum TaskNotesGlyph {
  static var view: some View {
    Image(systemName: "text.alignleft")
      .font(.system(size: 10))
      .foregroundStyle(Theme.inkSecondary)
      .accessibilityHidden(true)
  }
}

/// Permanent "an agent added this" marker for the row's trailing cluster
/// (`taskPage.provenance`, feature `task.provenance`). Unlike `AgentCueMarker`
/// it never clears: provenance is a fact about the task, not an unread state.
/// Muted ink like the notes glyph, so a list an agent filled stays calm.
struct AgentAuthoredGlyph: View {
  let task: SeptenaTask
  var body: some View {
    Image(systemName: RegistrySurfaces.provenanceAgentSymbol)
      .font(.system(size: 10))
      .foregroundStyle(Theme.inkSecondary)
      .accessibilityLabel(Text(task.addedByPhrase))
  }
}

/// The task page's "Added by" section (`taskPage.provenance`): who added the
/// task (an agent's name, or "You") and when. Read-only metadata.
struct TaskProvenanceSection: View {
  let task: SeptenaTask
  let label: String
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.septenaLabel)
        .foregroundStyle(Theme.inkSecondary)
      HStack(spacing: 6) {
        if task.isAgentAuthored {
          Image(systemName: RegistrySurfaces.provenanceAgentSymbol)
            .font(.system(size: 12))
            .foregroundStyle(Theme.inkSecondary)
            .accessibilityHidden(true)
        }
        Text(task.addedByDetail)
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkPrimary)
          .textSelection(.enabled)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Task row
//
// The single closed (non-editing) task row used by every task surface — the
// Tasks drawer, the deep `TaskListView`, and the dashboard Next feed — so a
// task looks identical wherever it appears. A thin, data-driven wrapper over
// `CheckableRow`: it owns the canonical trailing (notes + recurrence glyph +
// the due / scheduled date treatment) and resolves the project→area subtitle.
struct TaskRow: View {
  let task: SeptenaTask
  var accent: Color
  /// Backing catalog for the project / area subtitle. Empty → no subtitle.
  var areas: [Area] = []
  var projects: [Project] = []
  /// Suppress the project / area chip when the surrounding context already
  /// shows it (a project page suppresses both; an area page suppresses area
  /// only). The deep list maps these from its `TaskFilter`.
  var suppressProject: Bool = false
  var suppressArea: Bool = false
  /// Show the trailing Today pill (and scheduled date) on off-Today surfaces.
  /// Pass `false` on Today / Next surfaces (where every row is already Today).
  var showsTodayIndicator: Bool = true
  /// Show a trailing Faded pill and faded row opacity when a faded task appears
  /// inside a project or area. Pass `false` inside the Faded pile itself.
  var showsFadedIndicator: Bool = false
  /// Highlight this row while its edit modal is open (see `CheckableRow`).
  var isSelected: Bool = false
  /// Native `List(selection:)` cursor on the deep task list.
  var isListSelected: Bool = false
  /// Soften the checkbox during iOS touch multi-select mode.
  var checkboxDimmed: Bool = false
  /// The row was just checked and still holds its place (`SettleStore`). Its
  /// trailing cluster stays as it was, so the title never rewraps and the rows
  /// below do not move until the row leaves.
  var isSettling: Bool = false
  /// Optional inboard-most trailing accessory — the deep list passes the Inbox
  /// "file here" capsule here so it sits left of the date (a variable-width
  /// element kept inboard of the fixed glyphs). Nil on every other surface.
  var accessory: AnyView? = nil
  /// Optional 1-level checklist progress summary (`done/total`). Zero extra
  /// chrome when nil or `total == 0` (docs/CHECKLISTS_SPEC.md §4).
  var checklistSummary: (done: Int, total: Int)? = nil
  /// The kind of the item this task was created from (its `from` reference).
  /// Nil draws nothing.
  var fromKind: RegistryTaskReferenceKind? = nil
  /// Resolved live tags on this task (empty when untagged -> zero chrome).
  var tagChips: [TaskTag] = []
  /// Hero-animation anchors forwarded to `CheckableRow` so the closed row's
  /// title + checkbox glide into the inline editor. See `CheckableRow`.
  var titleMatchID: String? = nil
  var checkboxMatchID: String? = nil
  var heroMatchNS: Namespace.ID? = nil
  var heroMatchIsSource: Bool = true
  let onToggle: () -> Void
  var onTap: (() -> Void)? = nil

  @Environment(PromoteFlashStore.self) private var promoteFlash
  @Environment(DayClock.self) private var clock

  /// Settings ▸ Tasks ▸ Rows ▸ "Title lines". iPhone/iPad only — the macOS
  /// AppKit list is a fixed-height table whose titles truncate by design, and
  /// the SwiftUI Mac rows sit in the same dense list, so both stay at two.
  @AppStorage(SettingsKey.tasksTitleLines) private var titleLinesSetting: Int = 2

  private var titleLineLimit: Int {
    #if os(iOS)
    return min(3, max(1, titleLinesSetting))
    #else
    return 2
    #endif
  }

  private var todayAnchor: Date {
    Calendar.current.startOfDay(for: SeptenaDate.parse(clock.today) ?? clock.now)
  }

  private var isInactive: Bool {
    task.status == .done || task.status == .cancelled
  }
  private var hasNotes: Bool {
    !(task.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Project wins over area (a task in a project implies its area), each
  /// honoring its suppression flag. Mirrors the old `TaskListView.metaLine`.
  private var subtitle: String? {
    if !suppressProject, let pid = task.project,
       let p = projects.first(where: { $0.id == pid }) { return p.title }
    if !suppressArea, let aid = task.area,
       let a = areas.first(where: { $0.id == aid }) { return a.title }
    return nil
  }

  var body: some View {
    // The box is derived once, in `TaskCheckboxModel`, shared with the inline
    // editor's checkbox so view-row and edit-row can't drift.
    let box = TaskCheckboxModel(task: task, accent: accent,
                                showsTodayIndicator: showsTodayIndicator,
                                showsFadedIndicator: showsFadedIndicator)
    return CheckableRow(
      tint: box.tint,
      isDone: box.isDone,
      isToday: box.isToday,
      dashed: box.dashed,
      cornerDot: box.cornerDot,
      tenureFill: box.tenureFill,
      isInactive: isInactive,
      title: task.title,
      showsNotesGlyph: hasNotes,
      subtitle: subtitle,
      // Pin the title box to the checkbox band so it matches the inline editor's
      // field (closest reliable view↔edit match). Normal rows already stand at
      // this height (the checkbox sets it), so nothing visibly changes here.
      titleBandHeight: Theme.checkboxTap,
      titleLineLimit: titleLineLimit,
      isSelected: isSelected,
      isListSelected: isListSelected,
      checkboxDimmed: checkboxDimmed,
      promoteFlashTrigger: promoteFlash.trigger(for: task.id),
      titleMatchID: titleMatchID,
      checkboxMatchID: checkboxMatchID,
      heroMatchNS: heroMatchNS,
      heroMatchIsSource: heroMatchIsSource,
      trailing: { trailing },
      onToggle: onToggle,
      onTap: onTap
    )
  }

  /// The task the trailing cluster draws: a just-checked row draws the cluster
  /// it had while open (`isSettling`).
  private var trailingTask: SeptenaTask {
    guard isSettling, task.status == .done else { return task }
    var open = task
    open.status = .open
    return open
  }

  // Right-side order (left → right): variable-width elements inboard, fixed-width
  // pinned to the right edge so the row's right margin stays stable.
  //   accessory (Inbox "file here") · date  →  recurrence · reference · notes · status-dot
  // Accessory and date flex with their content; recurrence / reference / notes /
  // agent glyphs are fixed and anchor the trailing edge.
  @ViewBuilder private var trailing: some View {
    let task = trailingTask
    if let accessory { accessory }
    if showsFadedIndicator && task.isFaded {
      TaskStatusPill(symbol: "circle.dashed",
                     title: TaskFilter.faded.title)
    } else if showsTodayIndicator && task.isOnToday && task.status == .open && task.deletedAt == nil && !task.isFaded {
      TaskStatusPill(symbol: "sun.max.fill",
                     title: TaskFilter.today.title)
    }
    // "Waiting on Anna · 5 days" (docs/REVIEW_SPEC.md §6).
    if task.status == .open, task.deletedAt == nil, let waiting = task.waitingLabel(today: clock.today) {
      TaskStatusPill(symbol: RegistryIcons.sfSymbol(for: "action.waiting"), title: waiting)
    }
    if let name = SharedProjects.assigneeName(of: task, in: LocalStore.shared.container.mainContext) {
      TaskStatusPill(symbol: RegistryIcons.sfSymbol(for: "action.assign"), title: name)
    }
    trailingDate
    if task.status == .open, task.deletedAt == nil,
       let slot = task.timeSlotLabel {
      HStack(spacing: 3) {
        Image(systemName: "clock")
          .scaledFont(size: 11)
        Text(slot)
          .font(.septenaMeta)
      }
      .foregroundStyle(Theme.inkSecondary)
      .accessibilityLabel(String(localized: "Scheduled time \(slot)", comment: "Task row time slot a11y"))
    }
    if let summary = checklistSummary, summary.total > 0 {
      HStack(spacing: 3) {
        Image(systemName: "checklist")
          .scaledFont(size: 11)
        Text("\(summary.done)/\(summary.total)")
          .font(.septenaMeta)
      }
      .foregroundStyle(Theme.inkSecondary)
      .accessibilityLabel(String(localized: "\(summary.done) of \(summary.total) checklist items complete",
                                 comment: "Task row checklist progress a11y"))
    }
    if !tagChips.isEmpty {
      let visibleLimit = 2
      let shown = Array(tagChips.prefix(visibleLimit))
      let overflow = max(0, tagChips.count - visibleLimit)
      HStack(spacing: 4) {
        ForEach(shown) { tag in
          HStack(spacing: 3) {
            if tag.color != nil {
              Circle()
                .fill(TagColorPalette.color(for: tag.color))
                .frame(width: 5, height: 5)
            }
            Text(tag.name)
              .font(.septenaCaption)
              .lineLimit(1)
          }
          .foregroundStyle(Theme.inkSecondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .overlay(
            Capsule().strokeBorder(Theme.inkSecondary.opacity(0.28), lineWidth: 0.75)
          )
        }
        if overflow > 0 {
          Text("+\(overflow)")
            .font(.septenaCaption)
            .foregroundStyle(Theme.inkSecondary)
        }
      }
      .accessibilityLabel(Text(tagChips.map(\.name).joined(separator: ", ")))
    }
    if task.status == .open, task.deletedAt == nil,
       let badge = task.reminder?.badgeText() {
      HStack(spacing: 3) {
        Image(systemName: "bell.fill")
          .scaledFont(size: 11)
        Text(badge.text)
          .font(.septenaMeta)
      }
      .foregroundStyle(badge.isPastDue ? Theme.overdueRed : Theme.inkSecondary)
      .accessibilityLabel(String(localized: "Reminder \(badge.text)", comment: "Task row reminder a11y"))
    }
    if task.recurrence != nil {
      Image(systemName: "arrow.clockwise")
        .scaledFont(size: 12)
        .foregroundStyle(Theme.inkSecondary)
        .accessibilityLabel(TaskA11y.recurring)
    }
    if task.starred {
      Image(systemName: RegistryIcons.sfSymbol(for: "action.star", on: true))
        .scaledFont(size: 11)
        .foregroundStyle(Theme.todayAccent)
        .accessibilityLabel(TaskFilter.starred.title)
    }
    if let fromKind {
      Image(systemName: fromKind.sfSymbol)
        .scaledFont(size: 11)
        .foregroundStyle(Theme.inkSecondary)
        .accessibilityLabel(RegistryTaskReferences.createdFrom(name: fromKind.label))
    }
    // An agent-authored row carries its notes as the agent's write-up, so the
    // agent glyph already says "there is more here". One glyph, not two.
    if hasNotes, !task.isAgentAuthored { TaskNotesGlyph.view }
    if task.isAgentAuthored { AgentAuthoredGlyph(task: task) }
    agentSignal
  }

  /// The single trailing signal dot, in priority order: a live conversation's
  /// status badge wins; absent that, the calm "unseen" cue for a Claude-created
  /// row the user hasn't engaged yet; absent that, the "arrived in Today on its
  /// own" cue for a future-dated plan whose day just came. Mutually exclusive —
  /// the row never shows two dots, and the cue rides the same right edge as
  /// every other row glyph. The `hasStarted && badge != nil` guard mirrors
  /// `ConvoBadgeView`'s own, so when it wins the badge always renders.
  @ViewBuilder private var agentSignal: some View {
    if TaskRowFlags.languageV2 {
      // Language v2: the agent signal rides the LEFT box — dashed = proposal,
      // corner dot = unread context. "Arrived in Today on its own" is now an
      // amber checkbox (Things-style "new on Today"), not a right-edge dot, so
      // the trailing edge carries nothing for these states.
      EmptyView()
    } else if task.conversation.hasStarted, deriveConvo(task.conversation).badge != nil {
      ConvoBadgeView(convo: task.conversation)
    } else if task.showsAgentCue() {
      AgentCueMarker(tint: accent)
    } else if task.showsArrivedToday() {
      // The "rolled into Today on its own" cue wears the Today accent (yellow),
      // not the section accent — it's a Today signal, matching the checkbox's
      // promoted-to-Today color.
      ArrivedTodayMarker(tint: Theme.todayAccent)
    }
  }

  /// Date treatment, lifted from the old `TaskListView.trailingDate`:
  ///   • `due ≤ today` → red bold date (`Today` / `May 14`).
  ///   • `due > today` → gray flag + date (marked, not urgent).
  ///   • no `due`, scheduled, not a Today surface → muted calendar + date.
  @ViewBuilder private var trailingDate: some View {
    let task = trailingTask
    let cal = Calendar.current
    let today = todayAnchor
    // Completed tasks show WHEN they were done (the Completed view reads as a
    // dated archive); dropped tasks carry a distinct "Let go" label
    // (`docs/TASK_FADE_SPEC.md` §5).
    if task.status == .done, let done = task.completedAt.flatMap({ SeptenaDate.parse(String($0.prefix(10))) }) {
      HStack(spacing: 4) {
        Image(systemName: "checkmark").scaledFont(size: 11)
        Text(Self.shortDate(done)).font(.septenaMeta)
      }
      .foregroundStyle(Theme.inkSecondary)
    } else if task.status == .cancelled {
      let label = task.dropReason != nil
        ? String(localized: "Let go", comment: "Logbook label for dropped task")
        : String(localized: "Cancelled", comment: "Logbook label for cancelled task")
      let dateText = task.completedAt.flatMap { SeptenaDate.parse(String($0.prefix(10))) }.map(Self.shortDate)
      Text(dateText.map { "\(label) · \($0)" } ?? label)
        .font(.septenaMeta)
        .foregroundStyle(Theme.inkSecondary)
    } else if let due = task.deadline.flatMap(SeptenaDate.parse) {
      // `docs/TASK_DATES_SPEC.md` R3 / R4: due today and overdue are both
      // red; the label says which.
      switch task.deadlineState(today: SeptenaDate.format(today) ?? SeptenaDate.today) {
      case .dueToday:
        Text(String(localized: "Today", comment: "Deadline label: due today"))
          .font(.septenaMeta.weight(.semibold))
          .foregroundStyle(Theme.overdueRed)
      case .overdue:
        Text(RegistrySurfaces.taskDateBoardOverdueLabel)
          .font(.septenaMeta.weight(.semibold))
          .foregroundStyle(Theme.overdueRed)
      case .none, .later:
        HStack(spacing: 4) {
          Image(systemName: "flag.fill").scaledFont(size: 12)
          Text(Self.shortDate(due)).font(.septenaMeta)
        }
        .foregroundStyle(Theme.inkSecondary)
      }
    } else if let scheduled = task.scheduled.flatMap(SeptenaDate.parse) {
      let schedDay = cal.startOfDay(for: scheduled)
      // On Today / Next, past/today When dates are noise (the row is already
      // on Today). On off-Today surfaces, when the Today pill is shown for an
      // on-Today task, skip repeating today/past When dates beside it.
      let coveredByTodayPill = showsTodayIndicator && task.isOnToday && task.status == .open && task.deletedAt == nil && !task.isFaded && schedDay <= today
      if !coveredByTodayPill && (showsTodayIndicator || schedDay > today) {
        HStack(spacing: 4) {
          Image(systemName: "calendar").scaledFont(size: 11)
          Text(Self.shortDate(scheduled)).font(.septenaMeta)
        }
        .foregroundStyle(Theme.inkSecondary)
      }
    }
  }

  static func shortDate(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return RegistrySurfaces.tomorrowLabel }
    return SeptenaDate.monthDay(d)
  }
}

/// Quiet read-only status pill (`☀ Today`, `◌ Faded`) on the trailing edge of
/// an off-Today / project task row. Uses OS 26/27 frosted Liquid Glass capsule
/// material (falling back to solid `mutedSurface` under Reduce Transparency).
private struct TaskStatusPill: View {
  let symbol: String
  let title: String
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: symbol)
        .scaledFont(size: 10)
      Text(title)
        .font(.septenaMetaSmall)
    }
    .foregroundStyle(Theme.inkSecondary)
    .padding(.horizontal, 7)
    .padding(.vertical, 2.5)
    .modifier(RowGlassPillSurface(reduceTransparency: reduceTransparency))
    .accessibilityLabel(title)
  }
}

/// Shared OS 26/27 frosted glass capsule fill for neutral row pills/badges.
private struct RowGlassPillSurface: ViewModifier {
  let reduceTransparency: Bool

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(Theme.mutedSurface, in: Capsule())
    } else {
      #if os(iOS)
      content
        .background(.ultraThinMaterial, in: Capsule())
        .glassEffect(.regular, in: .capsule)
      #else
      content
        .background(.thinMaterial, in: Capsule())
        .overlay(
          Capsule()
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
      #endif
    }
  }
}

// MARK: - Screen title

struct ScreenTitle: View {
  let icon: String
  let iconTint: Color
  let title: String

  var body: some View {
    // Shares the list's leading grid with `ScreenTitleMenuLabel`: the icon
    // rides the same `checkboxTap` column (parked at `headerLeading`, nudged
    // like every row checkbox and section-header glyph) and the title lands
    // one `iconTextGap` past it, so toggling the sidebar never shifts the
    // title horizontally.
    HStack(spacing: Theme.iconTextGap) {
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(iconTint)
        .frame(width: Theme.checkboxTap, alignment: .center)
        .offset(x: -Theme.checkboxLeadingNudge)
      Text(title)
        .font(.septenaScreenTitle)
        .foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, TaskCardMetrics.headerLeading)
    .padding(.trailing, TaskCardMetrics.margin)
    .padding(.top, 12)
    .padding(.bottom, 18)
  }
}


// MARK: - Week strip

/// Which 7-day window a `WeekStrip` covers.
enum WeekStripRange {
  /// Today + the next 6 days, today FIRST. The scheduling default
  /// (When / Deadline). Today is a cell of the strip, not a separate row above
  /// it: one control, one axis, and the leading cell is the answer people pick
  /// most. (It was the other way round — a Today row over a strip that started
  /// tomorrow — until the two shapes were collapsed into one.)
  case upcoming
  /// The previous 6 days + today, with today rightmost. Used by the
  /// drawer time-travel picker, where you look *back* at past logs.
  case recent
}

/// Lean 7-day strip: today + the next 6 days as Reminders-style chips
/// (weekday on top, day number below). One tap = one pick.
/// Used by both the When and Deadline pickers so quick scheduling
/// within the coming week never opens a full calendar.
///
/// The leading cell of `.upcoming` is TODAY, and its weekday line reads
/// "Today" rather than the weekday name — it carries the word the separate
/// Today row used to carry.
struct WeekStrip: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  /// Currently-selected day (start-of-day), or nil for none.
  let selected: Date?
  /// Window the strip spans. Defaults to `.upcoming` so existing
  /// scheduling callers are unaffected.
  var range: WeekStripRange = .upcoming
  let onPick: (Date) -> Void

  private static let cal = Calendar.current
  private static let weekdayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEE"; return f   // Sun … Sat
  }()

  private var anchorDay: Date {
    Self.cal.startOfDay(for: SeptenaDate.parse(clock.today) ?? clock.now)
  }

  private var days: [Date] {
    let today = anchorDay
    switch range {
    case .upcoming:
      return (0...6).compactMap { Self.cal.date(byAdding: .day, value: $0, to: today) }
    case .recent:
      return (-6...0).compactMap { Self.cal.date(byAdding: .day, value: $0, to: today) }
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      ForEach(days, id: \.self) { d in
        let isSelected = selected.map { Self.cal.isDate($0, inSameDayAs: d) } ?? false
        let isToday = Self.cal.isDate(d, inSameDayAs: anchorDay)
        let isWeekend = Self.cal.isDateInWeekend(d)
        Button {
          Haptics.selection()
          onPick(Self.cal.startOfDay(for: d))
        } label: {
          // Selection reuses the canonical chip fill/ink (SelectionLanguage).
          // This used to paint a SOLID `theme.accent` with white text — and
          // `theme.accent` is the app's adaptive ink, which is WHITE in dark
          // mode, so the selected day rendered white-on-white and vanished.
          // A wash plus matching ink is contrast-safe in both appearances; the
          // selected day is then separated from "today" by a full-weight
          // stroke rather than by fill strength alone.
          VStack(spacing: 2) {
            Text(isToday
                 ? String(localized: "Today", comment: "Relative date")
                 : Self.weekdayFmt.string(from: d))
              .scaledFont(size: 11, weight: .medium)
              .lineLimit(1)
              .minimumScaleFactor(0.7)
              .foregroundStyle(isSelected ? theme.accent : Theme.inkSecondary)
            Text("\(Self.cal.component(.day, from: d))")
              .scaledFont(size: 17, weight: .semibold, design: .rounded)
              .foregroundStyle(isSelected || isToday ? theme.accent : Theme.inkPrimary)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(isSelected
                    ? SelectableChipStyle.fill(tint: theme.accent, isSelected: true)
                    : (isToday ? theme.accent.opacity(0.12)
                       : (isWeekend ? Theme.inkSecondary.opacity(0.09) : Color.clear)))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(isSelected ? theme.accent
                            : Theme.inkSecondary.opacity(0.18),
                            lineWidth: isSelected ? 1.5 : 0.5)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - Task date board

/// THE date board for tasks — one component, every task date surface.
///
/// Shape, in order: a **seven-day strip starting TODAY**, then the rows from
/// the registry (`RegistrySurfaces.dateBoardRows`) in three groups: pick (the
/// strip and Pick another date, Apple's month calendar for anything further
/// out), refine (Add time, Repeat; When only) and remove (Clear). A hairline
/// separates the groups. Every row is a `TaskDateBoardRow`.
/// It is the SwiftUI twin of the AppKit shell's ⌘S / ⌘⇧D popover
/// (`Septask/SeptaskKitDatePopover.swift`), so When and Deadline ask the
/// question the same way in both apps.
///
/// Today is the strip's FIRST CELL, not a row above it. The board used to
/// carry both — a Today row over a strip that started tomorrow — which asked
/// one question (which day?) with two controls in two vocabularies. One strip
/// answers it on one axis, and the cell people pick most is the leading one.
/// Tomorrow is a strip cell only. It was also a row (2026-11-24), but the
/// duplicate made the board read as an unordered list (mz, 2026-11-26).
///
/// Every control commits on the spot — there is no confirm button.
///
/// The caller decides what "Today" means. `.when` treats it as the today FLAG
/// (`onToday`), Deadline as an ordinary date — the board only reports the
/// gesture.
struct TaskDateBoard: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  /// Which attribute the board edits. The registry picks the rows for it.
  let attribute: RegistryDateBoardAttribute
  /// The dated value the board should show as chosen, or nil for none.
  let selected: Date?
  /// Whether the Today row itself is the current value.
  var todayActive: Bool = false
  /// When only: the Repeat row's title ("Repeat…" / "Repeat: Every week").
  /// The row hides when nil. Repeat is set where the date is set
  /// (docs/TASK_ROW_MENU_SPEC.md).
  var repeatLabel: String? = nil
  var onRepeat: (() -> Void)? = nil
  /// When only: opens the time controls. The row hides when nil.
  var onAddTime: (() -> Void)? = nil
  let onToday: () -> Void
  let onPick: (Date) -> Void
  let onClear: () -> Void

  @State private var calendarDate = Date()
  @State private var showingCalendar = false
  /// On the task page the board is embedded in its card, so the month
  /// calendar opens under the button instead of in a popover.
  @Environment(\.taskPickerEmbedding) private var embedding

  private var cal: Calendar { Calendar.current }
  private var anchorDay: Date {
    cal.startOfDay(for: SeptenaDate.parse(clock.today) ?? clock.now)
  }

  var body: some View {
    VStack(spacing: 0) {
      // `todayActive` is the today FLAG, which carries no date — the strip
      // takes a date, so map the flag onto today's cell here.
      WeekStrip(selected: selected ?? (todayActive ? anchorDay : nil)) { d in
        let day = cal.startOfDay(for: d)
        // Today's cell reports the Today GESTURE, so `.when` can keep writing
        // the flag rather than a dated schedule.
        if cal.isDate(day, inSameDayAs: anchorDay) { onToday() } else { onPick(day) }
      }
      .padding(.top, 4)
      .padding(.bottom, 6)

      VStack(spacing: 0) {
        ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
          // The strip opens the first group, so a divider goes only where
          // the group changes.
          let previous = index == 0 ? RegistryDateBoardGroup.pick : visibleRows[index - 1].group
          if row.group != previous {
            Hairline(leadingInset: 0)
              .padding(.vertical, 4)
          }
          boardRow(row)
        }
      }
    }
  }

  /// The registry rows this board can act on. A group with no rows draws no
  /// divider, so the filter runs before the dividers are placed.
  private var visibleRows: [RegistryDateBoardRow] {
    RegistrySurfaces.dateBoardRows(for: attribute, on: RegistryPlatform.current).filter { row in
      switch row.kind {
      case .repeatRule: return repeatLabel != nil && onRepeat != nil
      case .time: return onAddTime != nil
      case .calendar, .clear: return true
      }
    }
  }

  @ViewBuilder
  private func boardRow(_ row: RegistryDateBoardRow) -> some View {
    switch row.kind {
    case .calendar:
      calendarRow(row)
      if embedding != nil && showingCalendar {
        calendar
          .padding(.bottom, 8)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    case .clear:
      TaskDateBoardRow(symbol: row.sfSymbol, title: row.label(for: attribute)) {
        Haptics.commit()
        onClear()
      }
    case .repeatRule:
      if let repeatLabel, let onRepeat {
        TaskDateBoardRow(symbol: row.sfSymbol, title: repeatLabel) {
          Haptics.press()
          onRepeat()
        }
      }
    case .time:
      if let onAddTime {
        TaskDateBoardRow(symbol: row.sfSymbol, title: row.label(for: attribute)) {
          Haptics.press()
          onAddTime()
        }
      }
    }
  }

  /// A value past the strip. The calendar row names it, so the board always
  /// shows what the task has now.
  private var dateBeyondStrip: Date? {
    guard let selected else { return nil }
    let days = cal.dateComponents([.day], from: anchorDay, to: cal.startOfDay(for: selected)).day ?? 0
    return (0...6).contains(days) ? nil : selected
  }

  /// The "further out" path. The strip already covers the coming week, so the
  /// month calendar hides behind one tap — popover on iPad/Mac, small sheet on
  /// iPhone — and picking a day there commits it, like every other control.
  private func calendarRow(_ row: RegistryDateBoardRow) -> some View {
    TaskDateBoardRow(
      symbol: row.sfSymbol,
      title: dateBeyondStrip.map {
        RegistrySurfaces.dateBoardCalendarLabel(
          date: $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
      } ?? row.label(for: attribute),
      active: dateBeyondStrip != nil
    ) {
      Haptics.press()
      calendarDate = selected ?? anchorDay
      a11yAnimate(.snappy(duration: 0.22)) { showingCalendar.toggle() }
    }
    .popover(isPresented: Binding(get: { embedding == nil && showingCalendar },
                                  set: { showingCalendar = $0 })) {
      calendar
        .padding(8)
        .frame(minWidth: 300, idealWidth: 320, minHeight: 360)
        .presentationDetents([.medium])
        .presentationCompactAdaptation(.sheet)
    }
  }

  /// The month calendar: in the popover from a sheet, inline on the task page.
  private var calendar: some View {
      VStack(spacing: 8) {
        DatePicker("", selection: $calendarDate, displayedComponents: [.date])
          .datePickerStyle(.graphical)
          .labelsHidden()
          .tint(theme.accent)
          // Commit only when the user picks a DAY. Paging the month or using
          // the month/year wheel also rewrites the bound date (same day number,
          // other month), and committing that closed the calendar mid-browse.
          .onChange(of: calendarDate) { old, new in
            guard cal.component(.day, from: old) != cal.component(.day, from: new)
            else { return }
            commitCalendarDate()
          }
        // The one case the day compare can't see: after browsing to another
        // month, picking the SAME day number changes nothing. This commits
        // whatever is shown.
        Button("Set Date") { commitCalendarDate() }
          .buttonStyle(.borderless)
          .tint(theme.accent)
      }
  }

  private func commitCalendarDate() {
    showingCalendar = false
    onPick(cal.startOfDay(for: calendarDate))
  }
}

/// One full-width row of the date board — symbol, then title. The AppKit
/// board's row shape, wearing the inset palette highlight when it holds the
/// current value. `.contentShape` is required: a `.plain` button is only
/// tappable where it draws, so without it the trailing half of the row is a
/// dead zone.
struct TaskDateBoardRow: View {
  /// The When sheet's time controls line up with the rows' symbol and title.
  static let horizontalPadding: CGFloat = 10
  static let verticalPadding: CGFloat = 12

  let symbol: String
  let title: String
  var active: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 0) {
        TaskDateBoardRowLabel(symbol: symbol, title: title)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Self.horizontalPadding)
      .padding(.vertical, Self.verticalPadding)
      .contentShape(Rectangle())
      .background(InsetSelectionBackground(isSelected: active, horizontalInset: 0))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(active ? .isSelected : [])
  }
}

/// A row's symbol and title, shared with the open time controls.
struct TaskDateBoardRowLabel: View {
  let symbol: String
  let title: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .scaledFont(size: 17)
        .foregroundStyle(Theme.inkSecondary)
        .frame(width: 22)
      Text(title)
        .scaledFont(size: 16)
        .foregroundStyle(Theme.inkPrimary)
        .lineLimit(1)
    }
  }
}

// MARK: - Paper-themed action sheet
//
// iOS Menu pops with system materials (translucent gray) and can't be
// re-themed. For action lists ("Cancel / Delete") we want
// the same warm-paper surface as the rest of the app, so we present a
// custom bottom sheet of action rows instead of a Menu.

struct ActionSheet: View {
  struct Action: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var role: ButtonRole? = nil          // .destructive renders red
    /// When true, renders a trailing checkmark in the section accent — used
    /// for sort-mode rows where one of N is the current selection.
    var selected: Bool = false
    let perform: () -> Void
  }

  let title: String?
  let actions: [Action]
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      if let title {
        Text(title)
          .font(.septenaSectionTitle)
          .foregroundStyle(Theme.inkPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Theme.hPadding)
          .padding(.top, 18)
          .padding(.bottom, 8)
        Hairline()
      }

      ForEach(actions) { action in
        Button {
          action.perform()
          dismiss()
        } label: {
          HStack(spacing: 14) {
            Image(systemName: action.icon)
              .scaledFont(size: 16)
              .foregroundStyle(action.role == .destructive ? Theme.overdueRed : Theme.inkSecondary)
              .frame(width: 22)
            Text(action.title)
              .font(.septenaSidebarRow)
              .foregroundStyle(action.role == .destructive ? Theme.overdueRed : Theme.inkPrimary)
            Spacer()
            if action.selected {
              Image(systemName: "checkmark")
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(theme.accent)
            }
          }
          .padding(.horizontal, Theme.hPadding)
          .frame(height: Theme.sidebarRowHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(PlainHoverRowButtonStyle())
        Hairline()
      }

      Button("Cancel") { dismiss() }
        .font(.septenaButton)
        .foregroundStyle(theme.accent)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Theme.paperBackground.ignoresSafeArea())
  }
}

// MARK: - Hairline divider

struct Hairline: View {
  var leadingInset: CGFloat = Theme.hPadding
  var body: some View {
    Rectangle()
      .fill(Theme.divider)
      .frame(height: 0.5)
      .padding(.leading, leadingInset)
  }
}
