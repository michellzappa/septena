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
  /// A checklist step, by item id (edit mode, between notes and the rail).
  case step(String)
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
  /// `.page` is the task page pushed onto the iPhone navigation stack (ADR
  /// 0029): every page block, no Cancel/Save chrome, autosaving on Back.
  enum Presentation { case drawer, inline, page }

  let mode: Mode
  let areas: [Area]
  let projects: [Project]
  let accent: Color
  let presentation: Presentation
  /// The inline host already inserted this edit-mode task as a local-only
  /// placeholder for row identity. Intent remains CREATE; this storage detail
  /// must not enable edit-only behavior or disable create-only behavior.
  let deferredCreate: Bool
  /// True when composing inside a project view: committing a new task titled
  /// `# <Heading>` converts it into a project heading (#209). False everywhere
  /// else, where headings are not supported.
  var allowsHeadingPrefix: Bool = false
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
  #if os(iOS)
  /// The inline title still has to open the keyboard. The inline title is a
  /// UIKit text view with no `.focused(_, equals: .title)`, so SwiftUI drops a
  /// programmatic `focus = .title` and a new task opened without a keyboard.
  /// The text view reads this, becomes first responder and clears it. It lives
  /// here, not in the view, so a row that scrolls out of the `LazyVStack` and
  /// back does not take the keyboard again.
  @State private var titleFocusPending = false
  #endif
  /// One-shot trigger: set to a pill to make `TaskAttributeBar` run its
  /// `select` for that pill (keyboard Space/Return on a focused pill). The bar
  /// resets it to nil after acting.
  @State private var pendingPillActivate: TaskAttributeBar.Attribute?
  /// Escape saves and closes, exactly like tapping away (product decision:
  /// every way out of the editor keeps the work; undo takes it back). One
  /// keystroke can arrive through several handlers, so this latch makes the
  /// close run once per editing session.
  @State private var keyboardCloseInFlight = false
  /// The inline-create placeholder records ONE create on the undo stack, at its
  /// first save. Later saves in the same session are still authoring.
  @State private var recordedCreateUndo = false
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
  /// A `# Heading` new-task draft inside a project has been converted into a
  /// heading and its placeholder purged (#209). Terminal for this session so
  /// teardown never creates a duplicate heading.
  @State private var convertedToHeading = false
  /// SuggestionEngine's learned area/project pick for the current title (the
  /// "Suggested" chip). Recomputed as the title changes; create-mode only.
  @State private var suggestedList: SuggestionEngine.Suggestion?
  /// Mirrors whether the Discuss pill is on the rail (edit mode, no thread yet).
  @State private var discussKickoffVisible = false
  /// The clipboard held text when this blank new task opened, so the Paste
  /// chip is on offer (#210). Checked once per seed with `hasText`, which
  /// never reads the clipboard, so no iOS paste-permission alert appears.
  /// Cleared by a paste or by the first keystroke.
  @State private var pasteOffered = false
  /// Images the Paste chip took from the clipboard, held until the task
  /// exists, then written as attachments (`attachPastedImages`).
  @State private var pastedImages: [PastedImage] = []
  /// Shown under the pasted images when a paste could not be used.
  @State private var pasteError: String?

  init(mode: Mode, areas: [Area], projects: [Project], accent: Color,
       presentation: Presentation = .drawer, deferredCreate: Bool = false,
       allowsHeadingPrefix: Bool = false,
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
    self.allowsHeadingPrefix = allowsHeadingPrefix
    self.onClose = onClose
    self.onToggleComplete = onToggleComplete
    self.titleMatchID = titleMatchID
    self.checkboxMatchID = checkboxMatchID
    self.heroMatchNS = heroMatchNS
    self.heroMatchIsSource = heroMatchIsSource
    self.showsTodayIndicator = showsTodayIndicator
    self.onDone = onDone
    self.onVanish = onVanish
    if case .edit(let task) = mode {
      // Seed the initial draft synchronously before the first render pass so
      // inline editing never flashes an empty 1-line title before `.onAppear`
      // populates it (which caused a 2-frame vertical jump on open).
      let initial = TaskDraft(task: task)
      _draft = State(initialValue: initial)
      _seededDraft = State(initialValue: initial)
    }
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

  private var headerTitle: String { isEditing ? "Edit Task" : RegistryActions.title(.appNewTask) }
  private var saveTitle: String { isEditing ? "Save" : "Add" }

  /// Close: fold the inline editor (`onClose`) when hosted inline, else go
  /// through the docked-inspector hook with a sheet `dismiss()` fallback — the
  /// same close path `AdaptiveEditScaffold` uses, so terminal actions match.
  private func close() { (onClose ?? adaptiveClose ?? { dismiss() })() }

  /// Escape, and the keyboard toolbar's Done: save and close. Tapping away and
  /// scrolling away already save, so Escape must not be the one exit that asks
  /// "Discard?". An empty new task just closes (the host drops the blank
  /// placeholder). Undo takes a save back.
  ///
  /// One Escape keystroke can reach this from several handlers at once: the
  /// container's key press, the title field's own copy (a TextField would
  /// otherwise swallow it), and AppKit's exit command on macOS. The latch makes
  /// the duplicates no-ops, so a drawer can never be dismissed twice.
  private func saveAndCloseFromKeyboard() {
    guard !keyboardCloseInFlight, !discarded else { return }
    keyboardCloseInFlight = true
    persistOnce()
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
      // Escape saves and closes, like every other way out of the editor (undo
      // takes it back). On macOS the field editor consumes Escape, so carry
      // both the AppKit exit command and SwiftUI key press forms. (In the
      // drawer, the scaffold's Cancel button also binds Escape and keeps its
      // own discard contract; that chrome lives in SectionDrawer.swift.)
      .septenaOnEscape(saveAndCloseFromKeyboard)
      .onKeyPress(.escape) { saveAndCloseFromKeyboard(); return .handled }
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
      // `onVanish` is the host's licence to purge an inline-create draft that
      // was never titled — so it fires only when there is genuinely no title
      // to lose. A draft the user DID type into is never offered for purging,
      // whatever the store currently shows: if its write was rolled back the
      // store reads empty, and handing that to the host destroyed the task.
      .onDisappear {
        let landed = persistOnce()
        if !canSave || landed { onVanish?() }
      }
      .onChange(of: draft.title) { oldValue, newValue in
        // A title is one line, so a line break in the field is never text —
        // it is one of two gestures, and they end differently:
        //
        //   Return — a vertical-axis TextField turns Return into a newline at
        //     the caret; we treat that as "save". Remove the break ENTIRELY
        //     (not a space) so the title is exactly what it was before Enter —
        //     a space, then trimming only the ends, left a stray gap wherever
        //     the caret sat mid-title. A typed Return is the ONLY change in
        //     the value, which is exactly how it is told apart from a paste.
        //
        //   Paste — a multi-line clipboard string. Flatten it to one line here
        //     so the field never *shows* a break (the row is laid out for one
        //     line), joining the lines with a space so the words don't fuse.
        //     A paste must NOT commit: the user is still editing.
        // Typing hides the Paste chip (#210). One flag write per editing
        // session; later keystrokes skip it.
        if pasteOffered, !newValue.isEmpty { pasteOffered = false }
        guard newValue.contains(where: \.isNewline) else { updateSuggestion(); return }
        if TaskTitleText.withoutLineBreaks(newValue) == oldValue {
          draft.title = TaskTitleText.withoutLineBreaks(newValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if canSave { commit(); return }
          // Return on an empty NEW task closes it (its draft is then purged).
          if isCreating { close(); return }
        } else {
          draft.title = TaskTitleText.singleLine(newValue)
        }
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
        #if os(iOS)
        // The only way to put the keyboard away without leaving the row was
        // to tap elsewhere. Done saves and closes, the same as Escape. (The
        // notes field is a UIKit text view, which SwiftUI's keyboard toolbar
        // does not reach, so it carries its own Done — see `notesField`.)
        .toolbar {
          ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { saveAndCloseFromKeyboard() }
              .fontWeight(.semibold)
          }
        }
        #endif
    case .drawer:
      drawerBody
    case .page:
      ScrollView {
        formBody
      }
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle(headerTitle)
      .septenaInlineTitle()
    }
  }

  /// The task page depth this host shows (ADR 0029): the row editor is the
  /// quick edit, the drawer and the pushed page are the full page.
  /// A task waiting for the user to accept it opens at the review depth: the
  /// title, notes, the conversation (with Accept and Send back) and who added
  /// it, without the edit rows.
  private var pageDepth: RegistryTaskPageDepth {
    if presentation == .inline { return .inline }
    if editingTask?.conversation.needsHumanReview == true { return .review }
    return .page
  }

  /// "Area › Project", the area, or the Inbox, for the review depth.
  private var reviewListLabel: String {
    if let pid = draft.projectId, let project = projects.first(where: { $0.id == pid }) {
      if let aid = project.area, let area = areas.first(where: { $0.id == aid }) {
        return "\(area.title) › \(project.title)"
      }
      return project.title
    }
    return draft.listLabel(areas: areas, projects: projects)
  }

  /// The blocks to render, in registry order. A create, or an inline create
  /// held as a placeholder row, has no saved task, so `editOnly` blocks drop.
  private var pageBlocks: [RegistryTaskPageBlock] {
    RegistrySurfaces.taskPageBlocks(pageDepth, on: RegistryPlatform.current,
                                    isEditing: editingTask != nil && !deferredCreate)
  }

  /// One renderer per block kind. Each branch is type-erased: a large
  /// `@ViewBuilder` switch nests into one deep generic type, which overflowed
  /// the iOS main-thread stack at launch once before (AGENTS.md).
  private func blockView(_ block: RegistryTaskPageBlock, kinds: Set<RegistryTaskPageBlockKind>) -> AnyView {
    switch block.kind {
    case .header:
      return AnyView(EmptyView()) // drawn above the indented column, see `formBody`
    case .notes:
      return AnyView(VStack(alignment: .leading, spacing: presentation == .inline ? 10 : 14) {
        notesField
        quickEntryChips
        pastedImagesStrip
      })
    case .attributes:
      // The bar hosts the checklist, attachments, references and history panels; their blocks
      // gate them (`kinds`), so the registry decides where they show.
      return AnyView(TaskAttributeBar(
        draft: $draft,
        areas: areas,
        projects: projects,
        accent: accent,
        neutral: presentation == .inline,
        focus: $focus,
        activate: $pendingPillActivate,
        discussTask: editingTask,
        discussVisible: $discussKickoffVisible,
        moveFocus: { moveFocus(forward: $0) },
        showsChecklist: kinds.contains(.checklist),
        showsAttachments: kinds.contains(.attachments),
        showsReferences: kinds.contains(.references),
        showsHistory: kinds.contains(.history),
        // On the page the conversation runs inside the Discuss card.
        showsConversation: pageDepth == .page && kinds.contains(.conversation),
        // Paste leads the rail when it shows, as on the Mac composer: the
        // registry lists it first (`taskAttributes` `paste`, tier `chip`).
        leading: showsPasteChip ? AnyView(pasteChip) : nil,
        // The quick edit keeps the pill rail; the page lays the attributes
        // out as a column of rows with checklist and attachments as sections.
        layout: pageDepth == .page ? .rows : .rail
      ))
    case .checklist, .attachments, .references:
      return AnyView(EmptyView()) // rendered by the attribute bar, see `.attributes`
    case .history:
      // On the page, history is its own section in registry order.
      guard let task = editingTask, TaskHistory.isAvailable else { return AnyView(EmptyView()) }
      return AnyView(VStack(alignment: .leading, spacing: 8) {
        Text(block.label ?? "")
          .font(.septenaLabel)
          .foregroundStyle(Theme.inkSecondary)
        TaskHistoryPanel(taskID: task.id)
      })
    case .conversation:
      // The page's attribute column holds it, inside the Discuss card.
      if pageDepth == .page && kinds.contains(.attributes) { return AnyView(EmptyView()) }
      guard let task = editingTask else { return AnyView(EmptyView()) }
      return AnyView(ConversationSection(task: task, accent: accent))
    case .provenance:
      // Who added the task and when: permanent metadata, read-only.
      guard let task = editingTask else { return AnyView(EmptyView()) }
      return AnyView(TaskProvenanceSection(task: task, label: block.label ?? ""))
    }
  }

  /// The standard adaptive edit drawer: a grouped sheet on iPhone, a docked
  /// inspector on iPad/macOS, Close/Save chrome owned by the scaffold.
  private var drawerBody: some View {
    AdaptiveEditScaffold(
      title: headerTitle,
      // Standard two-control chrome: an explicit commit (Add / Save) and a
      // close (x). Close discards, but only through a confirmation when the
      // form is dirty, and the scaffold blocks swipe-to-dismiss while dirty, so
      // the ONLY way to lose a task is an explicit Close → Discard.
      saveTitle: saveTitle,
      showsSave: true,
      accent: accent,
      canSave: canSave,
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
    // The blocks come from the registry (`surfaces.json` `taskPage`, ADR 0029):
    // their order and the depth each shows at. Inline is the quick edit; the
    // drawer and the pushed page add the conversation and the history.
    let blocks = pageBlocks
    let kinds = Set(blocks.map(\.kind))
    return VStack(alignment: .leading, spacing: inline ? 10 : 14) {
      if kinds.contains(.header) { titleNotesCard }
      // The review depth has no List row: name where the task lives, read-only.
      if pageDepth == .review {
        Label(reviewListLabel, systemImage: RegistrySurfaces.taskAttribute(.list).sfSymbol)
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
      }

      VStack(alignment: .leading, spacing: inline ? 10 : 14) {
        // Header draws above this column; checklist, attachments and references draw
        // inside the attribute bar. History draws here on the page only (the
        // inline depth has no history block).
        ForEach(blocks.filter { ![.header, .checklist, .attachments, .references].contains($0.kind) }) { block in
          blockView(block, kinds: kinds)
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
    // Sanctioned exception to the "never bind Space on a task surface" rule:
    // this is the COMPOSER's own Tab focus loop, not a selected list row.
    // `activateFocused()` returns .ignored unless a pill actually holds the
    // cursor, so Space never reaches the row checkbox behind an inline
    // composer — it fires a pill the user tabbed to, and nothing otherwise.
    .onKeyPress(.space) { activateFocused() }  // septena-lint:allow task-space-binding
    .onKeyPress(.return) { activateFocused() }
  }

  // MARK: - Title / notes

  @ViewBuilder
  private var titleNotesCard: some View {
    // Title sits at the top; the notes field always sits directly below it.
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

  @ViewBuilder
  private var titleField: some View {
    #if os(iOS)
    if presentation == .inline {
      // Non-scrolling UIKit text view with zero `textContainerInset` and zero
      // `lineFragmentPadding` using the exact Dynamic Type `.body` font.
      // SwiftUI's `TextField(..., axis: .vertical)` wraps an opaque scrolling
      // `UITextView` that adds internal vertical insets and shifts its
      // `contentOffset` up then down as first responder settles — replacing it
      // here keeps the closed `Text` and open editor on the exact same line.
      InlineTitleTextView(
        text: $draft.title,
        isFocused: Binding(
          get: { focus == .title },
          set: { focused in
            if focused { focus = .title }
            else if focus == .title { focus = nil }
          }
        ),
        focusPending: $titleFocusPending,
        onSubmit: {
          if canSave { commit() } else if isCreating { close() }
        },
        onDone: { saveAndCloseFromKeyboard() },
        onTab: { forward in moveFocus(from: .title, forward: forward) },
        onEscape: { saveAndCloseFromKeyboard() }
      )
      .frame(minHeight: Theme.checkboxTap, alignment: .center)
    } else {
      swiftUITitleField
    }
    #else
    swiftUITitleField
    #endif
  }

  private var swiftUITitleField: some View {
    // ONE field identity, one lineLimit. A ClosedRange (`1...2`) reserves two
    // lines even when empty, and flipping `1...1` ↔ `1...2` from wrap-detection
    // rebuilt the focused field mid-keystroke — SwiftUI then drops the caret
    // at the end ("cursor jumps to the far right while typing or arrowing").
    // `lineLimit(2)` is a max, matching the closed row, so the field stays
    // one line until the title actually wraps.
    TextField("", text: $draft.title, axis: .vertical)
      .lineLimit(2)
      .textFieldStyle(.plain)
      .font(.septenaTaskTitle)
      // Match the closed row's title `Text` box so the two center-align to the
      // same place: `.fixedSize` gives the field the same tight vertical box a
      // `Text` has, and the shared band (`Theme.checkboxTap`, centered) makes the
      // closed `Text` and this `TextField` occupy an identical box on the same
      // checkbox line. Inline only.
      .fixedSize(horizontal: false, vertical: true)
      .frame(minHeight: presentation == .inline ? Theme.checkboxTap : 0,
             alignment: .center)
      #if os(macOS)
      .focusEffectDisabled(presentation == .inline)
      #endif
      .focused($focus, equals: .title)
      // macOS: a vertical-axis field fires onSubmit on plain Return (the iOS
      // newline-as-save trick never triggers there) — commit here instead.
      .onSubmit {
        if canSave { commit() } else if isCreating { close() }
      }
      // The field would otherwise swallow Tab, so carry the same focus-cycling
      // handler here too.
      .onKeyPress(keys: [.tab]) { press in
        moveFocus(forward: !press.modifiers.contains(.shift)); return .handled
      }
      // macOS only: the field editor consumes Escape before the container's
      // handler sees it. `saveAndCloseFromKeyboard` is idempotent, so the overlap
      // with the container binding is harmless.
      .septenaOnEscape(saveAndCloseFromKeyboard)
  }

  /// Notes — a multi-line field sitting directly under the title (Things-style),
  /// always visible (no Notes pill) with a quiet "Notes" placeholder when empty.
  /// Return inserts a newline here (it's prose), so — unlike the title — there's
  /// no Return-to-save; Tab still cycles focus.
  @ViewBuilder
  private var notesField: some View {
    let editor = TaskMarkdownNotesEditor(
      text: $draft.notes, focus: $focus,
      onDone: presentation == .inline ? { saveAndCloseFromKeyboard() } : nil,
      // The page shows notes as a visible text area: a taller box the whole
      // of which takes a tap. The quick edit keeps the one-line field and caps
      // growth at ~5 lines so long notes don't take over the card.
      minHeight: pageDepth != .inline ? 120 : 28,
      maxHeight: pageDepth != .inline ? 360 : 120
    )
      .onKeyPress(keys: [.tab]) { press in
        moveFocus(forward: !press.modifiers.contains(.shift)); return .handled
      }
    if pageDepth != .inline {
      editor
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.secondaryGroupedBackground,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(focusRing(visible: focus == .notes, cornerRadius: 18))
    } else {
      // A little extra right margin so wrapped prose doesn't run to the card edge.
      editor.padding(.trailing, 12)
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
  /// Non-nil when this new-task draft inside a project should convert into a
  /// heading on commit (`# Design` → `Design`, issue #209). Never fires outside
  /// projects, never on edits of existing tasks, and never on `## ` or `# `.
  private var headingPrefixMatch: (title: String, projectId: String)? {
    guard allowsHeadingPrefix, isCreating, let projectId = draft.projectId else { return nil }
    guard let title = TaskTitleText.headingPrefixTitle(draft.title) else { return nil }
    return (title, projectId)
  }

  private var detectedTokens: [DetectedToken] {
    guard isCreating, headingPrefixMatch == nil else { return [] }
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
          chip(icon: token.icon, customIcon: tokenCustomIcon(for: token),
               leading: "plus", text: token.displayText) { apply(token) }
        }
        if let s = suggestion {
          chip(icon: s.kind == .project ? "number" : "folder",
               customIcon: suggestionCustomIcon(for: s),
               leading: "lightbulb", text: s.title) { applySuggestedList() }
        }
      }
      .transition(.opacity)
    }
  }

  private func tokenCustomIcon(for token: DetectedToken) -> AnyView? {
    switch token.kind {
    case .area(let id, _):
      let emoji = areas.first(where: { $0.id == id })?.emoji
      return AnyView(AreaIcon(tint: accent, diameter: 14, emoji: emoji))
    case .project(let id, _):
      let progress = LocalCache.projectCompletionRatios(
        in: LocalStore.shared.container.mainContext)[id] ?? 0
      return AnyView(ProjectProgressIcon(progress: progress, tint: accent, diameter: 11, lineWidth: 1.8))
    case .today, .date:
      return nil
    }
  }

  private func suggestionCustomIcon(for suggestion: SuggestionEngine.Suggestion) -> AnyView {
    switch suggestion.kind {
    case .area:
      let emoji = areas.first(where: { $0.id == suggestion.id })?.emoji
      return AnyView(AreaIcon(tint: accent, diameter: 14, emoji: emoji))
    case .project:
      let progress = LocalCache.projectCompletionRatios(
        in: LocalStore.shared.container.mainContext)[suggestion.id] ?? 0
      return AnyView(ProjectProgressIcon(progress: progress, tint: accent, diameter: 11, lineWidth: 1.8))
    }
  }

  /// A small glass action chip: a leading hint glyph (`plus` to add a parsed
  /// token, `lightbulb` for the smart suggestion), the field's icon, and a label.
  private func chip(icon: String, customIcon: AnyView? = nil, leading: String, text: String,
                    _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: leading).font(.system(size: 10, weight: .bold))
        if let customIcon {
          customIcon
        } else {
          Image(systemName: icon).font(.system(size: 11, weight: .semibold))
        }
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

  // MARK: - Paste chip (#210)

  /// Blank new task, clipboard had text at open, nothing typed yet.
  private var showsPasteChip: Bool {
    pasteOffered && isCreating && draft.title.isEmpty && draft.notes.isEmpty
      && pastedImages.isEmpty
  }

  /// A new task can be saved once it has a title, or when it is a pasted
  /// image alone (it then takes the title "Image", `titleImageOnlyDraft`).
  private var canSave: Bool {
    draft.canSave || (isCreating && !pastedImages.isEmpty)
  }

  /// The Paste chip. Label and icon come from the registry
  /// (`taskAttributes` `paste`, tier `chip`).
  @ViewBuilder
  private var pasteChip: some View {
    #if os(iOS)
    // iOS: the system `PasteButton` reads the clipboard with the user's tap
    // as consent, so no paste-permission alert appears. It draws its own
    // system "Paste" label and clipboard glyph.
    // It is a secure system control: iOS draws it and limits its styling to
    // shape, label style, size, tint and button style. Regular size matches
    // the rail pills' 34pt height; the glass style matches their material;
    // blue sets the clipboard action apart from the task's own attributes.
    PasteButton(supportedContentTypes: [.image, .plainText]) { providers in
      Task { @MainActor in await applyPaste(providers) }
    }
    .buttonBorderShape(.capsule)
    .labelStyle(.titleAndIcon)
    .controlSize(.regular)
    .buttonStyle(.glass)
    .tint(.blue)
    #else
    let attr = RegistrySurfaces.taskAttribute(.paste)
    Button {
      if let image = PastedImage.fromGeneralPasteboard() {
        applyPastedImage(image)
      } else if let text = NSPasteboard.general.string(forType: .string) {
        applyPaste(text)
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: attr.sfSymbol).font(.system(size: 11, weight: .semibold))
        Text(verbatim: attr.label).font(.septenaLabel).lineLimit(1)
      }
      .foregroundStyle(accent)
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .background(Capsule().fill(accent.opacity(0.28)))
    #endif
  }

  /// What the iOS `PasteButton` delivered. An image wins over text: an image
  /// copied from a web page also carries its URL as text, and that URL is
  /// not a title.
  private func applyPaste(_ providers: [NSItemProvider]) async {
    if let image = await PastedImage.load(from: providers) {
      applyPastedImage(image)
    } else if let text = await PastedImage.loadText(from: providers) {
      applyPaste(text)
    } else {
      pasteOffered = false
      Haptics.warning()
      pasteError = String(localized: "Nothing on the clipboard could be pasted.",
                          comment: "New task: the Paste chip found no text or image")
    }
  }

  /// Hold a clipboard image for the new task and show it. It is written as
  /// an attachment when the task saves.
  private func applyPastedImage(_ image: PastedImage) {
    pasteOffered = false
    guard image.fitsAttachmentLimit else {
      Haptics.warning()
      pasteError = String(localized: "Attachments must be 25 MB or smaller.")
      return
    }
    pasteError = nil
    Haptics.selection()
    a11yAnimate(.snappy(duration: 0.2)) { pastedImages.append(image) }
    focusTitle()
  }

  /// A new task made from a pasted image alone gets the title "Image", so it
  /// saves like any titled task instead of reading as an empty draft.
  private func titleImageOnlyDraft() {
    guard draft.trimmedTitle.isEmpty, !pastedImages.isEmpty else { return }
    draft.title = String(localized: "Image", comment: "Title of a new task made from a pasted image")
  }

  /// Write the held images onto the task that now exists, then forget them.
  private func attachPastedImages(to taskID: String) {
    guard !pastedImages.isEmpty else { return }
    let store = SeptenaServices.shared.taskAttachmentStore
    for image in pastedImages {
      do {
        try store.add(taskID: taskID, data: image.data,
                      filename: image.filename, contentType: image.type.identifier)
      } catch {
        Log.persistence.error("Pasted image not attached: \(error.localizedDescription, privacy: .public)")
      }
    }
    pastedImages = []
  }

  /// The pasted images, each with a remove button, under the quick-entry
  /// chips. Empty (no view) when nothing was pasted.
  @ViewBuilder
  private var pastedImagesStrip: some View {
    if !pastedImages.isEmpty || pasteError != nil {
      VStack(alignment: .leading, spacing: 6) {
        if !pastedImages.isEmpty {
          HStack(spacing: 8) {
            ForEach(pastedImages) { image in
              AttachmentThumbnail(source: .data(image.data), key: image.id.uuidString, side: 64)
                .overlay(alignment: .topTrailing) {
                  Button {
                    Haptics.commit()
                    a11yAnimate(.snappy(duration: 0.2)) {
                      pastedImages.removeAll { $0.id == image.id }
                    }
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                      .symbolRenderingMode(.palette)
                      .foregroundStyle(.white, .black.opacity(0.6))
                      .padding(3)
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel(Text("Remove image"))
                }
            }
          }
        }
        if let pasteError {
          Text(pasteError).font(.caption).foregroundStyle(.red)
        }
      }
      .transition(.opacity)
    }
  }

  /// Fill the blank draft from clipboard text (`TaskTitleText.pasteSplit`)
  /// and retire the chip. Does not commit: the user is still composing.
  private func applyPaste(_ text: String) {
    pasteOffered = false
    guard let split = TaskTitleText.pasteSplit(text) else { return }
    Haptics.selection()
    a11yAnimate(.snappy(duration: 0.2)) {
      draft.title = split.title
      if let notes = split.notes { draft.notes = notes }
    }
    updateSuggestion()
    focusTitle()
  }

  private func applySuggestedList() {
    guard let s = suggestedList else { return }
    Haptics.selection()
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
    Haptics.selection()
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
    convertedToHeading = false
    keyboardCloseInFlight = false
    recordedCreateUndo = false
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
      let initial = TaskDraft(task: task)
      if draft != initial { draft = initial }
      // Snapshot the seeded draft as the dirty baseline — the SAME approach as
      // create mode. Comparing the whole struct against its own seed is immune to
      // the per-field normalization subtleties of `differs(from:)` (computed
      // `storedScheduled`/`pinToday`, trimmed-vs-raw title) that were leaving an
      // untouched peek reading "dirty" and wrongly prompting "Discard changes?".
      seededDraft = initial
      // Note: opening the editor must NOT acknowledge. The agent cue == triage-
      // band membership for agent rows, so acknowledging here would silently
      // ratify an unclassified proposal the moment you peek at it — it would
      // vanish from the Inbox on dismiss with no decision made. Ratification
      // happens on Save, and only when the edit actually (re)places it (see
      // `persist`).
      // Opening a faded task keeps it (`docs/TASK_FADE_SPEC.md` §4): clears
      // `fadedAt`, stamps `touchedAt`, and records undo.
      if !deferredCreate, task.isFaded {
        let snap = TaskUndo.FadedSnapshot(task)
        mutator.keepFaded(ids: [task.id])
        TaskUndo.recordKeepFaded(before: [snap], mutator: mutator)
      }
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
      //
      // On iOS, opening an EXISTING task never raises the keyboard (inline or
      // inspector): you're reviewing it, and a tap on a field edits. Only a
      // new inline task (the deferred-create placeholder) focuses its title.
      // macOS has no on-screen keyboard to fight, so it keeps the "open with
      // Return, type at once" focus.
      #if os(macOS)
      if useInspector || presentation == .inline {
        if presentation == .inline {
          // Inline opens instantly with no sheet animation to wait for.
          DispatchQueue.main.async { focusTitle() }
        } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focusTitle() }
        }
      }
      #else
      if deferredCreate {
        if presentation == .inline {
          // Inline opens instantly — focus on the next runloop turn rather
          // than letting the row sit unfocused for 0.4s and then settle.
          DispatchQueue.main.async { focusTitle() }
        } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focusTitle() }
        }
      }
      #endif
    }
    pasteOffered = isCreating && draft.title.isEmpty && draft.notes.isEmpty
      && SeptenaPasteboard.hasPasteable
  }

  /// Move keyboard focus into the title field and — on macOS — collapse
  /// AppKit's default select-all to a caret at the END. Skipped entirely when
  /// the field is already focused: a delayed autofocus used to fire ~0.4s after
  /// open and yank the caret to the far right if the user had already tapped
  /// or started typing.
  private func focusTitle() {
    guard focus != .title else { return }
    #if os(iOS)
    if presentation == .inline {
      titleFocusPending = true
      return
    }
    #endif
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
  ///
  /// Returns false when the title write was rolled back, so `persistOnce` can
  /// avoid recording a failed write as the last persisted state.
  @discardableResult
  private func persist() -> Bool {
    // Commit against the mode the draft was SEEDED from (see `seededMode`), so
    // a mid-flight subject swap flushes the outgoing edit into the right task.
    switch seededMode ?? mode {
    case .create:
      if let match = headingPrefixMatch {
        if let created = mutator.createHeading(title: match.title, project: match.projectId) {
          TaskUndo.recordHeadingCreate(id: created.id, title: match.title,
                                       project: match.projectId, position: created.position,
                                       mutator: mutator)
        }
        convertedToHeading = true
        return true
      }
      applyPendingTokens()
      titleImageOnlyDraft()
      let created = draft.create(via: mutator)
      attachPastedImages(to: created.id)
      recordCreateUndo(id: created.id)
      return true
    case .edit(let task):
      if seededDeferredCreate {
        if let match = headingPrefixMatch {
          if let created = mutator.createHeading(title: match.title, project: match.projectId,
                                                 afterHeadingID: task.heading) {
            TaskUndo.recordHeadingCreate(id: created.id, title: match.title,
                                         project: match.projectId, position: created.position,
                                         mutator: mutator)
          }
          mutator.purge(id: task.id)
          convertedToHeading = true
          recordedCreateUndo = true
          return true
        }
        // Same create pipeline as the drawer, except the inline host already
        // inserted a push-deferred entity for layout identity. Updating its
        // title releases the first CloudKit push.
        applyPendingTokens()
        titleImageOnlyDraft()
        let landed = draft.update(task, via: mutator)
        if landed { attachPastedImages(to: task.id) }
        // Register the create undo only once the title landed: an "un-create"
        // for a rolled-back write would purge a task the user never got.
        if landed, !recordedCreateUndo {
          recordedCreateUndo = true
          recordCreateUndo(id: task.id)
        }
        return landed
      }
      // Ratify (acknowledge → leave the Inbox) only when this save actually
      // (re)placed the task — gave it a project/area, a date, or a Today pin
      // (the same fields that take a row out of the triage band). A bare title /
      // notes edit, or just opening to peek, is not a placement decision and
      // must keep an agent proposal in the Inbox. No-op for non-agent /
      // already-seen rows.
      let placed = draft.placementChanged(from: task)
      let landed = draft.update(task, via: mutator, undoContext: modelContext)
      if placed { mutator.acknowledge(id: task.id) }
      return landed
    }
  }

  /// A new task lands on the shared undo stack as a create: undo purges it,
  /// redo re-creates it from the draft as saved.
  private func recordCreateUndo(id: String) {
    let saved = draft
    TaskUndo.recordCreate(
      name: RegistryActions.title(.appNewTask),
      ids: [id], mutator: mutator,
      rebuild: { [mutator] in [saved.create(via: mutator).id] })
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
  @discardableResult
  private func persistOnce() -> Bool {
    guard !discarded, !convertedToHeading else { return false }
    guard canSave else { return false }
    guard draft != lastPersistedDraft || !pastedImages.isEmpty else { return true }
    // Mark the draft persisted only AFTER the write reports that it landed.
    // Marking it first meant a rolled-back save was remembered as the last
    // persisted state, so every later call short-circuited on
    // `draft != lastPersistedDraft` and the title was never written again —
    // the row then read as untitled and the inline-create sweep purged it.
    // Leaving the marker unset keeps the next teardown/Save retrying.
    let landed = persist()
    if landed { lastPersistedDraft = draft }
    onDone()
    if convertedToHeading, presentation == .inline { onClose?() }
    return landed
  }

  /// Are there unsaved changes worth guarding? Create: any content entered;
  /// edit: any field differs from the original. Drives the scaffold's Cancel
  /// confirmation and the swipe-to-dismiss block.
  private var isDirty: Bool {
    // One rule for both modes: dirty iff the draft no longer equals the snapshot
    // taken right after seeding (create from the list defaults, edit from the
    // task). A pure whole-struct compare — no field-by-field normalization to get
    // subtly wrong — so an untouched peek is never dirty.
    draft.differs(fromSeed: seededDraft) || !pastedImages.isEmpty
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
    guard canSave else { return }
    Haptics.commit()
    persistOnce()
    // Return saves and closes, for a new task too. A new task used to chain
    // into a second blank draft below it (the Things capture chain); that
    // blank row read as a leftover "New task" ghost, so it is gone.
    close()
  }

  // MARK: - Keyboard focus traversal

  /// Tab order: title → notes → every pill (including Discuss when edit mode offers it).
  private var focusOrder: [TaskEditFocus] {
    var order: [TaskEditFocus] = [.title, .notes]
    // Steps follow notes, as on the Mac. Read on a key press, never in `body`.
    if let task = editingTask {
      order += LocalCache.checklistItems(forTaskID: task.id, in: modelContext).map { .step($0.id) }
    }
    // Rail order from the registry; edit-only pills join once a task exists.
    for attr in TaskAttributeBar.Attribute.rail {
      if attr == .discuss {
        if discussKickoffVisible { order.append(.pill(.discuss)) }
      } else if attr == .history {
        // Page depth only, and only where the backend keeps a log.
        if isEditing, TaskHistory.isAvailable,
           pageBlocks.contains(where: { $0.kind == .history }) {
          order.append(.pill(.history))
        }
      } else if !attr.editOnly || isEditing {
        order.append(.pill(attr))
      }
    }
    return order
  }

  /// Advance / retreat the keyboard cursor, wrapping at the ends.
  private func moveFocus(from origin: TaskEditFocus? = nil, forward: Bool) {
    let order = focusOrder
    guard let current = origin ?? focus, let i = order.firstIndex(of: current) else {
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

#if os(iOS)
// MARK: - Inline iOS title editor

/// Non-scrolling `UITextView` subclass for the inline task title.
///
/// SwiftUI's `TextField(..., axis: .vertical)` backs itself with a scrollable
/// `UITextView` whose internal text-container insets and first-responder
/// scroll-to-caret pass visibly shift the title up then down when editing
/// begins. Pinning `isScrollEnabled = false`, `textContainerInset = .zero`,
/// `lineFragmentPadding = 0`, and locking `contentOffset` to `.zero` keeps the
/// editing glyphs on the exact same line as `CheckableRow`'s static `Text`.
private final class InlineTitleUITextView: UITextView {
  var onTab: ((Bool) -> Void)?
  var onEscape: (() -> Void)?
  /// Set while the composer asks for the keyboard. The request holds until the
  /// view is in a window: before that, `becomeFirstResponder` does nothing.
  var focusPending = false
  var onFocusClaimed: (() -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    claimFocusIfPending()
  }

  /// One runloop turn later, because SwiftUI may be updating views now and the
  /// claim writes composer state.
  func claimFocusIfPending() {
    guard focusPending, window != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.focusPending, self.window != nil else { return }
      if !self.isFirstResponder {
        guard self.becomeFirstResponder() else { return }
        let end = ((self.text ?? "") as NSString).length
        self.selectedRange = NSRange(location: end, length: 0)
      }
      self.focusPending = false
      self.onFocusClaimed?()
    }
  }

  override var contentOffset: CGPoint {
    get { .zero }
    set { super.contentOffset = .zero }
  }

  override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
    super.setContentOffset(.zero, animated: false)
  }

  override var keyCommands: [UIKeyCommand]? {
    var commands = super.keyCommands ?? []
    let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTabForward))
    tab.wantsPriorityOverSystemBehavior = true
    let backTab = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleTabBackward))
    backTab.wantsPriorityOverSystemBehavior = true
    let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape))
    escape.wantsPriorityOverSystemBehavior = true
    commands.append(contentsOf: [tab, backTab, escape])
    return commands
  }

  @objc private func handleTabForward() { onTab?(true) }
  @objc private func handleTabBackward() { onTab?(false) }
  @objc private func handleEscape() { onEscape?() }
}

private struct InlineTitleTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  @Binding var focusPending: Bool
  let onSubmit: () -> Void
  let onDone: () -> Void
  let onTab: (Bool) -> Void
  let onEscape: () -> Void

  private func resolvedFont(for dynamicTypeSize: DynamicTypeSize) -> UIFont {
    let category = UIContentSizeCategory(dynamicTypeSize)
    return UIFont.preferredFont(
      forTextStyle: .body,
      compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
    )
  }

  func makeUIView(context: Context) -> InlineTitleUITextView {
    let view = InlineTitleUITextView()
    view.delegate = context.coordinator
    view.backgroundColor = .clear
    view.isOpaque = false
    view.isScrollEnabled = false
    view.bounces = false
    view.alwaysBounceVertical = false
    view.showsVerticalScrollIndicator = false
    view.showsHorizontalScrollIndicator = false
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.textContainer.lineBreakMode = .byWordWrapping
    view.textContainer.maximumNumberOfLines = 0
    view.adjustsFontForContentSizeCategory = false
    view.font = resolvedFont(for: context.environment.dynamicTypeSize)
    view.textColor = .label
    view.returnKeyType = .done
    view.textDragInteraction?.isEnabled = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.required, for: .vertical)
    view.setContentCompressionResistancePriority(.required, for: .vertical)
    view.text = text

    let coordinator = context.coordinator
    view.onTab = { forward in coordinator.parent.onTab(forward) }
    view.onEscape = { coordinator.parent.onEscape() }
    view.onFocusClaimed = { coordinator.parent.focusPending = false }

    // SwiftUI's `.keyboard` toolbar does not attach to a UIKit text view, so
    // carry the same Done accessory bar as `TaskMarkdownNotesEditor`.
    let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
    bar.items = [
      UIBarButtonItem(systemItem: .flexibleSpace),
      UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in
        coordinator.parent.onDone()
      })
    ]
    bar.sizeToFit()
    view.inputAccessoryView = bar
    return view
  }

  func updateUIView(_ view: InlineTitleUITextView, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self

    let font = resolvedFont(for: context.environment.dynamicTypeSize)
    if view.font != font {
      view.font = font
      view.invalidateIntrinsicContentSize()
    }

    if view.text != text {
      coordinator.replaceText(in: view, with: text)
    }

    // Mirror `PlatformMarkdownNotesTextView`'s focus gate: act only on a change
    // in the requested focus so SwiftUI's `@FocusState` echo (no native
    // `.focused` modifier on this representable) never dismisses a live tap.
    if isFocused != coordinator.lastRequestedFocus {
      if isFocused, !view.isFirstResponder {
        view.becomeFirstResponder()
        let end = ((view.text ?? "") as NSString).length
        view.selectedRange = NSRange(location: end, length: 0)
      } else if !isFocused, view.isFirstResponder, !coordinator.isEditing {
        view.resignFirstResponder()
      }
      coordinator.lastRequestedFocus = isFocused
    }

    view.focusPending = focusPending
    view.claimFocusIfPending()
  }

  func sizeThatFits(_ proposal: ProposedViewSize,
                    uiView: InlineTitleUITextView,
                    context: Context) -> CGSize? {
    let width = proposal.width ?? uiView.bounds.width
    guard width > 0 else { return nil }
    let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    let oneLine = uiView.font?.lineHeight ?? 0
    return CGSize(width: width, height: max(oneLine, fitted.height))
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: InlineTitleTextView
    var lastRequestedFocus = false
    var isEditing = false
    private var applying = false

    init(parent: InlineTitleTextView) {
      self.parent = parent
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
      isEditing = true
      lastRequestedFocus = true
      parent.isFocused = true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      isEditing = false
      lastRequestedFocus = false
      parent.isFocused = false
    }

    func textView(_ textView: UITextView,
                  shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
      // Intercept Return before UIKit inserts a newline so the field never
      // grows by an extra line for one frame before committing.
      if text == "\n" {
        parent.onSubmit()
        return false
      }
      // Flatten multi-line pastes in place before insertion.
      if text.contains(where: \.isNewline) {
        let flat = TaskTitleText.singleLine(text)
        let current = (textView.text ?? "") as NSString
        let updated = current.replacingCharacters(in: range, with: flat)
        applying = true
        textView.text = updated
        let caret = range.location + (flat as NSString).length
        textView.selectedRange = NSRange(location: caret, length: 0)
        applying = false
        parent.text = updated
        textView.invalidateIntrinsicContentSize()
        return false
      }
      return true
    }

    func textViewDidChange(_ textView: UITextView) {
      guard !applying else { return }
      let raw = textView.text ?? ""
      if raw.contains(where: \.isNewline) {
        let flat = TaskTitleText.singleLine(raw)
        replaceText(in: textView, with: flat)
        parent.text = flat
      } else {
        parent.text = raw
      }
      textView.invalidateIntrinsicContentSize()
    }

    func replaceText(in textView: UITextView, with text: String) {
      applying = true
      let selected = textView.selectedRange
      textView.text = text
      let length = (text as NSString).length
      let loc = min(selected.location, length)
      let len = min(selected.length, max(0, length - loc))
      textView.selectedRange = NSRange(location: loc, length: len)
      applying = false
      textView.invalidateIntrinsicContentSize()
    }
  }
}
#endif
