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
  /// Autosave guard. Every persistence path (explicit Save, Return-to-save,
  /// or a terminal action that already decided the outcome) flips this so the
  /// `.onDisappear` autosave doesn't double-write or resurrect a deleted task.
  @State private var savedOrSkipped = false
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
    guard !showingKeyboardDiscardConfirmation, !savedOrSkipped else { return }
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
      // removed, or — inline — the row folded). Idempotent via `savedOrSkipped`
      // — an explicit Save already ran it, and a Cancel → Discard flips the
      // guard so this no-ops and the draft is dropped. The belt to the Cancel
      // suspenders: the only path that loses work is a confirmed Discard. For
      // the inline editor this IS the save path — folding the row autosaves.
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
    .animation(.snappy(duration: 0.22), value: showsNotesField)
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
    withAnimation(.snappy(duration: 0.2)) {
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
    withAnimation(.snappy(duration: 0.2)) { applyToken(token) }
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
    // A new subject gets a fresh save latch. Without this, a card instance that
    // already saved once could never write again.
    savedOrSkipped = false
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

  /// Persist exactly once. The single funnel for every save path (explicit
  /// Save button, Return-to-save, autosave-on-close), so they can't double
  /// write. Skips the write when there's nothing worth saving (an empty new
  /// task that's just being dismissed).
  private func persistOnce() {
    guard !savedOrSkipped else { return }
    savedOrSkipped = true
    guard draft.canSave else { return }
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

  /// Explicit Cancel → Discard. Flip the autosave guard so the `.onDisappear`
  /// net below doesn't resurrect the dropped draft: create makes no task, edit
  /// leaves the original untouched (its mutations never ran). The scaffold
  /// closes after this.
  private func discard() {
    savedOrSkipped = true
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

// MARK: - Markdown-aware task notes editor

/// Plain-text task notes with lightweight Markdown styling while editing.
///
/// This intentionally keeps the raw Markdown markers editable. Styling is only
/// an awareness layer: headings, list/check markers, emphasis, inline code, and
/// links get typographic cues as the user types, while `draft.notes` remains a
/// normal String for persistence and sync.
private struct TaskMarkdownNotesEditor: View {
  @Binding var text: String
  @FocusState.Binding var focus: TaskEditFocus?
  @State private var contentHeight: CGFloat = 28

  private let minHeight: CGFloat = 28
  private let maxHeight: CGFloat = 360

  #if os(iOS)
  @ScaledMetric(relativeTo: .body) private var scaledBodySize: CGFloat = 17
  #endif

  private var bodyFontSize: CGFloat {
    #if os(macOS)
    return SeptenaTypeScale.size(.body)
    #else
    return scaledBodySize
    #endif
  }

  private var visibleHeight: CGFloat {
    min(max(contentHeight, minHeight), maxHeight)
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      PlatformMarkdownNotesTextView(
        text: $text,
        isFocused: Binding(
          get: { focus == .notes },
          set: { focused in
            if focused { focus = .notes }
            else if focus == .notes { focus = nil }
          }
        ),
        contentHeight: $contentHeight,
        fontSize: bodyFontSize,
        maxHeight: maxHeight
      )
      .frame(height: visibleHeight)

      if text.isEmpty {
        Text("Notes")
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkSecondary)
          .allowsHitTesting(false)
      }
    }
    .frame(minHeight: minHeight, alignment: .topLeading)
  }
}

#if os(iOS)
private struct PlatformMarkdownNotesTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  @Binding var contentHeight: CGFloat
  let fontSize: CGFloat
  let maxHeight: CGFloat

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.delegate = context.coordinator
    view.backgroundColor = .clear
    view.isOpaque = false
    view.isScrollEnabled = false
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.adjustsFontForContentSizeCategory = false
    view.textDragInteraction?.isEnabled = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    view.attributedText = MarkdownNotesStyle.attributed(text, fontSize: fontSize)
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.parent = self
    view.isScrollEnabled = contentHeight >= maxHeight - 1
    view.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)

    if view.text != text {
      context.coordinator.replaceText(in: view, with: text)
    } else if context.coordinator.lastFontSize != fontSize {
      context.coordinator.applyStyle(to: view)
    }

    if isFocused, !view.isFirstResponder {
      view.becomeFirstResponder()
    } else if !isFocused, view.isFirstResponder {
      view.resignFirstResponder()
    }

    context.coordinator.updateHeight(for: view)
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: PlatformMarkdownNotesTextView
    var lastFontSize: CGFloat = 0
    private var applying = false

    init(parent: PlatformMarkdownNotesTextView) {
      self.parent = parent
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
      parent.isFocused = true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      parent.isFocused = false
    }

    func textViewDidChange(_ textView: UITextView) {
      guard !applying else { return }
      parent.text = textView.text
      applyStyle(to: textView)
      updateHeight(for: textView)
    }

    func replaceText(in textView: UITextView, with text: String) {
      applying = true
      let selected = textView.selectedRange
      textView.attributedText = MarkdownNotesStyle.attributed(text, fontSize: parent.fontSize)
      textView.selectedRange = clamped(selected, length: textView.textStorage.length)
      textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: parent.fontSize)
      lastFontSize = parent.fontSize
      applying = false
      updateHeight(for: textView)
    }

    func applyStyle(to textView: UITextView) {
      guard textView.markedTextRange == nil else { return }
      applying = true
      let selected = textView.selectedRange
      MarkdownNotesStyle.apply(to: textView.textStorage,
                               raw: textView.text,
                               fontSize: parent.fontSize)
      textView.selectedRange = clamped(selected, length: textView.textStorage.length)
      textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: parent.fontSize)
      lastFontSize = parent.fontSize
      applying = false
    }

    func updateHeight(for textView: UITextView) {
      guard textView.bounds.width > 0 else { return }
      let size = textView.sizeThatFits(
        CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
      )
      let next = max(28, ceil(size.height))
      DispatchQueue.main.async {
        if abs(self.parent.contentHeight - next) > 0.5 {
          self.parent.contentHeight = next
        }
      }
    }

    private func clamped(_ range: NSRange, length: Int) -> NSRange {
      NSRange(location: min(range.location, length),
              length: min(range.length, max(0, length - min(range.location, length))))
    }
  }
}
#elseif os(macOS)
private struct PlatformMarkdownNotesTextView: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  @Binding var contentHeight: CGFloat
  let fontSize: CGFloat
  let maxHeight: CGFloat

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true

    let textView = NSTextView()
    textView.delegate = context.coordinator
    textView.drawsBackground = false
    textView.isRichText = true
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = CGSize(width: scrollView.bounds.width,
                                                   height: .greatestFiniteMagnitude)
    textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    textView.textStorage?.setAttributedString(MarkdownNotesStyle.attributed(text, fontSize: fontSize))

    scrollView.documentView = textView
    context.coordinator.textView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = context.coordinator.textView else { return }

    scrollView.hasVerticalScroller = contentHeight >= maxHeight - 1
    textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    textView.textContainer?.containerSize = CGSize(width: max(scrollView.bounds.width, 1),
                                                   height: .greatestFiniteMagnitude)

    if textView.string != text {
      context.coordinator.replaceText(in: textView, with: text)
    } else if context.coordinator.lastFontSize != fontSize {
      context.coordinator.applyStyle(to: textView)
    }

    if isFocused, textView.window?.firstResponder !== textView {
      if let window = textView.window {
        window.makeFirstResponder(textView)
      } else {
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
      }
    } else if !isFocused, textView.window?.firstResponder === textView {
      textView.window?.makeFirstResponder(nil)
    }

    context.coordinator.updateHeight(for: scrollView)
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: PlatformMarkdownNotesTextView
    weak var textView: NSTextView?
    var lastFontSize: CGFloat = 0
    private var applying = false

    init(parent: PlatformMarkdownNotesTextView) {
      self.parent = parent
    }

    func textDidBeginEditing(_ notification: Notification) {
      parent.isFocused = true
    }

    func textDidEndEditing(_ notification: Notification) {
      parent.isFocused = false
    }

    func textDidChange(_ notification: Notification) {
      guard !applying, let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
      applyStyle(to: textView)
      if let scrollView = textView.enclosingScrollView {
        updateHeight(for: scrollView)
      }
    }

    func replaceText(in textView: NSTextView, with text: String) {
      applying = true
      let selected = textView.selectedRange()
      textView.textStorage?.setAttributedString(MarkdownNotesStyle.attributed(text, fontSize: parent.fontSize))
      textView.setSelectedRange(clamped(selected, length: textView.string.utf16.count))
      textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: parent.fontSize)
      lastFontSize = parent.fontSize
      applying = false
      if let scrollView = textView.enclosingScrollView {
        updateHeight(for: scrollView)
      }
    }

    func applyStyle(to textView: NSTextView) {
      applying = true
      let selected = textView.selectedRange()
      if let storage = textView.textStorage {
        MarkdownNotesStyle.apply(to: storage,
                                 raw: textView.string,
                                 fontSize: parent.fontSize)
      }
      textView.setSelectedRange(clamped(selected, length: textView.string.utf16.count))
      textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: parent.fontSize)
      lastFontSize = parent.fontSize
      applying = false
    }

    func updateHeight(for scrollView: NSScrollView) {
      guard let textView else { return }
      let width = max(scrollView.bounds.width, 1)
      textView.textContainer?.containerSize = CGSize(width: width,
                                                     height: .greatestFiniteMagnitude)
      textView.frame.size.width = width
      if let manager = textView.layoutManager, let container = textView.textContainer {
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let next = max(28, ceil(used.height + textView.textContainerInset.height))
        DispatchQueue.main.async {
          if abs(self.parent.contentHeight - next) > 0.5 {
            self.parent.contentHeight = next
          }
          textView.frame.size.height = next
        }
      }
    }

    private func clamped(_ range: NSRange, length: Int) -> NSRange {
      NSRange(location: min(range.location, length),
              length: min(range.length, max(0, length - min(range.location, length))))
    }
  }
}
#endif

private enum MarkdownNotesStyle {
  static func attributed(_ raw: String, fontSize: CGFloat) -> NSAttributedString {
    let attributed = NSMutableAttributedString(string: raw)
    apply(to: attributed, raw: raw, fontSize: fontSize)
    return attributed
  }

  static func apply(to attributed: NSMutableAttributedString,
                    raw: String,
                    fontSize: CGFloat) {
    let full = NSRange(location: 0, length: attributed.length)
    guard full.length > 0 else { return }

    attributed.setAttributes(baseAttributes(fontSize: fontSize), range: full)

    applyLineStyle(#"(?m)^(#{1,3})[ \t]+(.+)$"#, raw: raw, to: attributed) { match in
      let level = max(1, min(3, match.range(at: 1).length))
      let size = fontSize + CGFloat(4 - level)
      attributed.addAttributes([
        .font: platformFont(size: size, weight: .semibold),
        .foregroundColor: primaryColor
      ], range: match.range(at: 2))
      attributed.addAttributes([
        .foregroundColor: secondaryColor,
        .font: platformFont(size: fontSize, weight: .semibold)
      ], range: match.range(at: 1))
    }

    applyLineStyle(#"(?m)^(\s*(?:[-*+]|\d+\.)(?:\s+\[[ xX]\])?\s+)"#, raw: raw, to: attributed) { match in
      attributed.addAttributes([
        .foregroundColor: secondaryColor,
        .font: platformFont(size: fontSize, weight: .semibold)
      ], range: match.range(at: 1))
    }

    applyDelimited(#"(?<!\*)\*\*([^\n*]+?)\*\*(?!\*)"#,
                   delimiterLength: 2,
                   raw: raw,
                   to: attributed) { range in
      attributed.addAttributes([.font: platformFont(size: fontSize, weight: .semibold)],
                               range: range)
    }

    applyDelimited(#"(?<!_)__([^\n_]+?)__(?!_)"#,
                   delimiterLength: 2,
                   raw: raw,
                   to: attributed) { range in
      attributed.addAttributes([.font: platformFont(size: fontSize, weight: .semibold)],
                               range: range)
    }

    applyDelimited(#"(?<!\*)\*([^\n*]+?)\*(?!\*)"#,
                   delimiterLength: 1,
                   raw: raw,
                   to: attributed) { range in
      attributed.addAttributes([.font: italicFont(size: fontSize)], range: range)
    }

    applyDelimited(#"(?<!_)_([^\n_]+?)_(?!_)"#,
                   delimiterLength: 1,
                   raw: raw,
                   to: attributed) { range in
      attributed.addAttributes([.font: italicFont(size: fontSize)], range: range)
    }

    applyDelimited(#"`([^`\n]+?)`"#,
                   delimiterLength: 1,
                   raw: raw,
                   to: attributed) { range in
      attributed.addAttributes([
        .font: monoFont(size: fontSize * 0.92),
        .backgroundColor: codeBackgroundColor
      ], range: range)
    }

    for match in matches(#"\[([^\]\n]+)\]\(([^\)\n]+)\)"#, raw: raw) {
      let label = match.range(at: 1)
      let target = match.range(at: 2)
      guard label.location != NSNotFound, target.location != NSNotFound else { continue }
      attributed.addAttributes([
        .font: platformFont(size: fontSize, weight: .semibold),
        .underlineStyle: NSUnderlineStyle.single.rawValue
      ], range: label)
      attributed.addAttributes([.foregroundColor: secondaryColor], range: target)
    }
  }

  static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 2
    paragraph.paragraphSpacing = 3
    return [
      .font: platformFont(size: fontSize, weight: .regular),
      .foregroundColor: primaryColor,
      .paragraphStyle: paragraph
    ]
  }

  private static func applyDelimited(_ pattern: String,
                                     delimiterLength: Int,
                                     raw: String,
                                     to attributed: NSMutableAttributedString,
                                     content: (NSRange) -> Void) {
    for match in matches(pattern, raw: raw) {
      let contentRange = match.range(at: 1)
      guard contentRange.location != NSNotFound else { continue }
      content(contentRange)

      let opening = NSRange(location: match.range.location, length: delimiterLength)
      let closing = NSRange(location: match.range.location + match.range.length - delimiterLength,
                            length: delimiterLength)
      attributed.addAttributes([.foregroundColor: secondaryColor], range: opening)
      attributed.addAttributes([.foregroundColor: secondaryColor], range: closing)
    }
  }

  private static func applyLineStyle(_ pattern: String,
                                     raw: String,
                                     to attributed: NSMutableAttributedString,
                                     style: (NSTextCheckingResult) -> Void) {
    for match in matches(pattern, raw: raw) {
      style(match)
    }
  }

  private static func matches(_ pattern: String, raw: String) -> [NSTextCheckingResult] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
    return regex.matches(in: raw, range: range)
  }

  #if os(iOS)
  private static var primaryColor: UIColor { .label }
  private static var secondaryColor: UIColor { .secondaryLabel }
  private static var codeBackgroundColor: UIColor { .tertiarySystemFill }

  private static func platformFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
    .systemFont(ofSize: size, weight: weight)
  }

  private static func italicFont(size: CGFloat) -> UIFont {
    .italicSystemFont(ofSize: size)
  }

  private static func monoFont(size: CGFloat) -> UIFont {
    .monospacedSystemFont(ofSize: size, weight: .regular)
  }
  #elseif os(macOS)
  private static var primaryColor: NSColor { .labelColor }
  private static var secondaryColor: NSColor { .secondaryLabelColor }
  private static var codeBackgroundColor: NSColor { .quaternaryLabelColor.withAlphaComponent(0.18) }

  private static func platformFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
  }

  private static func italicFont(size: CGFloat) -> NSFont {
    NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
  }

  private static func monoFont(size: CGFloat) -> NSFont {
    .monospacedSystemFont(ofSize: size, weight: .regular)
  }
  #endif
}

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

  /// The electives, in rail order. Each is fully described by the enum (icon /
  /// label / how it presents); per-attribute *values* are derived from the draft
  /// in `value(for:)` / `isSet(_:)`, and each editor lives in its own panel. So
  /// every pill is wired identically — one `ForEach`, one `select(_:)` — and the
  /// rail grows by adding a case, not another hand-written call.
  enum Attribute: Identifiable {
    // Notes IS an elective, but a special one: its pill only shows while notes
    // are empty/unrevealed; selecting it reveals the multi-line notes field
    // above the rail (see `TaskComposerCard.showsNotesField`) rather than
    // expanding an inline panel. Not part of `draftCases` — it's rendered
    // conditionally, like `.attachments`.
    case notes, when, deadline, repeatRule, list, attachments
    /// Edit-mode AI kickoff — rendered separately, not part of `draftCases`.
    case discuss
    var id: Self { self }

    /// Scheduling / filing electives — the `ForEach` rail.
    static let draftCases: [Attribute] = [.when, .deadline, .repeatRule, .list]

    var icon: String {
      switch self {
      case .notes:      "text.alignleft"
      case .when:       "calendar"
      case .deadline:   "flag"
      case .repeatRule: "repeat"
      case .list:       "folder"
      case .attachments:"paperclip"
      case .discuss:    "bubble.left.and.bubble.right"
      }
    }
    var label: String {
      switch self {
      case .notes:      "Notes"
      case .when:       "When"
      case .deadline:   "Deadline"
      case .repeatRule: "Repeat"
      case .list:       "List"
      case .attachments:"Attachments"
      case .discuss:    "Discuss"
      }
    }
    /// List opens a sheet — a rich, searchable area/project picker reused across
    /// the Tasks surfaces. Every other pill expands an inline panel under the rail.
    var presentsSheet: Bool { self == .list }
  }

  /// The currently expanded inline pill (never `.list`, which presents a sheet).
  @State private var expanded: Attribute?
  @State private var showingList = false
  @State private var discussStarted: Bool
  @State private var discussWorking = false

  init(draft: Binding<TaskDraft>, areas: [Area], projects: [Project], accent: Color,
       neutral: Bool = false, focus: FocusState<TaskEditFocus?>.Binding,
       activate: Binding<Attribute?>, discussTask: SeptenaTask? = nil,
       discussVisible: Binding<Bool> = .constant(false)) {
    _draft = draft
    self.areas = areas
    self.projects = projects
    self.accent = accent
    self.neutral = neutral
    _focus = focus
    _activate = activate
    self.discussTask = discussTask
    _discussVisible = discussVisible
    _discussStarted = State(initialValue: discussTask?.conversation.hasStarted ?? true)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Pills wrap onto extra rows as needed (FlowLayout) so every elective
      // stays visible — no offscreen horizontal scroll. "Today" isn't its own
      // pill: it's the same stored state as When=Today, so it lives inside the
      // When control (quick chip) instead of duplicating the rail. Flat
      // capsule fills (no floating glass) — these sit inline on the form card.
      FlowLayout(spacing: 8) {
        // Notes lead the rail, but only while collapsed — once the field is
        // revealed (notes present or focused) it hosts the notes instead, so
        // the pill and the field are never both on screen.
        if draft.notes.isEmpty, focus != .notes {
          AttributePill(icon: Attribute.notes.icon, label: Attribute.notes.label,
                        value: nil, isSet: false, isActive: false,
                        isFocused: focus == .pill(.notes),
                        accent: accent, neutral: neutral) { revealNotes() }
            .focused($focus, equals: .pill(.notes))
        }
        ForEach(Attribute.draftCases) { attr in
          AttributePill(icon: attr.icon, label: attr.label,
                        value: value(for: attr), isSet: isSet(attr),
                        isActive: expanded == attr, isFocused: focus == .pill(attr),
                        accent: accent, neutral: neutral) { select(attr) }
            .focused($focus, equals: .pill(attr))
        }
        if let task = discussTask {
          let count = SeptenaServices.shared.taskAttachmentStore.attachmentCount(taskID: task.id)
          AttributePill(icon: Attribute.attachments.icon, label: Attribute.attachments.label,
                        value: count == 0 ? nil : "\(count) file\(count == 1 ? "" : "s")",
                        isSet: count > 0, isActive: expanded == .attachments,
                        isFocused: focus == .pill(.attachments), accent: accent, neutral: neutral) {
            select(.attachments)
          }
          .focused($focus, equals: .pill(.attachments))
        }
        if showsDiscuss {
          AttributePill(icon: Attribute.discuss.icon, label: Attribute.discuss.label,
                        value: discussWorking ? "Thinking…" : nil,
                        isSet: discussWorking, isActive: false,
                        isFocused: focus == .pill(.discuss),
                        accent: accent, neutral: neutral) { select(.discuss) }
            .focused($focus, equals: .pill(.discuss))
            .disabled(discussWorking)
        }
      }

      inlineEditor
    }
    .onAppear(perform: reloadDiscussState)
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      reloadDiscussState()
    }
    .sheet(isPresented: $showingList) {
      MovePickerSheet(areas: areas, projects: projects,
                      currentAreaId: draft.areaId, currentProjectId: draft.projectId) { a, p in
        draft.areaId = a; draft.projectId = p
      }
      #if os(iOS)
      .presentationDetents([.large, .medium])
      #endif
    }
    // Keyboard Space / Return on a focused pill arrives here.
    .onChange(of: activate) { _, attr in
      guard let attr else { return }
      activate = nil
      select(attr)
    }
  }

  private var showsDiscuss: Bool {
    discussTask != nil && !discussStarted && OnDeviceAI.isAvailable
  }

  /// The value shown on a pill (its `nil` falls back to the plain label). All
  /// values are derived from the draft — the single read-side of the rail.
  private func value(for attr: Attribute) -> String? {
    switch attr {
    case .notes: return nil
    case .discuss: return nil
    case .attachments: return nil
    // "When" folds in Today: a task pinned to today (no date) reads "Today", a
    // future planning date reads its date, nothing set reads as Anytime (nil).
    case .when:
      if let s = draft.scheduled { return Self.dateLabel(s) }
      return draft.onToday ? "Today" : nil
    case .deadline:
      return draft.deadline.map(Self.dateLabel)
    case .repeatRule:
      return draft.recurrence?.shortLabel
    // The List pill always names its destination — "Inbox" by default, the area
    // or project once filed (but tinted only when explicitly filed, see isSet).
    case .list:
      return draft.listLabel(areas: areas, projects: projects)
    }
  }

  /// Whether a pill counts as "filled" — drives the accent tint.
  private func isSet(_ attr: Attribute) -> Bool {
    switch attr {
    case .notes:      !draft.notes.isEmpty
    case .discuss:    discussWorking
    case .attachments: discussTask.map { SeptenaServices.shared.taskAttachmentStore.attachmentCount(taskID: $0.id) > 0 } ?? false
    case .when:       draft.scheduled != nil || draft.onToday
    case .deadline:   draft.deadline != nil
    case .repeatRule: draft.recurrence != nil
    case .list:       draft.areaId != nil || draft.projectId != nil
    }
  }

  @ViewBuilder
  private var inlineEditor: some View {
    // One transition for every inline panel — they all slide down from the rail.
    Group {
      switch expanded {
      case .when:       InlineWhenPanel(draft: $draft, accent: accent)
      case .deadline:   InlineDatePanel(date: $draft.deadline, accent: accent)
      case .repeatRule: InlineRepeatPanel(recurrence: $draft.recurrence, accent: accent) {
        withAnimation(.snappy(duration: 0.22)) { expanded = nil }
      }
      case .attachments:
        if let task = discussTask { TaskAttachmentsPanel(taskID: task.id) }
      // Notes reveals a field above the rail, not an inline panel here.
      case .notes, .discuss, .list, .none: EmptyView()
      }
    }
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  /// The single dispatch for every pill: sheet-backed pills open their sheet,
  /// inline pills toggle the expanded panel. Per-attribute setup (Repeat seeding
  /// a default, Notes autofocusing) lives in each panel's `onAppear`, so this
  /// stays uniform.
  private func select(_ attr: Attribute) {
    if attr == .discuss {
      startDiscuss()
      return
    }
    // Move the keyboard cursor onto the pill (also drops the title field's
    // keyboard before a calendar opens — what `onInteractStart` used to do).
    focus = .pill(attr)
    withAnimation(.snappy(duration: 0.22)) {
      if attr.presentsSheet {
        expanded = nil
        showingList = true
      } else {
        expanded = (expanded == attr) ? nil : attr
      }
    }
  }

  /// Reveal the notes field above the rail and drop the keyboard cursor into
  /// it. `showsNotesField` keys off `focus == .notes`, so this both shows the
  /// field and focuses it in one move.
  private func revealNotes() {
    withAnimation(.snappy(duration: 0.22)) { focus = .notes }
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
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f.string(from: d)
  }
}

// MARK: - Pill

private struct AttributePill: View {
  let icon: String
  let label: String
  let value: String?
  let isSet: Bool
  let isActive: Bool
  /// The keyboard cursor is on this pill — draw the focus ring (the system ring
  /// never shows with macOS keyboard navigation off).
  var isFocused: Bool = false
  let accent: Color
  /// Monochrome rail (inline editor): filled/active pills wear a neutral gray
  /// capsule and the focus ring goes gray, so no section accent leaks into the
  /// open editor. See `TaskAttributeBar.neutral`.
  var neutral: Bool = false
  let action: () -> Void

  /// Capsule fill — flat surface, no floating-glass elevation shadow.
  private var capsuleFill: Color {
    guard isSet || isActive else { return Theme.mutedSurface }
    return neutral ? Theme.inkPrimary.opacity(0.10) : accent.opacity(0.42)
  }
  private var ringColor: Color { neutral ? Theme.selectionNeutral : accent }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: icon)
          .font(.system(size: 12, weight: .semibold))
        // Text follows the value when one exists (so the List pill can read
        // "Inbox" while still untinted); tint stays driven by `isSet`.
        Text(value ?? label)
          .font(.septenaLabel)
          .lineLimit(1)
      }
      .foregroundStyle(isSet ? Theme.inkPrimary : Theme.inkSecondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .background(Capsule().fill(capsuleFill))
    .overlay {
      Capsule()
        .strokeBorder(ringColor, lineWidth: 2)
        .opacity(isFocused ? 1 : 0)
        .allowsHitTesting(false)
    }
  }
}

// MARK: - Inline "When" editor

/// The scheduling control — the single home for Today and a planning date, so
/// neither needs its own pill. Quick chips (Today / Tomorrow / Weekend) sit
/// above a graphical calendar; picking today normalizes back to the
/// pinned-Today state. Leaving it unset keeps the task in Anytime. Expanded
/// under the When pill.
private struct InlineWhenPanel: View {
  @Binding var draft: TaskDraft
  let accent: Color
  @Environment(DayClock.self) private var clock

  private var cal: Calendar { Calendar.current }
  private var today: Date {
    cal.startOfDay(for: SeptenaDate.parse(clock.today) ?? clock.now)
  }
  private var tomorrow: Date { cal.date(byAdding: .day, value: 1, to: today) ?? today }
  /// Next Saturday.
  private var weekend: Date {
    var comps = DateComponents(); comps.weekday = 7
    let next = cal.nextDate(after: today, matching: comps, matchingPolicy: .nextTime) ?? today
    return cal.startOfDay(for: next)
  }

  private var isSet: Bool { draft.scheduled != nil || draft.onToday }

  private var calendarBinding: Binding<Date> {
    Binding(get: { draft.scheduled ?? today },
            set: { d in withAnimation(.snappy(duration: 0.2)) { draft.setScheduled(d) } })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        chip("Today", active: draft.onToday && draft.scheduled == nil) {
          draft.setToday()
        }
        chip("Tomorrow", active: isSameDay(draft.scheduled, tomorrow)) { draft.setScheduled(tomorrow) }
        chip("Weekend", active: isSameDay(draft.scheduled, weekend)) { draft.setScheduled(weekend) }
      }

      DatePicker("", selection: calendarBinding, displayedComponents: [.date])
        .datePickerStyle(.graphical)
        .tint(accent)

      if isSet {
        Button(role: .destructive) {
          withAnimation(.snappy(duration: 0.2)) { draft.clearWhen() }
        } label: {
          Label("Clear", systemImage: "xmark.circle").font(.septenaLabel)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.overdueRed)
      }
    }
    .padding(12)
    .background(Theme.secondaryGroupedBackground,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func isSameDay(_ a: Date?, _ b: Date) -> Bool {
    a.map { cal.isDate($0, inSameDayAs: b) } ?? false
  }

  @ViewBuilder
  private func chip(_ title: String, active: Bool, _ action: @escaping () -> Void) -> some View {
    Button { withAnimation(.snappy(duration: 0.2)) { action() } } label: {
      Text(title)
        .font(.septenaLabel)
        .foregroundStyle(active ? Theme.inkPrimary : Theme.inkSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .background(Capsule().fill(active ? accent.opacity(0.42) : Theme.mutedSurface))
  }
}

// MARK: - Inline date editor

/// A graphical calendar that writes a `Date?`. Selecting a day sets it;
/// "Clear" removes it. Lives inside the composer card when the Deadline pill
/// is expanded.
private struct InlineDatePanel: View {
  @Binding var date: Date?
  let accent: Color
  @Environment(DayClock.self) private var clock

  private var bound: Binding<Date> {
    let anchor = Calendar.current.startOfDay(
      for: SeptenaDate.parse(clock.today) ?? clock.now)
    return Binding(get: { date ?? anchor },
            set: { date = Calendar.current.startOfDay(for: $0) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      DatePicker("", selection: bound, displayedComponents: [.date])
        .datePickerStyle(.graphical)
        .tint(accent)
      if date != nil {
        Button(role: .destructive) {
          withAnimation(.snappy(duration: 0.2)) { date = nil }
        } label: {
          Label("Clear", systemImage: "xmark.circle")
            .font(.septenaLabel)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.overdueRed)
      }
    }
    .padding(12)
    .background(Theme.secondaryGroupedBackground,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

// MARK: - Inline repeat editor

/// Unit + interval + after-completion controls writing a `Recurrence?`, the
/// inline twin of `RecurrencePickerSheet`. Expanded under the Repeat pill.
private struct InlineRepeatPanel: View {
  @Binding var recurrence: Recurrence?
  let accent: Color
  /// Collapse the rail's expanded panel. "Don't Repeat" calls it (clear + close);
  /// owned by `TaskAttributeBar.expanded`.
  var onStop: () -> Void = {}

  /// True once the user actually picks a value here (or the task already
  /// repeated when the panel opened). A panel opened but left untouched reverts
  /// on close — so merely *peeking* at Repeat never commits a recurrence, and
  /// re-tapping the pill (or clicking away) cleanly undoes the open.
  @State private var confirmed = false

  /// Every control write goes through here so any real interaction marks the
  /// recurrence as confirmed (and thus kept on close).
  private func write(_ r: Recurrence) { recurrence = r; confirmed = true }

  private var unit: Binding<Recurrence.Unit> {
    Binding(get: { recurrence?.unit ?? .week },
            set: { write(Recurrence(unit: $0, interval: recurrence?.interval ?? 1,
                                    afterCompletion: recurrence?.afterCompletion ?? true)) })
  }
  private var interval: Binding<Int> {
    Binding(get: { recurrence?.interval ?? 1 },
            set: { write(Recurrence(unit: recurrence?.unit ?? .week, interval: $0,
                                    afterCompletion: recurrence?.afterCompletion ?? true)) })
  }
  private var afterCompletion: Binding<Bool> {
    Binding(get: { recurrence?.afterCompletion ?? true },
            set: { write(Recurrence(unit: recurrence?.unit ?? .week,
                                    interval: recurrence?.interval ?? 1, afterCompletion: $0)) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Unit", selection: unit) {
        Text("Day").tag(Recurrence.Unit.day)
        Text("Week").tag(Recurrence.Unit.week)
        Text("Month").tag(Recurrence.Unit.month)
      }
      .pickerStyle(.segmented)

      Stepper(value: interval, in: 1...99) {
        Text("Every \(intervalLabel())")
          .font(.septenaSidebarRow)
          .foregroundStyle(Theme.inkPrimary)
      }

      Toggle("After completion", isOn: afterCompletion)
        .font(.septenaSidebarRow)
        .tint(accent)

      Button(role: .destructive) {
        recurrence = nil
        confirmed = true   // explicit clear; don't let onDisappear second-guess it
        onStop()
      } label: {
        Label("Don't Repeat", systemImage: "xmark.circle")
          .font(.septenaLabel)
      }
      .buttonStyle(.plain)
      .foregroundStyle(Theme.overdueRed)
    }
    .padding(12)
    .background(Theme.secondaryGroupedBackground,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    // Opening shows a weekly preview so the controls have something to bind, but
    // it's only a peek: `confirmed` stays false until a real edit, and an
    // untouched panel reverts to "no repeat" on close (`onDisappear`). A task
    // that already repeated counts as confirmed, so editing never loses it.
    .onAppear {
      if recurrence == nil { recurrence = Recurrence(unit: .week); confirmed = false }
      else { confirmed = true }
    }
    .onDisappear { if !confirmed { recurrence = nil } }
  }

  /// Pluralized "N days/weeks/months" via the String Catalog (one/other).
  private func intervalLabel() -> String {
    let n = interval.wrappedValue
    switch recurrence?.unit ?? .week {
    case .day:   return String(localized: "\(n) days")
    case .week:  return String(localized: "\(n) weeks")
    case .month: return String(localized: "\(n) months")
    }
  }
}

// MARK: - Inline notes editor

/// A multi-line notes field that writes `draft.notes`, expanded under the Notes
/// pill. Autofocuses on appear (you tapped the pill to write), and offers a
/// "Clear" when there's text — the same shape as the When / Deadline panels.
// MARK: - Presentation

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
