import SwiftUI
import UniformTypeIdentifiers

// MARK: - Task drag payload (sidebar re-home + in-list reorder)

/// Drag payload for re-homing one or more tasks onto a sidebar destination,
/// or reordering them within a manually-ordered list (`TaskReorderDrop`).
struct TaskDragIDs: Codable, Hashable, Transferable {
  let ids: [String]

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .septenaTaskDragIDs)
  }
}

extension UTType {
  static let septenaTaskDragIDs = UTType(exportedAs: "com.septena.task-drag-ids")
}

/// Row-level reorder target for manually-ordered lists — the in-list
/// counterpart of the sidebar's `SidebarTaskDrop`, same `TaskDragIDs`
/// payload. While a drag hovers, the row parts an animated gap on the side
/// the drop would land (top half = insert above, bottom half = below) —
/// pushing the rows beneath out of the way — with an accent insertion line
/// in the opening. `perform` is nil on rows that aren't reorderable
/// (date/tier-sorted lists), which makes the modifier a pass-through.
///
/// Uses `onDrop(of:delegate:)` rather than `.dropDestination` deliberately:
/// only `DropDelegate.dropUpdated` exposes the hover location live (needed
/// for the insertion side) and the drop proposal (`.move`, so the cursor
/// doesn't wear the green copy badge).
struct TaskReorderDrop: ViewModifier {
  static let gapHeight: CGFloat = 14

  let perform: ((_ ids: [String], _ before: Bool) -> Bool)?
  /// nil = no drag hovering; true = would insert above this row; false = below.
  @State private var hoverBefore: Bool? = nil
  @State private var rowHeight: CGFloat = 0

  func body(content: Content) -> some View {
    if let perform {
      content
        // Height of the un-parted row — captured before the gap padding so
        // the delegate's midline compare doesn't shift when the gap opens.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeight = $0 }
        .padding(.top, hoverBefore == true ? Self.gapHeight : 0)
        .padding(.bottom, hoverBefore == false ? Self.gapHeight : 0)
        .overlay(alignment: .top) { if hoverBefore == true { insertionLine } }
        .overlay(alignment: .bottom) { if hoverBefore == false { insertionLine } }
        .a11yAnimation(.easeOut(duration: 0.14), value: hoverBefore)
        .onDrop(of: [.septenaTaskDragIDs],
                delegate: TaskReorderDropDelegate(hoverBefore: $hoverBefore,
                                                  rowHeight: { rowHeight },
                                                  perform: perform))
    } else {
      content
    }
  }

  /// A 3pt accent capsule centered in the parted gap.
  private var insertionLine: some View {
    Capsule()
      .fill(Color.accentColor)
      .frame(height: 3)
      .padding(.horizontal, 20)
      .frame(height: Self.gapHeight)
  }
}

private struct TaskReorderDropDelegate: DropDelegate {
  @Binding var hoverBefore: Bool?
  let rowHeight: () -> CGFloat
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

  /// Which side of the row the pointer is on. The open gap pads the content
  /// down, so subtract it before the midline compare; the flip then moves the
  /// content *away* from the pointer, so the side is hysteresis-stable (no
  /// flicker at the midline).
  private func update(_ info: DropInfo) {
    let adjusted = info.location.y - (hoverBefore == true ? TaskReorderDrop.gapHeight : 0)
    hoverBefore = adjusted < rowHeight() / 2
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

struct CheckableRow<Trailing: View>: View {
  var tint: Color
  var isDone: Bool
  var isToday: Bool = false
  /// Readiness form (language v2) forwarded to `TaskCheckbox`: dashed = proposal,
  /// `cornerDot` = unread-context marker on a committed task.
  var dashed: Bool = false
  var cornerDot: Color? = nil
  /// Forwarded to `TaskCheckbox`: fill (0…1) for the Today tenure dial, or nil.
  var tenureFill: Double? = nil
  /// The checkbox celebration this row plays on check (see `CheckFeel`).
  /// Standardized to the default `.stamp` across every checkable row.
  var feel: CheckFeel = .stamp
  /// Strikethrough + dimmed title. Usually `isDone`, but habits fold in
  /// skipped and chores fold in deferred, so the caller decides.
  var isInactive: Bool
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
  /// `Text` and the OPEN inline editor's `TextField` occupy an IDENTICAL,
  /// centered box on the same checkbox line — the closest reliable match between
  /// the two (they still differ sub-pixel; baseline alignment was worse because
  /// SwiftUI mis-reports a vertical-axis field's baseline). nil (non-task rows)
  /// keeps the intrinsic height. See `TaskComposerCard.titleField`.
  var titleBandHeight: CGFloat? = nil
  /// Neutral selection capsule while this row's detail/edit modal is open
  /// (drawer surfaces — the deep list paints via `listRowBackground` instead).
  var isSelected: Bool = false
  /// Native `List(selection:)` cursor — keep title ink dark on the gray capsule.
  var isListSelected: Bool = false
  /// Rising-edge counter from `PromoteFlashStore` — plays a brief amber row wash.
  var promoteFlashTrigger: Int = 0
  /// Optional hero-animation anchors (`matchedGeometryEffect`): the Things-style
  /// inline editor reuses the same id + namespace on ITS title and checkbox, so
  /// on expand/collapse they GLIDE between the closed row and the open editor
  /// instead of cross-fading into a new position. Shared namespace, distinct
  /// ids. Nil everywhere else.
  var titleMatchID: String? = nil
  var checkboxMatchID: String? = nil
  var heroMatchNS: Namespace.ID? = nil
  /// Which endpoint of the hero glide is the `matchedGeometryEffect` source.
  /// Closed row and open editor must never both be `true` during a transition.
  var heroMatchIsSource: Bool = true
  @ViewBuilder var trailing: () -> Trailing
  let onToggle: () -> Void
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
      .lineLimit(2)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .matchedHeroGeometry(titleMatchID, heroMatchNS, isSource: heroMatchIsSource)
      .accessibilityLabel(TaskA11y.rowLabel(title: title, hasNotes: showsNotesGlyph, isHeading: false))
  }

  var body: some View {
    HStack(alignment: .rowTitleCenter, spacing: Theme.iconTextGap) {
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
      .alignmentGuide(.rowTitleCenter) { d in d[VerticalAlignment.center] }

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

      trailing()
    }
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

extension CheckableRow where Trailing == EmptyView {
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

  init(task: SeptenaTask, accent: Color, showsTodayIndicator: Bool) {
    // A volunteered, still-unratified agent proposal — the dashed "not a task
    // yet" form. Human captures stay solid; only MCP triage-band rows read so.
    let isProposal = task.isInTriageBand && task.source == TaskSource.mcp
    tint = accent
    isDone = task.status == .done
    isToday = task.isOnToday && showsTodayIndicator
    dashed = TaskRowFlags.languageV2 && isProposal
    // Accent corner dot for a committed task carrying unread agent context.
    // Proposals are excluded (they already read as dashed).
    cornerDot = {
      guard TaskRowFlags.languageV2, !isProposal else { return nil }
      if task.conversation.hasStarted, deriveConvo(task.conversation).badge != nil { return accent }
      return nil
    }()
    tenureFill = TaskRowFlags.agingEnabled ? task.todayTenureFill() : nil
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
  /// Show the "promoted to Today" accent in the checkbox, and the scheduled
  /// date in the trailing. Pass `false` on Today / Next surfaces (where every
  /// row is already today, so both are noise).
  var showsTodayIndicator: Bool = true
  /// Highlight this row while its edit modal is open (see `CheckableRow`).
  var isSelected: Bool = false
  /// Native `List(selection:)` cursor on the deep task list.
  var isListSelected: Bool = false
  /// Optional inboard-most trailing accessory — the deep list passes the Inbox
  /// "file here" capsule here so it sits left of the date (a variable-width
  /// element kept inboard of the fixed glyphs). Nil on every other surface.
  var accessory: AnyView? = nil
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
                                showsTodayIndicator: showsTodayIndicator)
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
      isSelected: isSelected,
      isListSelected: isListSelected,
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

  // Right-side order (left → right): variable-width elements inboard, fixed-width
  // pinned to the right edge so the row's right margin stays stable.
  //   accessory (Inbox "file here") · date  →  recurrence · notes · status-dot
  // Accessory and date flex with their content; recurrence / notes / agent
  // glyphs are fixed and anchor the trailing edge.
  @ViewBuilder private var trailing: some View {
    if let accessory { accessory }
    trailingDate
    if task.recurrence != nil {
      Image(systemName: "arrow.clockwise")
        .scaledFont(size: 12)
        .foregroundStyle(Theme.inkSecondary)
        .accessibilityLabel(TaskA11y.recurring)
    }
    if hasNotes { TaskNotesGlyph.view }
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
    let cal = Calendar.current
    let today = todayAnchor
    // Completed tasks show WHEN they were done (the Completed view reads as a
    // dated archive); the date prefix strips the time off `completedAt`.
    if task.status == .done, let done = task.completedAt.flatMap({ SeptenaDate.parse(String($0.prefix(10))) }) {
      HStack(spacing: 4) {
        Image(systemName: "checkmark").scaledFont(size: 11)
        Text(Self.shortDate(done)).font(.septenaMeta)
      }
      .foregroundStyle(Theme.inkSecondary)
    } else if let due = task.deadline.flatMap(SeptenaDate.parse) {
      let dueDay = cal.startOfDay(for: due)
      if dueDay <= today {
        Text(cal.isDateInToday(due) ? "Today" : Self.shortDate(due))
          .font(.septenaMeta.weight(.semibold))
          .foregroundStyle(Theme.overdueRed)
      } else {
        HStack(spacing: 4) {
          Image(systemName: "flag.fill").scaledFont(size: 12)
          Text(Self.shortDate(due)).font(.septenaMeta)
        }
        .foregroundStyle(Theme.inkSecondary)
      }
    } else if let scheduled = task.scheduled.flatMap(SeptenaDate.parse) {
      let schedDay = cal.startOfDay(for: scheduled)
      // On Today / Next, past/today When dates are noise (the row is already
      // on Today) — but a future When date should still read (sort + label).
      if showsTodayIndicator || schedDay > today {
        HStack(spacing: 4) {
          Image(systemName: "calendar").scaledFont(size: 11)
          Text(Self.shortDate(scheduled)).font(.septenaMeta)
        }
        .foregroundStyle(Theme.inkSecondary)
      }
    }
    // Language v2: an on-Today task seen on an off-Today surface is signalled by
    // the amber checkbox (see `boxStrokeColor`), not a right-edge "Today" chip.
  }

  private static func shortDate(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f.string(from: d)
  }
}

// MARK: - Screen title

struct ScreenTitle: View {
  let icon: String
  let iconTint: Color
  let title: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(iconTint)
      Text(title)
        .font(.septenaScreenTitle)
        .foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Theme.hPadding)
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
          Haptics.pick()
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
/// Shape, in order: a **seven-day strip starting TODAY**, **Pick another
/// date** (Apple's month calendar, for anything further out), and **Clear**.
/// It is the SwiftUI twin of the AppKit shell's ⌘S / ⌘⇧D popover
/// (`Septask/SeptaskKitDatePopover.swift`), so When and Deadline ask the
/// question the same way in both apps.
///
/// Today is the strip's FIRST CELL, not a row above it. The board used to
/// carry both — a Today row over a strip that started tomorrow — which asked
/// one question (which day?) with two controls in two vocabularies. One strip
/// answers it on one axis, and the cell people pick most is the leading one.
///
/// Every control commits on the spot — there is no confirm button.
///
/// The caller decides what "Today" means. `.when` treats it as the today FLAG
/// (`onToday`), Deadline as an ordinary date — the board only reports the
/// gesture.
struct TaskDateBoard: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  /// The dated value the board should show as chosen, or nil for none.
  let selected: Date?
  /// Whether the Today row itself is the current value.
  var todayActive: Bool = false
  /// e.g. "No Date" / "Remove Deadline". The row hides when nil.
  var clearLabel: String?
  let onToday: () -> Void
  let onPick: (Date) -> Void
  let onClear: () -> Void

  @State private var calendarDate = Date()
  @State private var showingCalendar = false

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
      .padding(.bottom, 10)

      Hairline(leadingInset: 0)

      calendarButton
        .padding(.vertical, 12)

      if let clearLabel {
        Hairline(leadingInset: 0)
        row(symbol: "xmark.circle", tint: Theme.iconMuted,
            title: clearLabel, active: false) {
          Haptics.warning()
          onClear()
        }
        .padding(.top, 4)
      }
    }
  }

  /// One full-width row — symbol, then title. The AppKit board's row shape,
  /// wearing the inset palette highlight when it holds the current value.
  /// `.contentShape` is required: a `.plain` button is only tappable where it
  /// draws, so without it the trailing half of the row is a dead zone.
  private func row(symbol: String, tint: Color, title: String, active: Bool,
                   action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .scaledFont(size: 17)
          .foregroundStyle(tint)
          .frame(width: 22)
        Text(title)
          .scaledFont(size: 16)
          .foregroundStyle(Theme.inkPrimary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 11)
      .contentShape(Rectangle())
      .background(InsetSelectionBackground(isSelected: active, horizontalInset: 0))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(active ? .isSelected : [])
  }

  /// The "further out" path. The strip already covers the coming week, so the
  /// month calendar hides behind one tap — popover on iPad/Mac, small sheet on
  /// iPhone — and picking a day there commits it, like every other control.
  private var calendarButton: some View {
    Button {
      Haptics.pick()
      calendarDate = selected ?? anchorDay
      showingCalendar = true
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "calendar")
          .scaledFont(size: 17)
          .foregroundStyle(Theme.inkSecondary)
        Text("Pick another date")
          .scaledFont(size: 16, weight: .medium)
          .foregroundStyle(.primary)
        Image(systemName: "chevron.right")
          .scaledFont(size: 13, weight: .semibold)
          .foregroundStyle(Theme.iconMuted)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 13)
      .background(Capsule().fill(Theme.inkSecondary.opacity(0.08)))
      .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .popover(isPresented: $showingCalendar) {
      DatePicker("", selection: $calendarDate, displayedComponents: [.date])
        .datePickerStyle(.graphical)
        .labelsHidden()
        .tint(theme.accent)
        .padding(8)
        .frame(minWidth: 300, idealWidth: 320, minHeight: 320)
        .presentationDetents([.medium])
        .presentationCompactAdaptation(.sheet)
        .onChange(of: calendarDate) {
          showingCalendar = false
          onPick(cal.startOfDay(for: calendarDate))
        }
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
