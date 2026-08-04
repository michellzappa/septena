import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// The task composer — one form used for both creating and editing a task,
// hosted by the app's standard `AdaptiveEditScaffold` + `.adaptiveDetail`
// (a sheet on iPhone, a docked inspector on iPad/macOS — like every other edit
// drawer). Title + notes sit at the top; the electives (Today, When, Deadline,
// Repeat, List) are flat capsule pills underneath. A pill shows its glyph + label when
// unset and its glyph + value (accent-tinted) when set. Tapping a
// date/repeat pill expands its editor inline; the List picker opens as a sheet.
// In edit mode the agent conversation is a section in the scroll. See
// docs/DesignSpec.md §5.5 — glass is the floating-control material.

// MARK: - Composer card

/// The keyboard focus targets inside the composer, in no particular order —
/// `TaskComposerCard.focusOrder` defines the Tab sequence. Driven entirely
/// programmatically (Tab is intercepted), so it works with macOS keyboard
/// navigation OFF — see `moveFocus` / `activateFocused`.
enum TaskEditFocus: Hashable {
  case title
  case notes
  case pill(TaskAttributeBar.Attribute)
}

struct TaskComposerCard: View {
  enum Mode {
    case create(TaskFilter)
    case edit(SeptenaTask)

    /// Stable identity of the thing being composed. Every piece of composer
    /// `@State` that describes the *subject* (the seeded draft, the dirty
    /// baseline, the one-shot save latch) is keyed to this rather than to view
    /// lifetime, because a host can hand one card instance a different mode
    /// without SwiftUI ever tearing the view down — a docked inspector swapping
    /// from one task to the next does exactly that. When that happened, the
    /// old `seeded` / `savedOrSkipped` latches stayed set: the form kept
    /// showing the previous task's draft and every later save returned early,
    /// so an edit appeared to take in the editor and never reached the row.
    var identity: String {
      switch self {
      case .create(let filter):
        switch filter {
        case .project(let id): return "create:project:\(id)"
        case .area(let id):    return "create:area:\(id)"
        default:               return "create:\(filter.serverView)"
        }
      case .edit(let task):
        return "edit:\(task.id)"
      }
    }
  }

  /// How the same form is hosted. `.drawer` is the standard adaptive edit
  /// drawer (sheet on iPhone, docked inspector on iPad/macOS) with Cancel/Save
  /// chrome. `.inline` is the Things-style expand-in-place editor: the bare form
  /// rendered straight into the expanded task row — no scaffold, no inner
  /// ScrollView (the list scrolls), autosaving on collapse.
  enum Presentation { case drawer, inline }

  let mode: Mode
  let areas: [Area]
  let projects: [Project]
  let accent: Color
  let presentation: Presentation
  /// The inline host already inserted this edit-mode task as a local-only
  /// placeholder for row identity. Intent remains CREATE; this storage detail
  /// must not enable edit-only behavior or disable create-only behavior.
  let deferredCreate: Bool
  /// Inline collapse hook — how the form asks its host row to fold shut (Return
  /// to save, etc.). The scaffold/`.adaptiveDetail` owns closing in `.drawer`.
  let onClose: (() -> Void)?
  /// Inline-only: toggle the task complete from the editor's title-line
  /// checkbox (wired to the list's settle-aware `toggle`). Nil in the drawer /
  /// create, where there's no checkbox.
  let onToggleComplete: (() -> Void)?
  /// Hero-animation anchors (`matchedGeometryEffect`) shared with the closed
  /// row's title + checkbox, so they glide between the row and the open inline
  /// editor instead of cross-fading. Inline only; nil in the drawer.
  var titleMatchID: String? = nil
  var checkboxMatchID: String? = nil
  var heroMatchNS: Namespace.ID? = nil
  /// Hero-glide source flag — paired with the closed row's inverse so only one
  /// endpoint is `isSource: true` during expand/collapse transitions.
  var heroMatchIsSource: Bool = true
  /// Surface context for the title-line checkbox so it's derived identically to
  /// the closed row (the row gates the Today indicator off Today surfaces).
  /// Forwarded into the shared `TaskCheckboxModel`. Matches the row's
  /// `showsTodayIndicator` (`filter != .today`).
  var showsTodayIndicator: Bool = true
  /// Fired after a successful create/edit (or a terminal action) so the list
  /// reloads. Closing is owned by the scaffold / `.adaptiveDetail`, not here.
  let onDone: () -> Void
  /// Inline-only teardown hook, fired in `.onDisappear` *after* the autosave
  /// funnel has run. The host uses it to drop an untouched inline-create draft
  /// — but only once the save has definitely had its chance, so a just-typed
  /// title can never be purged out from under the (animation-delayed) autosave.
  var onVanish: (() -> Void)? = nil

  @Environment(TaskMutator.self) private var mutator
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.adaptiveDetailClose) private var adaptiveClose
  // Inspector (iPad/macOS) vs. bottom sheet (iPhone) — the same flag
  // `.adaptiveDetail` switches on. Edit mode only autofocuses in the inspector,
  // where the keyboard doesn't fight the half-height sheet detent.
  @Environment(\.usesPushNavigation) private var useInspector
  // Inline presentation lays out at the host list's row rhythm so the editor's
  // title line sits flush with the rows above/below it (checkbox + title at the
  // same insets). The drawer keeps its own airier padding.
  @Environment(\.rowHInset) private var rowHInset
  @Environment(\.rowVInset) private var rowVInset
  @State private var draft = TaskDraft()
  /// Which `Mode.identity` the current `draft` was seeded from — the guard that
  /// replaces a plain `seeded` bool. Nil until the first seed; re-seeding is
  /// driven by this no longer matching `mode.identity`.
  @State private var seededIdentity: String?
  /// The mode the current `draft` was seeded from, and therefore the target
  /// every save writes to. Deliberately NOT read from `mode`: when a host swaps
  /// the composer to a different subject in place, the outgoing draft must be
  /// flushed into the task it was actually edited against, never into the
  /// incoming one.
  @State private var seededMode: Mode?
  /// `deferredCreate` as of the seed, for the same reason as `seededMode`.
  @State private var seededDeferredCreate = false
  /// The create-mode draft exactly as seeded from the list's defaults — the
  /// baseline `isDirty` compares against so the pre-filled Today/project/area
  /// defaults don't read as user edits. Unused in edit mode.
  @State private var seededDraft = TaskDraft()
  #if os(iOS)
  /// Bottom-sheet height (iPhone only — the iPad/macOS inspector ignores this).
  /// New tasks open full so the autofocused title sits above the keyboard from
  /// the start; edits open at half height (no autofocus) and only promote to
  /// full when a field is tapped. Seeded per-mode in `init` (before first
  /// presentation, so editing opens at half height without flashing full first).
  @State private var detent: PresentationDetent = .large
  #endif
  /// Single keyboard cursor across the whole form (title, pills, terminal
  /// actions). Replaces the old title-only `titleFocused` bool.
  @FocusState private var focus: TaskEditFocus?
  /// One-shot trigger: set to a pill to make `TaskAttributeBar` run its
  /// `select` for that pill (keyboard Space/Return on a focused pill). The bar
  /// resets it to nil after acting.
  @State private var pendingPillActivate: TaskAttributeBar.Attribute?
  /// Escape follows the platform contract: cancel is non-destructive until a
  /// dirty draft has been explicitly confirmed for discard.
  @State private var showingKeyboardDiscardConfirmation = false
  /// The draft exactly as it was at the last successful write. `persistOnce`
  /// skips when the current draft still equals it, which makes saving
  /// idempotent WITHOUT being one-shot.
  ///
  /// This used to be a `savedOrSkipped` boolean latch, and that silently ate
  /// edits. `.onDisappear` is the autosave hook, but the inline editor lives in
  /// a `LazyVStack`, which fires `.onDisappear` whenever the row leaves the
  /// materialization window — a scroll, or the relayout the editor itself
  /// causes when its title wraps — while keeping the view's `@State` alive. The
  /// latch turned that transient disappear into the ONLY save the editor would
  /// ever perform: everything typed afterwards was held in `draft`, shown in the
  /// field, and never written. Hence "2 of 4 edits stuck".
  @State private var lastPersistedDraft: TaskDraft?
  /// Explicit Cancel → Discard. Terminal for this editing session, unlike the
  /// save bookkeeping above: it must survive any number of teardowns.
  @State private var discarded = false
  /// SuggestionEngine's learned area/project pick for the current title (the
  /// "Suggested" chip). Recomputed as the title changes; create-mode only.
  @State private var suggestedList: SuggestionEngine.Suggestion?
  /// Mirrors whether the Discuss pill is on the rail (edit mode, no thread yet).
  @State private var discussKickoffVisible = false
  /// Inline-only: the title column width for wrap detection and whether the
  /// draft title currently needs a second line. A vertical-axis `TextField`
  /// with `lineLimit(1...2)` reserves two lines even when empty — so inline
  /// create/edit stays single-line until the title actually wraps.
  @State private var inlineTitleColumnWidth: CGFloat = 0
  @State private var inlineTitleWraps = false
  // The effective body point size for wrap measurement on iOS. `@ScaledMetric`
  // tracks the ambient `dynamicTypeSize` — including the app's ±2 Text Size step,
  // which is applied as an environment shift at the root — so the measurement
  // font matches the size the title actually renders at. (macOS has no Dynamic
  // Type; there the size comes from `SeptenaTypeScale` / `FontScale` instead.)
  @ScaledMetric(relativeTo: .body) private var scaledTitleSize: CGFloat = 17

  init(mode: Mode, areas: [Area], projects: [Project], accent: Color,
       presentation: Presentation = .drawer, deferredCreate: Bool = false,
       onClose: (() -> Void)? = nil,
       onToggleComplete: (() -> Void)? = nil,
       titleMatchID: String? = nil, checkboxMatchID: String? = nil,
       heroMatchNS: Namespace.ID? = nil, heroMatchIsSource: Bool = true,
       showsTodayIndicator: Bool = true,
       onDone: @escaping () -> Void,
       onVanish: (() -> Void)? = nil) {
    self.mode = mode
    self.areas = areas
    self.projects = projects
    self.accent = accent
    self.presentation = presentation
    self.deferredCreate = deferredCreate
    self.onClose = onClose
    self.onToggleComplete = onToggleComplete
    self.titleMatchID = titleMatchID
    self.checkboxMatchID = checkboxMatchID
    self.heroMatchNS = heroMatchNS
    self.heroMatchIsSource = heroMatchIsSource
    self.showsTodayIndicator = showsTodayIndicator
    self.onDone = onDone
    self.onVanish = onVanish
    #if os(iOS)
    // Seed the iPhone sheet height before first presentation so editing opens
    // directly at half height instead of flashing full then snapping down.
    if case .edit = mode { _detent = State(initialValue: .medium) }
    #endif
  }

  private var isEditing: Bool {
    if !deferredCreate, case .edit = mode { return true }
    return false
  }

  private var isCreating: Bool {
    if deferredCreate { return true }
    if case .create = mode { return true }
    return false
  }

  private var editingTask: SeptenaTask? {
    if isEditing, case .edit(let task) = mode { return task }
    return nil
  }

  /// Whether the notes field is present. It starts collapsed so the composer
  /// opens as a single title line (create *and* edit) and only appears once the
  /// task actually has notes or the user reveals it via the Notes pill. When
  /// hidden, the rail shows an elective "Notes" pill instead (see
  /// `TaskAttributeBar`).
  private var showsNotesField: Bool { !draft.notes.isEmpty || focus == .notes }

  private var headerTitle: String { isEditing ? "Edit To-Do" : "New Task" }
  private var saveTitle: String { isEditing ? "Save" : "Add" }

  /// Close: fold the inline editor (`onClose`) when hosted inline, else go
  /// through the docked-inspector hook with a sheet `dismiss()` fallback — the
  /// same close path `AdaptiveEditScaffold` uses, so terminal actions match.
  private func close() { (onClose ?? adaptiveClose ?? { dismiss() })() }

  private func requestKeyboardCancel() {
    // One Escape keystroke can reach this from several handlers at once: the
    // container's key press, the title field's own copy (a TextField would
    // otherwise swallow it), and AppKit's exit command on macOS. So this has to
    // be idempotent — once a cancel is in flight, the duplicates are no-ops.
    // Previously the second call re-read `isDirty` after the first had already
    // discarded and closed, which made the outcome depend on handler ordering.
    guard !showingKeyboardDiscardConfirmation, !discarded else { return }
    if isDirty {
      showingKeyboardDiscardConfirmation = true
    } else {
      discard()
      close()
    }
  }

  private func discardAndClose() {
    discard()
    close()
  }

  var body: some View {
    presentedContent
      .onAppear(perform: seed)
      // A host can point this same card at a different task without SwiftUI
      // tearing it down (a docked inspector moving between rows). Flush the
      // outgoing edit — `persist` writes to `seededMode`, so it lands on the
      // task it was typed against — then re-seed for the new subject.
      .onChange(of: mode.identity) { _, _ in
        persistOnce()
        seed()
      }
      // A task editor is a normal form: Escape cancels rather than silently
      // saving. On macOS the field editor consumes Escape, so carry both the
      // AppKit exit command and SwiftUI key press forms.
      .septenaOnEscape(requestKeyboardCancel)
      .onKeyPress(.escape) { requestKeyboardCancel(); return .handled }
      .confirmationDialog(
        isEditing ? "Discard changes?" : "Discard new task?",
        isPresented: $showingKeyboardDiscardConfirmation,
        titleVisibility: .visible
      ) {
        Button("Discard", role: .destructive) { discardAndClose() }
        Button("Keep Editing", role: .cancel) {}
      } message: {
        Text("Your unsaved changes will be lost.")
      }
      // Safety net: persist on any teardown the buttons didn't already handle
      // (app backgrounded, the inspector toggled shut by the system, a parent
      // removed, or — inline — the row folded). Idempotent via
      // `lastPersistedDraft`: an explicit Save already wrote this exact draft
      // so it no-ops, and a Cancel → Discard latches it off entirely. The belt
      // to the Cancel suspenders: the only path that loses work is a confirmed
      // Discard. For the inline editor this IS the save path — folding the row
      // autosaves.
      //
      // Note this can fire while the row is still being edited: the inline host
      // is a `LazyVStack`, which disappears a row that merely scrolled out of
      // the materialization window without destroying its state. That's exactly
      // why the guard compares drafts instead of latching after the first call.
      // Save first, THEN let the host decide about an untouched draft — both in
      // the one teardown event so purge can never front-run the autosave.
      .onDisappear { persistOnce(); onVanish?() }
      .onChange(of: draft.title) { _, newValue in
        // A vertical-axis TextField turns Return into a newline at the cursor;
        // we treat that as "save". Remove the newline ENTIRELY (not a space) so
        // the title is exactly what it was before Enter — replacing it with a
        // space, then only trimming the ends, left a stray space wherever the
        // cursor sat mid-title. A single-line title never keeps a newline, so
        // this also flattens a pasted multi-line string.
        if newValue.contains("\n") {
          draft.title = newValue.replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if draft.canSave { commit(); return }
        }
        refreshInlineTitleWrap()
        updateSuggestion()
      }
  }

  @ViewBuilder
  private var presentedContent: some View {
    switch presentation {
    case .inline:
      // No scaffold, no inner ScrollView — the bare form expands inside the
      // task row and the LIST scrolls. Autosaves on fold (see `.onDisappear`).
      formBody
    case .drawer:
      drawerBody
    }
  }

  /// The standard adaptive edit drawer: a grouped sheet on iPhone, a docked
  /// inspector on iPad/macOS, Cancel/Save chrome owned by the scaffold.
  private var drawerBody: some View {
    AdaptiveEditScaffold(
      title: headerTitle,
      // Standard two-control chrome: an explicit commit (Add / Save) and a real
      // Cancel. Cancel discards — but only through a confirmation when the form
      // is dirty, and the scaffold blocks swipe-to-dismiss while dirty, so the
      // ONLY way to lose a task is an explicit Cancel → Discard.
      saveTitle: saveTitle,
      cancelTitle: "Cancel",
      showsSave: true,
      accent: accent,
      canSave: draft.canSave,
      isDirty: isDirty,
      discardTitle: isEditing ? "Discard changes?" : "Discard new task?",
      onSave: { persistOnce() },
      onDiscard: { discard() }
    ) {
      ScrollView {
        formBody
      }
      .scrollDismissesKeyboard(.interactively)
    }
    #if os(iOS)
    // Half-height-when-possible bottom sheet; `detent` is seeded per-mode. The
    // keyboard auto-promotes the sheet to `.large`, so edit mode stays half
    // until you tap a field. (No-op for the iPad/macOS docked inspector.)
    .presentationDetents([.medium, .large], selection: $detent)
    .presentationContentInteraction(.scrolls)
    #endif
  }

  /// The form itself — title, quick-entry chips, the elective pill rail, and
  /// (edit mode) the conversation. Shared verbatim by the drawer and the inline
  /// editor so they're literally identical components.
  private var formBody: some View {
    // Inline rides the list's row rhythm (tight gaps, content aligned to the row
    // inset); the drawer keeps a roomier 16pt card. Pills/conversation indent a
    // touch past the checkbox so they hang off the title, Things-style.
    let inline = presentation == .inline
    return VStack(alignment: .leading, spacing: inline ? 10 : 14) {
      titleNotesCard

      Group {
        if showsNotesField {
          notesField
            .transition(.opacity.combined(with: .move(edge: .top)))
        }

        quickEntryChips

        TaskAttributeBar(
          draft: $draft,
          areas: areas,
          projects: projects,
          accent: accent,
          neutral: inline,
          focus: $focus,
          activate: $pendingPillActivate,
          discussTask: editingTask,
          discussVisible: $discussKickoffVisible
        )

        // Edit mode only — a not-yet-created task has no id/conversation.
        // docs/TASK_CONVERSATIONS_PHASE1.md.
        if let task = editingTask {
          ConversationSection(task: task, accent: accent)
        }
      }
      // Indent the rail/conversation to align with the title text (past the
      // checkbox column) when inline; the drawer has no checkbox so no indent.
      .padding(.leading, inline ? Theme.checkboxTap + Theme.iconTextGap : 0)
    }
    .padding(.horizontal, inline ? rowHInset : 16)
    // Inline: same top/bottom inset as closed task rows (`rowVInset` from the
    // list). The card chrome supplies the external gap to sibling rows.
    .padding(.vertical, inline ? rowVInset : 16)
    // Tab / Shift-Tab cycle the whole form; Space / Return open a focused pill
    // or fire a focused action. Attached here so it catches the keypress
    // whenever any pill / action (a focusable descendant) holds the cursor; the
    // title field carries its own copy (a TextField would otherwise eat Tab).
    // Works with macOS keyboard navigation off — we move focus ourselves.
    .onKeyPress(keys: [.tab]) { press in
      moveFocus(forward: !press.modifiers.contains(.shift)); return .handled
    }
    .onKeyPress(.space) { activateFocused() }
    .onKeyPress(.return) { activateFocused() }
    .a11yAnimation(.snappy(duration: 0.22), value: showsNotesField)
  }

  // MARK: - Title / notes

  @ViewBuilder
  private var titleNotesCard: some View {
    // Title only — notes moved to an elective pill in the attribute bar so the
    // card stays a single clean line; tapping the Notes pill expands an inline
    // editor like the When / Deadline / Repeat controls.
    if presentation == .inline {
      // Mirror the static row: a baseline-aligned checkbox + the title as a
      // plain field, no boxed background — so the expanded row reads as the same
      // line you clicked, now editable, instead of a heavy input card.
      HStack(alignment: .rowTitleCenter, spacing: Theme.iconTextGap) {
        Group {
          if let task = editingTask, let onToggleComplete {
            // Derived from the SAME `TaskCheckboxModel` the closed row uses, so the
            // box is identical in view and edit modes (tint, Today gating, proposal
            // dashing, tenure dial, unread-context dot — all shared, never re-rolled).
            TaskCheckbox(
              model: TaskCheckboxModel(task: task, accent: accent,
                                       showsTodayIndicator: showsTodayIndicator),
              onToggle: onToggleComplete
            )
          } else {
            // Create mode: a plain empty, non-interactive box so the new-task row
            // reads like a real task row (matching the closed rows above/below it)
            // instead of a title floating with no checkbox. There's nothing to
            // toggle until the task is committed, so it ignores hits.
            TaskCheckbox(isDone: false, onToggle: {})
              .allowsHitTesting(false)
          }
        }
        .matchedHeroGeometry(checkboxMatchID, heroMatchNS, isSource: heroMatchIsSource)
        .alignmentGuide(.rowTitleCenter) { d in d[VerticalAlignment.center] }
        VStack(alignment: .leading, spacing: 4) {
          titleField
            .alignmentGuide(.rowTitleCenter) { d in d[VerticalAlignment.center] }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _, width in
          inlineTitleColumnWidth = width
          refreshInlineTitleWrap()
        }
        .matchedHeroGeometry(titleMatchID, heroMatchNS, isSource: heroMatchIsSource)
      }
    } else {
      titleField
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.secondaryGroupedBackground,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(focusRing(visible: focus == .title, cornerRadius: 18))
    }
  }

  private var titleField: some View {
    // ONE field identity across the single-line ↔ wrapped transition: a
    // vertical-axis `TextField` whose lineLimit *value* flips, never the view
    // itself. (An earlier `if/else` swapped a plain field for a vertical-axis one
    // at the wrap threshold, tearing down and rebuilding the focused field
    // mid-keystroke — the Text↔TextField identity-swap trap that clobbers focus
    // and cursor.) A range lineLimit reserves blank space for its MAX line count
    // even when empty, so single-line mode caps at `1...1` to avoid a phantom
    // second line on a new task; it opens to `1...2` only once the text wraps.
    // Drawer: no checkbox to align against, so it may grow to two lines freely.
    let singleLine = presentation == .inline && !inlineTitleWraps
    return TextField("", text: $draft.title, axis: .vertical)
      .lineLimit(singleLine ? 1...1 : 1...2)
      .textFieldStyle(.plain)
      .font(.septenaTaskTitle)
      // Match the closed row's title `Text` box so the two center-align to the
      // same place: `.fixedSize` gives the field the same tight vertical box a
      // `Text` has, and the shared band (`Theme.checkboxTap`, centered) makes the
      // closed `Text` and this `TextField` occupy an identical box on the same
      // checkbox line. This is the closest reliable match (a plain `TextField`
      // still differs from `Text` sub-pixel; baseline alignment was worse because
      // SwiftUI mis-reports a vertical-axis field's baseline). Inline only.
      .fixedSize(horizontal: false, vertical: true)
      .frame(minHeight: presentation == .inline ? Theme.checkboxTap : 0,
             alignment: .center)
      // Edit mode renders the title a few points HIGHER than the closed row's
      // `Text` — the UITextView text-container inset. Since open/close is now
      // instant (no animation to smear it), a fixed downward shift plants the
      // editing glyphs back on the closed-row line. Visual-only. Tune the one
      // constant until it sits still. Inline only.
      .offset(y: presentation == .inline ? Self.editModeTitleDrop : 0)
      .focused($focus, equals: .title)
      // macOS: a vertical-axis field fires onSubmit on plain Return (the iOS
      // newline-as-save trick never triggers there) — commit here instead.
      .onSubmit { if draft.canSave { commit() } }
      // The field would otherwise swallow Tab, so carry the same focus-cycling
      // handler here too.
      .onKeyPress(keys: [.tab]) { press in
        moveFocus(forward: !press.modifiers.contains(.shift)); return .handled
      }
      // macOS only: the field editor consumes Escape before the container's
      // handler sees it. `requestKeyboardCancel` is idempotent, so the overlap
      // with the container binding is harmless.
      .septenaOnEscape(requestKeyboardCancel)
  }

  /// How far to drop the inline edit-mode title so its glyphs land on the closed
  /// row's text line (counters the UITextView text-container inset). The single
  /// tuning knob for the view↔edit jump — raise if the title still sits high in
  /// edit mode, lower if it now sits low. Points, positive = down. iOS only for
  /// now (macOS's field editor has a different inset and hasn't shown the jump).
  private static var editModeTitleDrop: CGFloat {
    #if os(iOS)
    return 1
    #else
    return 0
    #endif
  }

  /// Recompute whether the inline title needs a second line so the field can
  /// switch between single-line and vertical-axis modes without reserving two
  /// blank lines on an empty new task.
  private func refreshInlineTitleWrap() {
    guard presentation == .inline else { return }
    #if os(macOS)
    // No Dynamic Type on macOS — the title renders at the FontScale-scaled body
    // size, so measure with the same.
    let bodySize = SeptenaTypeScale.size(.body)
    #else
    let bodySize = scaledTitleSize
    #endif
    inlineTitleWraps = TaskTitleMetrics.wraps(
      text: draft.title, width: inlineTitleColumnWidth, bodyPointSize: bodySize)
  }

  /// Notes — a multi-line field sitting directly under the title (Things-style),
  /// no box and no Clear button. It's collapsed by default (`showsNotesField`)
  /// so the composer opens on a single title line; it appears once the task has
  /// notes or the Notes pill reveals it. Return inserts a newline here (it's
  /// prose), so — unlike the title — there's no Return-to-save; Tab still
  /// cycles focus.
  private var notesField: some View {
    TaskMarkdownNotesEditor(text: $draft.notes, focus: $focus)
      // A little extra right margin so wrapped prose doesn't run to the card edge.
      .padding(.trailing, 12)
      .onKeyPress(keys: [.tab]) { press in
        moveFocus(forward: !press.modifiers.contains(.shift)); return .handled
      }
  }

  /// The shared keyboard focus ring drawn on whatever holds the cursor — a
  /// 2pt accent stroke, so Tab traversal is visible with macOS keyboard
  /// navigation off (the system ring never appears).
  @ViewBuilder
  private func focusRing(visible: Bool, cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .strokeBorder(accent, lineWidth: 2)
      .opacity(visible ? 1 : 0)
      .allowsHitTesting(false)
  }

  private func updateSuggestion() {
    guard TaskRowFlags.filingSuggestionsEnabled else {
      suggestedList = nil
      return
    }
    guard isCreating else { return }
    if draft.projectId != nil || draft.areaId != nil {
      suggestedList = nil
    } else {
      suggestedList = SuggestionEngine.shared.suggest(forText: draft.title)
    }
  }

  // MARK: - Quick entry

  /// Date phrases and #project / @area / !today tokens detected in the title,
  /// limited to ones whose field isn't already set. Create-mode only — parsing
  /// an existing title on edit would surface noise.
  private var detectedTokens: [DetectedToken] {
    guard isCreating else { return [] }
    return TaskTitleParser.detect(in: draft.title, projects: projects, areas: areas)
      .filter(isUnset)
  }

  private func isUnset(_ token: DetectedToken) -> Bool {
    switch token.kind {
    case .today, .date: return !draft.onToday && draft.scheduled == nil
    case .project:      return draft.projectId == nil
    case .area:         return draft.areaId == nil && draft.projectId == nil
    }
  }

  /// Whether to offer the learned "Suggested list" chip — only when the user
  /// hasn't filed the task somewhere already.
  private var listSuggestion: SuggestionEngine.Suggestion? {
    guard draft.projectId == nil, draft.areaId == nil else { return nil }
    return suggestedList
  }

  /// Tap-to-apply chips: tokens parsed out of the title (date / #project /
  /// @area / !today) plus the learned list suggestion. Nothing is applied
  /// silently — the user confirms each (and committing applies parsed tokens).
  @ViewBuilder
  private var quickEntryChips: some View {
    let tokens = detectedTokens
    let suggestion = listSuggestion
    if !tokens.isEmpty || suggestion != nil {
      FlowLayout(spacing: 8) {
        ForEach(tokens) { token in
          chip(icon: token.icon, leading: "plus", text: token.displayText) { apply(token) }
        }
        if let s = suggestion {
          chip(icon: s.kind == .project ? "number" : "folder",
               leading: "lightbulb", text: s.title) { applySuggestedList() }
        }
      }
      .transition(.opacity)
    }
  }

  /// A small glass action chip: a leading hint glyph (`plus` to add a parsed
  /// token, `lightbulb` for the smart suggestion), the field's icon, and a label.
  private func chip(icon: String, leading: String, text: String,
                    _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: leading).font(.system(size: 10, weight: .bold))
        Image(systemName: icon).font(.system(size: 11, weight: .semibold))
        Text(text).font(.septenaLabel).lineLimit(1)
      }
      .foregroundStyle(accent)
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .background(Capsule().fill(accent.opacity(0.28)))
  }

  private func applySuggestedList() {
    guard let s = suggestedList else { return }
    Haptics.tick()
    a11yAnimate(.snappy(duration: 0.2)) {
      switch s.kind {
      case .project:
        draft.projectId = s.id
        draft.areaId = projects.first { $0.id == s.id }?.area
      case .area:
        draft.areaId = s.id; draft.projectId = nil
      }
      suggestedList = nil
    }
  }

  /// Apply a detected token to the draft and strip its phrase from the title.
  private func applyToken(_ token: DetectedToken) {
    switch token.kind {
    case .today:
      draft.setToday()
    case .date(let d):
      draft.setScheduled(d)
    case .project(let id, _):
      draft.projectId = id
      draft.areaId = projects.first { $0.id == id }?.area
    case .area(let id, _):
      draft.areaId = id; draft.projectId = nil
    }
    draft.title = TaskTitleParser.strip(token.phrase, from: draft.title)
  }

  private func apply(_ token: DetectedToken) {
    Haptics.tick()
    a11yAnimate(.snappy(duration: 0.2)) { applyToken(token) }
    updateSuggestion()
  }

  // MARK: - Lifecycle

  /// Seed the draft from `mode` — once per subject, not once per view lifetime.
  /// Re-runs whenever `mode.identity` changes so a reused card instance always
  /// shows (and commits) the task it is currently pointed at.
  private func seed() {
    guard seededIdentity != mode.identity else { return }
    seededIdentity = mode.identity
    seededMode = mode
    seededDeferredCreate = deferredCreate
    // A new subject starts with nothing written and nothing discarded.
    lastPersistedDraft = nil
    discarded = false
    switch mode {
    case .create(let filter):
      draft = TaskDraft(filter: filter)
      seededDraft = draft
      // Train the list classifier once so the "Suggested" chip can query it
      // cheaply per keystroke.
      if TaskRowFlags.filingSuggestionsEnabled {
        SuggestionEngine.shared.prepare(
          allTasks: LocalCache.trainingTasks(in: modelContext),
          projects: projects, areas: areas
        )
      }
      // Focus after the sheet settles — an immediate focus is dropped before the
      // field joins the responder chain, so the keyboard wouldn't come up.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focusTitle() }
    case .edit(let task):
      draft = TaskDraft(task: task)
      // Snapshot the seeded draft as the dirty baseline — the SAME approach as
      // create mode. Comparing the whole struct against its own seed is immune to
      // the per-field normalization subtleties of `differs(from:)` (computed
      // `storedScheduled`/`pinToday`, trimmed-vs-raw title) that were leaving an
      // untouched peek reading "dirty" and wrongly prompting "Discard changes?".
      seededDraft = draft
      // Note: opening the editor must NOT acknowledge. The agent cue == triage-
      // band membership for agent rows, so acknowledging here would silently
      // ratify an unclassified proposal the moment you peek at it — it would
      // vanish from the Inbox on dismiss with no decision made. Ratification
      // happens on Save, and only when the edit actually (re)places it (see
      // `persist`).
      //
      // On the iPhone sheet, editing opens at half height (seeded in `init`)
      // with no autofocus: you're reviewing an existing task, not entering one,
      // so we don't raise the keyboard (which would force the sheet to full).
      // Tapping the title focuses it and the system promotes the sheet then.
      // In the iPad/macOS inspector there's no detent to protect, so keep the
      // keyboard-driven "open row with Return, edit immediately" focus.
      if deferredCreate, TaskRowFlags.filingSuggestionsEnabled {
        SuggestionEngine.shared.prepare(
          allTasks: LocalCache.trainingTasks(in: modelContext),
          projects: projects, areas: areas
        )
      }
      if useInspector || presentation == .inline {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focusTitle() }
      }
    }
  }

  /// Move keyboard focus into the title field and — on macOS — drop the cursor
  /// at the END of the existing title instead of letting `NSTextField` select
  /// the whole string. The cursor nudge is deferred one beat past the focus
  /// assignment so the field editor has joined the responder chain first
  /// (otherwise there's nothing to reposition). A no-op for a fresh empty title.
  private func focusTitle() {
    focus = .title
    #if os(macOS)
    DispatchQueue.main.async { septenaMoveCursorToEnd() }
    #endif
  }

  /// Apply any quick-entry tokens the user didn't tap. The `isUnset` guard
  /// means an earlier token (e.g. `!today`) wins over a later conflicting one
  /// (a detected date) instead of being clobbered.
  private func applyPendingTokens() {
    for token in detectedTokens where isUnset(token) { applyToken(token) }
  }

  /// Writes the draft through the mutator. The scaffold's Save runs this then
  /// closes; the title-newline path runs it through `commit()`.
  private func persist() {
    // Commit against the mode the draft was SEEDED from (see `seededMode`), so
    // a mid-flight subject swap flushes the outgoing edit into the right task.
    switch seededMode ?? mode {
    case .create:
      applyPendingTokens()
      draft.create(via: mutator)
      AddInfoSection.tasks.notifyTilesChanged()
    case .edit(let task):
      if seededDeferredCreate {
        // Same create pipeline as the drawer, except the inline host already
        // inserted a push-deferred entity for layout identity. Updating its
        // title releases the first CloudKit push.
        applyPendingTokens()
        draft.update(task, via: mutator)
        AddInfoSection.tasks.notifyTilesChanged()
        return
      }
      // Ratify (acknowledge → leave the Inbox) only when this save actually
      // (re)placed the task — gave it a project/area, a date, or a Today pin
      // (the same fields that take a row out of the triage band). A bare title /
      // notes edit, or just opening to peek, is not a placement decision and
      // must keep an agent proposal in the Inbox. No-op for non-agent /
      // already-seen rows.
      let placed = draft.placementChanged(from: task)
      draft.update(task, via: mutator)
      if placed { mutator.acknowledge(id: task.id) }
    }
  }

  /// The single funnel for every save path (explicit Save button,
  /// Return-to-save, autosave-on-teardown). Writes only when the draft is
  /// worth saving AND differs from what was last written, so the paths can't
  /// double-write — but any genuinely new edit still gets through, however
  /// many times this is called.
  ///
  /// It is deliberately NOT one-shot. See `lastPersistedDraft`: a `LazyVStack`
  /// fires `.onDisappear` on a row that merely scrolled out of view, and the
  /// user goes on typing into a view whose state is still very much alive.
  private func persistOnce() {
    guard !discarded else { return }
    guard draft.canSave else { return }
    guard draft != lastPersistedDraft else { return }
    lastPersistedDraft = draft
    persist()
    onDone()
  }

  /// Are there unsaved changes worth guarding? Create: any content entered;
  /// edit: any field differs from the original. Drives the scaffold's Cancel
  /// confirmation and the swipe-to-dismiss block.
  private var isDirty: Bool {
    // One rule for both modes: dirty iff the draft no longer equals the snapshot
    // taken right after seeding (create from the list defaults, edit from the
    // task). A pure whole-struct compare — no field-by-field normalization to get
    // subtly wrong — so an untouched peek is never dirty.
    draft.differs(fromSeed: seededDraft)
  }

  /// Explicit Cancel → Discard. Latches the autosave off for good so the
  /// `.onDisappear` net can't resurrect the dropped draft: create makes no
  /// task, edit leaves the original untouched (its mutations never ran). The
  /// scaffold closes after this.
  private func discard() {
    discarded = true
  }

  /// Persist + close (Return-to-save / newline-save). Closing then fires
  /// `.onDisappear`, but `persistOnce` is idempotent so it won't write twice.
  private func commit() {
    guard draft.canSave else { return }
    Haptics.tick()
    persistOnce()
    close()
  }

  // MARK: - Keyboard focus traversal

  /// Tab order: title → every pill (including Discuss when edit mode offers it).
  private var focusOrder: [TaskEditFocus] {
    // Notes is either the revealed field (`.notes`) or, when collapsed, the
    // rail's elective pill (`.pill(.notes)`) — never both.
    var order: [TaskEditFocus] = [.title]
    order.append(showsNotesField ? .notes : .pill(.notes))
    order += TaskAttributeBar.Attribute.draftCases.map { .pill($0) }
    if isEditing { order.append(.pill(.attachments)) }
    if discussKickoffVisible {
      order.append(.pill(.discuss))
    }
    return order
  }

  /// Advance / retreat the keyboard cursor, wrapping at the ends.
  private func moveFocus(forward: Bool) {
    let order = focusOrder
    guard let current = focus, let i = order.firstIndex(of: current) else {
      focus = order.first
      return
    }
    let n = order.count
    focus = order[forward ? (i + 1) % n : (i - 1 + n) % n]
  }

  /// Space / Return on the cursor: open a focused pill. On the title field (or
  /// no focus) it does nothing here so the field's own Return-to-save /
  /// space-typing wins.
  private func activateFocused() -> KeyPress.Result {
    switch focus {
    case .pill(let attr):
      pendingPillActivate = attr   // TaskAttributeBar runs `select` and resets.
      return .handled
    default:
      return .ignored
    }
  }
}

// MARK: - Inline title wrap metrics

/// Width-aware single-line vs. wrapped detection for the inline composer title.
/// Keeps new tasks at one line until the title actually needs two.
private enum TaskTitleMetrics {
  /// `bodyPointSize` is the effective rendered size of `.septenaTaskTitle` on the
  /// caller's platform (Dynamic-Type-scaled on iOS, FontScale-scaled on macOS),
  /// so the measurement font matches what the field draws at any Text Size step.
  static func wraps(text: String, width: CGFloat, bodyPointSize: CGFloat) -> Bool {
    guard !text.isEmpty, width > 0 else { return false }
    #if os(macOS)
    let font = NSFont.systemFont(ofSize: bodyPointSize)
    let oneLine = font.ascender - font.descender + font.leading
    #else
    let font = UIFont.systemFont(ofSize: bodyPointSize)
    let oneLine = font.lineHeight
    #endif
    let rect = (text as NSString).boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font],
      context: nil)
    return rect.height > oneLine * 1.05
  }
}

extension View {
  /// Present the composer as the app's standard adaptive edit drawer — a sheet
  /// on iPhone, a docked inspector on iPad/macOS — the same `.adaptiveDetail`
  /// primitive every other section's edit form uses. The composer's
  /// `AdaptiveEditScaffold` supplies the Cancel/Save chrome and closes through
  /// the injected hook.
  func taskComposerDrawer<Card: View>(
    isPresented: Binding<Bool>,
    @ViewBuilder card: @escaping () -> Card
  ) -> some View {
    adaptiveDetail(isPresented: isPresented) { card() }
  }
}
