#if os(macOS)
import AppKit
import Quartz
import SwiftData
import UniformTypeIdentifiers

// The inline composer: a task row that expands in place into an editor —
// title, then notes (when the task has any, or the Notes pill reveals them),
// then a rail of elective pills (Today / When / Deadline / List / Repeat /
// Notes). The AppKit counterpart of `TaskComposerCard` in `.inline` mode +
// `TaskAttributeBar`, in the SAME top-to-bottom order — title, notes, rail —
// which is also the open-task anatomy Things and Reminders share: prose hangs
// off the title, the controls sit under the prose.
//
// Title and notes are both `NSTextView`s rather than a field-editor-backed
// `NSTextField`. A long title has to WRAP and grow the row as you type — the
// single-line field editor clipped it at the row's width, so the overflow was
// simply invisible while editing — and one layout manager gives both fields
// the same measurement path. The title still behaves as one line
// semantically (Return commits, pasted breaks flatten); it only wraps
// visually. The closed row keeps truncating to one line for list rhythm.
//
// The pills don't own any pickers of their own: each opens the SAME popover or
// panel the row commands use (`SeptaskKitDatePopover`, `KitMoveMenu`, and the
// full Repeat editor), so the composer and the ⌘S / ⌘⇧D / ⌘⇧M / Repeat paths
// can't drift into two different pickers.
//
// Edits autosave on collapse, matching the SwiftUI inline host's contract —
// the list's ONE edit contract: Esc, Return, ⌘↩, click-away, a list change
// and window close all save and close; ⌘Z undoes the save.
// Keyboard, one meaning per key: Return in the title enters and leaves it.
// ⌘↩ (or Esc) commits and folds from ANYWHERE in the open row — title,
// notes, or a pill — which is the platform's "finish this"; the table catches
// it (`SeptaskKitTableView.onCommitEditing`) so one handler covers every
// caret position. Going DEEPER is a separate gesture, never ⌘↩: ↓ on the
// title's last line drops the caret into notes, ↑ on the first notes line
// goes back to the end of the title, Tab walks title → notes → pills
// (Shift-Tab back), and ⌥↩ on a closed row opens straight into notes.
@MainActor
final class KitComposerCell: NSTableCellView, NSTextViewDelegate {

  /// Top-left origin matching `NSTableRowView`. `NSTableCellView` defaults to
  /// non-flipped (bottom-left), which moves `topAnchor` by the entire height
  /// delta while `noteHeightOfRows` animates the row open/closed and causes
  /// the title and checkbox to visibly jump vertically during the transition.
  override var isFlipped: Bool { true }

  /// Which pill was activated — the controller owns every mutation, this view
  /// only says what was asked for.
  enum Action {
    case toggleToday
    case toggleStar
    case when(NSView)
    case deadline(NSView)
    case reminder(NSView)
    case list(NSView)
    case repeatRule(NSView)
    case tags(NSView)
    case toggleComplete
    /// AI kickoff — starts a conversation on this task. Shown only when there
    /// is none yet and on-device AI is available, mirroring SwiftUI's
    /// `TaskAttributeBar.showsDiscuss`.
    case discuss
  }

  var onAction: ((Action) -> Void)?
  /// Title + notes as they stand; the controller writes them through the
  /// mutator. Notes is nil when the field was never shown or is empty.
  var onCommit: ((String, String?) -> Void)?
  /// Fold the row shut (Return, ⌘↩, or Esc).
  var onCollapse: (() -> Void)?
  /// The notes band appeared or disappeared — the controller animates the
  /// row to `expandedHeight`.
  var onNotesVisibilityChanged: (() -> Void)?
  /// Typing (or a resize re-wrap) grew or shrank the title or notes — the
  /// controller should JUMP the row to `expandedHeight`, no easing, so the
  /// caret line is never briefly clipped.
  var onContentHeightChanged: (() -> Void)?

  private let checkbox = KitCheckboxView()
  private let titleView = KitComposerTextView()
  private let titleScroll = KitNestedScrollView()
  private let notesView = KitComposerTextView()
  private let notesScroll = KitNestedScrollView()
  private let checklistView = KitChecklistView()
  private let attachmentsView = KitAttachmentsView()
  private let referencesView = KitReferencesView()
  /// Title, notes, checklist (when shown), attachments (when shown), pills — stacked.
  private let column = NSStackView()
  private let pillRow = NSStackView()
  /// Holds `pillRow` so the rail scrolls sideways (trackpad, shift-wheel)
  /// when the labelled pills are wider than the card, instead of clipping.
  private let pillScroll = KitNestedScrollView()

  private let whenPill = KitPillButton()
  private let deadlinePill = KitPillButton()
  private let reminderPill = KitPillButton()
  private let listPill = KitPillButton()
  private let repeatPill = KitPillButton()
  private let starPill = KitPillButton()
  private let tagPill = KitPillButton()
  private let checklistPill = KitPillButton()
  private let attachPill = KitPillButton()
  private let discussPill = KitPillButton()
  /// "Paste" on a blank new task when the clipboard holds text (#210). A
  /// text stadium at the front of the rail, NOT a rail attribute: it has
  /// registry tier `chip`, so it is outside `taskAttributePills`. Hidden by
  /// a paste or the first keystroke.
  private let pastePill = KitPillButton()
  /// Registry id → pill. The rail's order, labels and icons come from
  /// `RegistrySurfaces.taskAttributePills` (ADR 0020), the same list the
  /// SwiftUI `TaskAttributeBar` renders. Notes is a field, not a pill (#203),
  /// and Today folds into When, as on SwiftUI.
  private lazy var pillsByID: [String: KitPillButton] = [
    "when": whenPill, "deadline": deadlinePill, "reminder": reminderPill,
    "repeat": repeatPill, "star": starPill, "list": listPill, "tags": tagPill,
    "checklist": checklistPill, "attachments": attachPill, "discuss": discussPill,
  ]
  /// The pills in registry rail order.
  private var orderedPills: [KitPillButton] {
    RegistrySurfaces.taskAttributePills(on: RegistryPlatform.current).compactMap { pillsByID[$0.id] }
  }

  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var checkboxCenterYConstraint: NSLayoutConstraint!
  private var columnTopConstraint: NSLayoutConstraint!
  private var titleHeightConstraint: NSLayoutConstraint!
  private var notesHeightConstraint: NSLayoutConstraint!
  private var checklistHeightConstraint: NSLayoutConstraint!
  private var attachmentsHeightConstraint: NSLayoutConstraint!
  private var referencesHeightConstraint: NSLayoutConstraint!
  /// False only before `configure(with:)` has run — an open row always shows
  /// its notes. Kept as a guard so a cell the table measures before it is
  /// configured doesn't reserve notes height it isn't drawing yet.
  private var notesShown = false
  /// Last measured heights. Both drive their scroll view's constraint and
  /// `expandedHeight`; the title is never shorter than one line.
  private var measuredTitleHeight: CGFloat = KitComposerCell.titleLineHeight
  private var measuredNotesHeight: CGFloat = KitComposerCell.notesMinHeight
  /// Text-edit undo stays LOCAL to the open row. Both text views would
  /// otherwise fall through to the window's undo manager — the shared task
  /// stack (`TaskUndo`) — and a ⌘Z after the row folded would "undo" keystrokes
  /// into a field that is no longer on screen. Reset on every `configure`.
  private let textUndo = UndoManager()
  /// What the store held after the last commit from this cell (or at
  /// `configure`). `commit()` reports only a difference from it, so it is
  /// idempotent: a command that saves typed text first, and the collapse that
  /// follows, never write the same edit twice.
  private var committedTitle = ""
  /// The task this composer was opened for (`configure(with:)`).
  private var configuredTaskID: String?
  private var committedNotes: String?
  /// A deferred commit-and-collapse is queued. A second Return / Esc before
  /// it runs must not queue another.
  private var isClosing = false

  // MARK: - Height

  /// The pill rail's height: the 30pt pills plus room for the focus ring.
  fileprivate static let pillRowHeight: CGFloat = 34
  /// Empty / short notes — two lines of room before the field grows. Things'
  /// open task shows about this much under the title.
  private static var notesMinHeight: CGFloat {
    ceil(NSLayoutManager().defaultLineHeight(
      for: .systemFont(ofSize: SeptaskKitTheme.notesFontSize)) * 2 + notesInset.height * 2)
  }
  /// Caps growth so a novel-length note scrolls inside the field instead of
  /// eating the whole list. Matches SwiftUI `TaskMarkdownNotesEditor`.
  private static let notesMaxHeight: CGFloat = 360
  private static let notesInset = NSSize(width: 2, height: 4)
  /// Breathing room under the pill rail. The TOP of the composer is not
  /// padded separately — it reuses the closed row's vertical band so the
  /// title doesn't travel when the row expands.
  private static let bottomPadding: CGFloat = 10
  private static let interRowGap: CGFloat = 8

  /// One line of title. The first line's baseline aligns to `SeptaskKitTaskCell`'s
  /// centered label to 0pt across every `SeptenaTypeScale` step so opening the
  /// row never nudges the glyphs; every further wrapped line adds to the row
  /// below it.
  static var titleLineHeight: CGFloat {
    ceil(NSLayoutManager().defaultLineHeight(for: SeptaskKitTheme.taskTitle))
  }

  private struct TitleTopCacheKey: Equatable {
    let fontSize: CGFloat
    let rowHeight: CGFloat
  }
  private static var cachedTitleTop: (key: TitleTopCacheKey, value: CGFloat)?

  /// Exact vertical offset from the cell's top to `titleScroll`'s top so the
  /// first line's baseline matches `SeptaskKitTaskCell`'s vertically centered
  /// `NSTextField` label at every text-size factor (including non-integer scale
  /// steps where `NSTextFieldCell` and `NSLayoutManager.defaultLineHeight`
  /// otherwise diverge by 0.5pt).
  private static var titleTop: CGFloat {
    let font = SeptaskKitTheme.taskTitle
    let rowHeight = SeptaskKitTheme.rowHeight
    let key = TitleTopCacheKey(fontSize: font.pointSize, rowHeight: rowHeight)
    if let cached = cachedTitleTop, cached.key == key {
      return cached.value
    }
    let probe = NSTextField(labelWithString: "Ag")
    probe.font = font
    probe.isBordered = false
    probe.isBezeled = false
    let labelHeight = probe.intrinsicContentSize.height
    let labelBaselineFromTop = (rowHeight - labelHeight) / 2
      + (labelHeight - probe.baselineOffsetFromBottom)

    let storage = NSTextStorage(string: "Ag", attributes: [.font: font])
    let container = NSTextContainer(size: CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    let manager = NSLayoutManager()
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    let lineRect = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
    let tvBaselineFromBottom = manager.typesetter.baselineOffset(in: manager, glyphIndex: 0)
    let tvBaselineFromLineTop = lineRect.maxY - tvBaselineFromBottom

    let value = labelBaselineFromTop - tvBaselineFromLineTop
    cachedTitleTop = (key, value)
    return value
  }

  /// Row height for a one-line title with no notes — the controller's answer
  /// until the live cell has measured itself (`expandedHeight`).
  static var baseHeight: CGFloat {
    height(titleHeight: titleLineHeight, notesHeight: nil, checklistHeight: 0, attachmentsHeight: 0,
           referencesHeight: 0)
  }

  /// Layout: a closed-row-height band at the top (checkbox + first title line
  /// centered exactly as `SeptaskKitTaskCell`), any extra title lines, then
  /// notes, optional checklist, attachments and references, and pills hanging below.
  private static func height(titleHeight: CGFloat, notesHeight: CGFloat?,
                             checklistHeight: CGFloat, attachmentsHeight: CGFloat,
                             referencesHeight: CGFloat) -> CGFloat {
    var height = SeptaskKitTheme.rowHeight + max(0, titleHeight - titleLineHeight) + interRowGap
    if let notesHeight { height += notesHeight + interRowGap }
    if checklistHeight > 0 { height += checklistHeight + interRowGap }
    if attachmentsHeight > 0 { height += attachmentsHeight + interRowGap }
    if referencesHeight > 0 { height += referencesHeight + interRowGap }
    return height + pillRowHeight + bottomPadding
  }

  var expandedHeight: CGFloat {
    recomputeContentHeights(notify: false)
    let checklistH = checklistView.isHidden ? 0 : checklistView.preferredHeight
    let attachH = attachmentsView.isHidden ? 0 : attachmentsView.preferredHeight
    return Self.height(titleHeight: measuredTitleHeight,
                       notesHeight: notesShown ? measuredNotesHeight : nil,
                       checklistHeight: checklistH,
                       attachmentsHeight: attachH,
                       referencesHeight: referencesView.preferredHeight)
  }

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    checkbox.translatesAutoresizingMaskIntoConstraints = false
    checkbox.onToggle = { [weak self] in self?.onAction?(.toggleComplete) }

    // Chrome-less title — same ink/type as the closed row, no bezel/fill, so
    // it reads as the row's own text with a caret in it (Things), not a boxed
    // input sitting on the card.
    titleView.isRichText = false
    titleView.usesFontPanel = false
    titleView.isAutomaticLinkDetectionEnabled = false
    titleView.isAutomaticDataDetectionEnabled = false
    titleView.font = SeptaskKitTheme.taskTitle
    titleView.textColor = .labelColor
    titleView.typingAttributes = Self.titleAttributes
    titleView.textContainerInset = .zero
    titleView.placeholder = RegistryActions.title("app.newTask")
    Self.styleTextView(titleView, in: titleScroll)
    // A task title is ONE line, enforced in the view itself (see
    // `isSingleLine`) so no delegate wiring — present or absent — can put a
    // break in it.
    titleView.isSingleLine = true
    titleView.onLineBreakAttempt = { [weak self] in self?.deferCommitAndCollapse() }

    notesView.isRichText = true
    notesView.textContainerInset = Self.notesInset
    notesView.typingAttributes = MarkdownNotesStyle.baseAttributes(
      fontSize: SeptaskKitTheme.notesFontSize)
    notesView.font = .systemFont(ofSize: SeptaskKitTheme.notesFontSize)
    notesView.placeholder = RegistrySurfaces.taskAttribute("notes").label
    Self.styleTextView(notesView, in: notesScroll)
    notesScroll.isHidden = true

    // THE delegate assignment. Without it every `NSTextViewDelegate` method
    // below is dead code: Return inserted a line break instead of committing,
    // Tab inserted a tab, Escape and ↓-into-notes never fired, the pasted
    // line-break flattening never ran, and text-edit undo landed on the shared
    // task stack instead of the row-local one. It was missing from the day the
    // composer landed — the cell CONFORMS to the protocol, which reads as
    // wired, and the two behaviors that did work (Esc, ⌘↩) work through the
    // responder chain and the table's `performKeyEquivalent`, so the gap stayed
    // invisible.
    titleView.delegate = self
    notesView.delegate = self

    pillRow.orientation = .horizontal
    pillRow.spacing = 8
    pillRow.alignment = .centerY
    pillRow.translatesAutoresizingMaskIntoConstraints = false

    whenPill.onPress = { [weak self] view in self?.onAction?(.when(view)) }
    deadlinePill.onPress = { [weak self] view in self?.onAction?(.deadline(view)) }
    reminderPill.onPress = { [weak self] view in self?.onAction?(.reminder(view)) }
    listPill.onPress = { [weak self] view in self?.onAction?(.list(view)) }
    repeatPill.onPress = { [weak self] view in self?.onAction?(.repeatRule(view)) }
    starPill.onPress = { [weak self] _ in self?.onAction?(.toggleStar) }
    tagPill.onPress = { [weak self] view in self?.onAction?(.tags(view)) }
    checklistPill.onPress = { [weak self] _ in self?.addChecklistItemAndFocus() }
    attachPill.onPress = { [weak self] _ in self?.attachmentsView.pickFilesToAttach() }
    discussPill.onPress = { [weak self] _ in self?.onAction?(.discuss) }
    let pasteChip = RegistrySurfaces.taskAttribute("paste")
    pastePill.image = NSImage(systemSymbolName: pasteChip.sfSymbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    pastePill.imagePosition = .imageLeading
    pastePill.title = pasteChip.label
    pastePill.toolTip = pasteChip.label
    pastePill.setAccessibilityLabel(pasteChip.label)
    pastePill.isHidden = true
    pastePill.onPress = { [weak self] _ in self?.pasteFromClipboard() }
    pillRow.addArrangedSubview(pastePill)
    for attribute in RegistrySurfaces.taskAttributePills(on: RegistryPlatform.current) {
      guard let pill = pillsByID[attribute.id] else { continue }
      pill.attribute = attribute
      pillRow.addArrangedSubview(pill)
    }

    checklistView.translatesAutoresizingMaskIntoConstraints = false
    checklistView.onChanged = { [weak self] in
      guard let self else { return }
      self.syncChecklistHeight(notify: true)
      self.updateChecklistPill()
    }
    // The steps read as part of the document: ↑ or Shift-Tab off the first
    // step climbs into notes, ↓ or Tab off the last goes on to the rail.
    checklistView.onLeave = { [weak self] delta in
      guard let self else { return }
      if delta < 0 { self.focusNotes() } else { self.window?.makeFirstResponder(self.firstFocusablePill ?? self.titleView) }
    }

    attachmentsView.translatesAutoresizingMaskIntoConstraints = false
    attachmentsView.onChanged = { [weak self] in
      guard let self else { return }
      self.syncAttachmentsHeight(notify: true)
      self.updateAttachPill()
    }

    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = Self.interRowGap
    column.detachesHiddenViews = true
    column.translatesAutoresizingMaskIntoConstraints = false
    column.addArrangedSubview(titleScroll)
    column.addArrangedSubview(notesScroll)
    column.addArrangedSubview(checklistView)
    column.addArrangedSubview(attachmentsView)
    referencesView.translatesAutoresizingMaskIntoConstraints = false
    referencesView.isHidden = true
    column.addArrangedSubview(referencesView)
    pillScroll.drawsBackground = false
    pillScroll.hasHorizontalScroller = false
    pillScroll.hasVerticalScroller = false
    pillScroll.verticalScrollElasticity = .none
    pillScroll.horizontalScrollElasticity = .automatic
    pillScroll.translatesAutoresizingMaskIntoConstraints = false
    pillScroll.documentView = pillRow
    column.addArrangedSubview(pillScroll)
    // The one-line title ends `titleTop` short of the closed-row band's
    // bottom; add that back so the rail hangs `interRowGap` under the BAND
    // (where it always sat), not under the glyphs.
    column.setCustomSpacing(Self.titleTop + Self.interRowGap, after: titleScroll)

    addSubview(checkbox)
    addSubview(column)

    leadingConstraint = checkbox.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + SeptaskKitLayout.rowLeadingPad)
    trailingConstraint = column.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    checkboxCenterYConstraint = checkbox.centerYAnchor.constraint(
      equalTo: topAnchor, constant: SeptaskKitTheme.rowHeight / 2)
    columnTopConstraint = column.topAnchor.constraint(
      equalTo: topAnchor, constant: Self.titleTop)
    titleHeightConstraint = titleScroll.heightAnchor.constraint(
      equalToConstant: Self.titleLineHeight)
    notesHeightConstraint = notesScroll.heightAnchor.constraint(
      equalToConstant: Self.notesMinHeight)
    checklistHeightConstraint = checklistView.heightAnchor.constraint(equalToConstant: 0)
    attachmentsHeightConstraint = attachmentsView.heightAnchor.constraint(equalToConstant: 0)
    referencesHeightConstraint = referencesView.heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      leadingConstraint,
      // Match `SeptaskKitTaskCell`: checkbox on the vertical center of a
      // standard-height row, the title's FIRST line baseline-locked to it.
      // Extra lines and the rest of the column add space BELOW this band.
      checkboxCenterYConstraint,
      checkbox.widthAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      checkbox.heightAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      column.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
      columnTopConstraint,
      trailingConstraint,

      titleScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
      titleHeightConstraint,
      notesScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
      notesHeightConstraint,
      checklistView.widthAnchor.constraint(equalTo: column.widthAnchor),
      checklistHeightConstraint,
      attachmentsView.widthAnchor.constraint(equalTo: column.widthAnchor),
      attachmentsHeightConstraint,
      referencesView.widthAnchor.constraint(equalTo: column.widthAnchor),
      referencesHeightConstraint,
      pillScroll.heightAnchor.constraint(equalToConstant: Self.pillRowHeight),
      pillScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
      pillRow.topAnchor.constraint(equalTo: pillScroll.contentView.topAnchor),
      pillRow.leadingAnchor.constraint(equalTo: pillScroll.contentView.leadingAnchor),
      pillRow.heightAnchor.constraint(equalTo: pillScroll.contentView.heightAnchor),
    ])

    // Tab walks title → notes (when shown) → pills, which is the composer's
    // keyboard cursor (the SwiftUI form's `focusOrder`). The title's link is
    // re-pointed as notes show/hide (`updateKeyChain`).
    let pills = orderedPills
    notesView.nextKeyView = pills.first ?? titleView
    for (pill, next) in zip(pills, pills.dropFirst()) { pill.nextKeyView = next }
    pills.last?.nextKeyView = titleView
    updateKeyChain()
  }

  required init?(coder: NSCoder) { fatalError("KitComposerCell is code-only") }

  private static var titleAttributes: [NSAttributedString.Key: Any] {
    [.font: SeptaskKitTheme.taskTitle, .foregroundColor: NSColor.labelColor]
  }

  /// The shared text-view setup: borderless, transparent, width-tracking, and
  /// hosted in a scroll view whose height WE set from the measured text (the
  /// documentView arrangement is the one `NSTextView` sizing mode that plays
  /// cleanly with Auto Layout). Scrollers only ever appear on notes at its cap.
  private static func styleTextView(_ view: KitComposerTextView, in scroll: NSScrollView) {
    view.importsGraphics = false
    view.allowsUndo = true
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.drawsBackground = false
    view.focusRingType = .none
    view.insertionPointColor = .labelColor
    view.isHorizontallyResizable = false
    view.isVerticallyResizable = true
    view.minSize = .zero
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                          height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.lineFragmentPadding = 0
    scroll.documentView = view
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
  }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + SeptaskKitLayout.rowLeadingPad
    trailingConstraint.constant = -(inset + 8)
    super.layout()
    // Width can change on window resize — re-wrap and grow/shrink both fields.
    // Defer the table notify so we don't re-enter layout via noteHeightOfRows.
    if recomputeContentHeights(notify: false) {
      DispatchQueue.main.async { [weak self] in
        self?.onContentHeightChanged?()
      }
    }
  }

  /// The text column's width, from the cell's own bounds rather than the
  /// scroll views' — those are still zero before the first layout pass, and
  /// `expandedHeight` is read before it. Nil until the table has sized the
  /// cell at all (a fresh dequeue), when no measurement would be meaningful.
  private var textColumnWidth: CGFloat? {
    guard bounds.width > 60 else { return nil }
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    return bounds.width - (inset + SeptaskKitLayout.rowLeadingPad + KitCheckboxView.tapSize + 7) - (inset + 8)
  }

  // MARK: - Populate

  /// Full load — title AND notes included. Call ONLY when the composer is
  /// first opened for a task; never on a mid-edit refresh (see `refreshPills`).
  func configure(with task: SeptenaTask, listName: String?) {
    textUndo.removeAllActions()
    isClosing = false
    configuredTaskID = task.id
    committedTitle = task.title
    committedNotes = Self.normalizedNotes(task.notes)
    // Refresh text-scale-dependent geometry on every reuse so a pooled cell
    // stays baseline-locked to `SeptaskKitTaskCell` after Text Size changes.
    checkboxCenterYConstraint.constant = SeptaskKitTheme.rowHeight / 2
    columnTopConstraint.constant = Self.titleTop
    column.setCustomSpacing(Self.titleTop + Self.interRowGap, after: titleScroll)
    measuredTitleHeight = Self.titleLineHeight
    titleHeightConstraint.constant = Self.titleLineHeight
    titleView.font = SeptaskKitTheme.taskTitle
    titleView.textContainerInset = .zero
    titleView.textContainer?.lineFragmentPadding = 0
    titleView.textStorage?.setAttributedString(
      NSAttributedString(string: task.title, attributes: Self.titleAttributes))
    titleView.typingAttributes = Self.titleAttributes
    titleScroll.contentView.scroll(to: .zero)
    let notes = task.notes ?? ""
    let fontSize = SeptaskKitTheme.notesFontSize
    notesView.textStorage?.setAttributedString(
      MarkdownNotesStyle.attributed(notes, fontSize: fontSize))
    notesView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    notesScroll.contentView.scroll(to: .zero)
    // An open row ALWAYS shows its notes field, empty or not: the open row is
    // the task's whole document, and a field that appears only once it has
    // content hides the fact that notes exist at all. The empty field's
    // "Notes" placeholder is the affordance.
    notesShown = true
    notesScroll.isHidden = false
    titleView.needsDisplay = true
    notesView.needsDisplay = true
    checklistView.configure(taskID: task.id)
    syncChecklistHeight(notify: false)
    attachmentsView.configure(taskID: task.id)
    syncAttachmentsHeight(notify: false)
    refreshReferences(notify: false)
    updateKeyChain()
    recomputeContentHeights(notify: false)
    refreshPills(with: task, listName: listName)
    // A blank new task offers Paste when the clipboard holds text (#210).
    // Read once here, at open; never per keystroke.
    pastePill.isHidden = !(task.title.isEmpty && committedNotes == nil && SeptenaPasteboard.hasPasteable)
  }

  /// Fill the blank title and notes from the clipboard
  /// (`TaskTitleText.pasteSplit`), hide the Paste pill, and put the caret at
  /// the end of the title. Does not commit: the row autosaves on collapse.
  private func pasteFromClipboard() {
    pastePill.isHidden = true
    // An image becomes an attachment, same as the iOS composer. The row
    // already exists here, so it attaches at once.
    if SeptenaPasteboard.hasImage, let taskID = configuredTaskID {
      KitAttachmentPasteHelper.attachFromPasteboard(to: taskID, presentErrorIn: window)
      attachmentsView.reload()
      syncAttachmentsHeight(notify: false)
      updateAttachPill()
      // An untitled row is purged when it folds. A pasted image alone titles
      // it "Image", selected, so typing replaces it.
      if titleView.string.isEmpty {
        titleView.textStorage?.setAttributedString(NSAttributedString(
          string: String(localized: "Image", comment: "Title of a new task made from a pasted image"),
          attributes: Self.titleAttributes))
        titleView.needsDisplay = true
        window?.makeFirstResponder(titleView)
        titleView.selectAll(nil)
      }
      recomputeContentHeights(notify: true)
      return
    }
    guard let text = NSPasteboard.general.string(forType: .string),
          let split = TaskTitleText.pasteSplit(text) else { return }
    titleView.textStorage?.setAttributedString(
      NSAttributedString(string: split.title, attributes: Self.titleAttributes))
    titleView.typingAttributes = Self.titleAttributes
    if let notes = split.notes {
      let fontSize = SeptaskKitTheme.notesFontSize
      notesView.textStorage?.setAttributedString(
        MarkdownNotesStyle.attributed(notes, fontSize: fontSize))
      notesView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    }
    titleView.needsDisplay = true
    notesView.needsDisplay = true
    recomputeContentHeights(notify: true)
    focusTitle()
  }

  /// Reveal the checklist (if hidden), append a step, and move focus into it.
  /// Driven by the Checklist pill and `⇧⌘C`.
  func addChecklistItemAndFocus() {
    checklistView.appendItemAndFocus()
    syncChecklistHeight(notify: true)
    updateChecklistPill()
    attachmentsView.reload()
    syncAttachmentsHeight(notify: true)
    updateAttachPill()
  }

  private func syncChecklistHeight(notify: Bool) {
    let h = checklistView.isHidden ? 0 : checklistView.preferredHeight
    if abs(checklistHeightConstraint.constant - h) > 0.5 {
      checklistHeightConstraint.constant = h
      if notify { onContentHeightChanged?() }
    }
  }

  private func syncAttachmentsHeight(notify: Bool) {
    let h = attachmentsView.isHidden ? 0 : attachmentsView.preferredHeight
    if abs(attachmentsHeightConstraint.constant - h) > 0.5 {
      attachmentsHeightConstraint.constant = h
      if notify { onContentHeightChanged?() }
    }
  }

  /// Also the list's answer to a task change, so a reference added, removed or
  /// undone while the row is open shows at once.
  func refreshReferences(notify: Bool = true) {
    guard let taskID = configuredTaskID else { return }
    referencesView.configure(rows: LocalCache.taskRefRows(
      forTaskID: taskID, in: LocalStore.shared.container.mainContext))
    referencesView.isHidden = referencesView.isEmpty
    let h = referencesView.preferredHeight
    if abs(referencesHeightConstraint.constant - h) > 0.5 {
      referencesHeightConstraint.constant = h
      if notify { onContentHeightChanged?() }
    }
  }

  private func updateAttachPill() {
    let count = attachmentsView.attachmentCount
    attachPill.show(value: count > 0 ? RegistrySurfaces.taskAttributeCount("attachments", count: count) : nil)
    attachPill.isOn = count > 0
  }

  private func updateChecklistPill() {
    let summary = checklistView.summary
    checklistPill.show(value: summary.total > 0 ? "\(summary.done)/\(summary.total)" : nil)
    checklistPill.isOn = summary.total > 0
  }

  /// Pills + checkbox cues only — deliberately does NOT touch `titleView` or
  /// `notesView`. Called after a pill writes through the mutator (When,
  /// Deadline, List, Repeat, Today all re-read the task afterward to update
  /// their own labels), where the title/notes fields may hold an edit the
  /// user hasn't committed yet — overwriting them here is exactly what used
  /// to silently revert an in-progress title edit the moment any OTHER pill
  /// was touched.
  func refreshPills(with task: SeptenaTask, listName: String?) {
    checkbox.isDone = task.status != .open
    checkbox.isDashed = task.status == .open && task.isInTriageBand
    checkbox.isToday = task.isOnToday
    checkbox.tenureFill = TaskRowFlags.agingEnabled ? task.fadeFill() : nil
    checkbox.cornerDot = task.conversation.hasStarted && !task.isInTriageBand
    checkbox.agentCue = task.showsAgentCue()

    // A pill shows its registry label when empty and its value when set; the
    // icon carries the attribute, as on the SwiftUI rail. "When" folds in
    // Today: a task pinned to today with no date reads "Today", and a time
    // slot rides after the day.
    let slot = task.timeSlotLabel
    let whenDay = task.scheduled.map(KitDayFormat.display)
      ?? (task.today ? String(localized: "Today", comment: "Relative date") : nil)
    whenPill.show(value: whenDay.map { day in slot.map { "\(day) · \($0)" } ?? day } ?? slot)
    whenPill.isOn = task.scheduled != nil || task.today || task.startTime != nil
    deadlinePill.show(value: task.deadline.map(KitDayFormat.display))
    deadlinePill.isOn = task.deadline != nil
    let ctx = LocalStore.shared.container.mainContext
    let snapshot = StructureCache.snapshot(in: ctx)
    if let projectID = task.project,
       snapshot.projects.contains(where: { $0.id == projectID }) {
      let progress = LocalCache.projectCompletionRatios(in: ctx)[projectID] ?? 0
      listPill.iconProvider = { ink in
        KitGlyph.progress(progress, tint: ink, diameter: 12)
      }
    } else if let areaID = task.area,
              let area = snapshot.areas.first(where: { $0.id == areaID }) {
      let emoji = area.emoji
      listPill.iconProvider = { _ in
        KitGlyph.area(emoji: emoji, diameter: 14)
      }
    } else {
      listPill.iconProvider = nil
    }
    listPill.show(value: listName)
    listPill.isOn = listName != nil
    repeatPill.show(value: task.recurrence?.shortLabel)
    repeatPill.isOn = task.recurrence != nil
    let reminderBadge = task.reminder?.badgeText()?.text
    reminderPill.show(value: reminderBadge)
    reminderPill.isOn = reminderBadge != nil
    starPill.show(value: nil)
    starPill.isOn = task.starred
    let resolvedTags = LocalCache.resolvedTags(
      for: task,
      tagsByID: LocalCache.tagsByID(in: ctx)
    )
    tagPill.show(value: resolvedTags.isEmpty ? nil
      : resolvedTags.count == 1 ? resolvedTags[0].name
      : RegistrySurfaces.taskAttributeCount("tags", count: resolvedTags.count))
    tagPill.isOn = !resolvedTags.isEmpty
    updateChecklistPill()
    attachmentsView.reload()
    syncAttachmentsHeight(notify: true)
    updateAttachPill()

    // Same gate as SwiftUI's `showsDiscuss`: only before a conversation
    // exists, and only when a local model can actually answer. A pill that
    // starts nothing would be worse than no pill.
    discussPill.isHidden = task.conversation.hasStarted || !OnDeviceAI.isAvailable
    discussPill.isEnabled = !discussWorking
    discussPill.show(value: discussWorking ? discussPill.attribute?.workingLabel : nil)
  }

  /// True while `ConversationEngine.advance` is in flight — the pill says so
  /// rather than looking inert, since the first turn can take a moment.
  private var discussWorking = false

  func setDiscussWorking(_ working: Bool) {
    discussWorking = working
    discussPill.isEnabled = !working
    discussPill.show(value: working ? discussPill.attribute?.workingLabel : nil)
  }

  // MARK: - Focus

  func focusTitle() {
    // A freshly-opened composer reaches here before its first layout pass —
    // `beginComposing` swaps the cell in and focuses one runloop turn later,
    // while the row is still animating open, so the column's trailing pin
    // (set in `layout()`) has not resolved. Without this flush the text view
    // inherits a near-zero frame and you can only see the glyph you just
    // typed. Same guard, same reason as `SeptaskKitTaskCell.beginEditing`.
    layoutSubtreeIfNeeded()
    titleScroll.contentView.scroll(to: .zero)
    window?.makeFirstResponder(titleView)
    // Caret at the end (Things), not AppKit's select-all block — a selected
    // title reads as a second surface, and one stray keystroke replaces it.
    let end = (titleView.string as NSString).length
    titleView.setSelectedRange(NSRange(location: end, length: 0))
    titleScroll.contentView.scroll(to: .zero)
  }

  /// Title → notes while notes are on screen, straight to the rail otherwise;
  /// notes → rail is fixed.
  private func updateKeyChain() {
    titleView.nextKeyView = notesView
  }

  /// Tab order inside the open row: title ⇄ notes ⇄ steps (when the task has
  /// any), then out to the rail when
  /// the rail can actually take focus. With Full Keyboard Access off — the
  /// default — the pills can't become first responder at all, so Tab cycles
  /// between the two text fields rather than dead-ending on a button that
  /// silently refuses the focus.
  private func moveComposerFocus(forward: Bool) {
    let current = window?.firstResponder
    let target: NSView
    if forward {
      if current === notesView, checklistView.hasItems {
        checklistView.focusFirstItem()
        return
      }
      target = current === titleView ? notesView : (firstFocusablePill ?? titleView)
    } else {
      if current !== notesView, current !== titleView, checklistView.hasItems {
        checklistView.focusLastItem()
        return
      }
      target = current === notesView ? titleView : notesView
    }
    window?.makeFirstResponder(target)
    if let text = target as? NSTextView {
      let end = (text.string as NSString).length
      text.setSelectedRange(NSRange(location: end, length: 0))
    }
  }

  /// The first rail pill that will actually accept the keyboard, or nil when
  /// none will (Full Keyboard Access off).
  private var firstFocusablePill: NSView? {
    pillRow.arrangedSubviews.first { $0.acceptsFirstResponder && !$0.isHidden }
  }

  /// Put the caret at the end of the notes field. It is always on screen for
  /// an open row, so there is nothing to reveal first.
  func focusNotes() {
    window?.makeFirstResponder(notesView)
    let end = (notesView.string as NSString).length
    notesView.setSelectedRange(NSRange(location: end, length: 0))
  }

  /// Whether the caret sits on the first visual line of a wrapped text view —
  /// ↑ there leaves notes for the title; ↑ on a later line is a line move.
  private func caretOnFirstLine(of view: NSTextView) -> Bool {
    guard let manager = view.layoutManager, let container = view.textContainer else { return true }
    manager.ensureLayout(for: container)
    let glyphCount = manager.numberOfGlyphs
    let length = (view.string as NSString).length
    guard glyphCount > 0, length > 0 else { return true }
    let caret = min(view.selectedRange().location, length - 1)
    let glyph = min(manager.glyphIndexForCharacter(at: caret), glyphCount - 1)
    let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    return line.minY <= manager.usedRect(for: container).minY + 1
  }

  /// Whether the caret sits on the last visual line of a wrapped text view —
  /// ↓ there leaves the field; ↓ on an earlier line is a normal line move.
  private func caretOnLastLine(of view: NSTextView) -> Bool { view.caretOnLastLine }

  // MARK: - Measurement

  /// Fit both scroll views to their text — the title unclamped above one
  /// line, notes clamped to min/max. Returns whether either measurement
  /// changed enough to matter for row sizing. A no-op (false) before the
  /// table has given the cell a width.
  @discardableResult
  private func recomputeContentHeights(notify: Bool) -> Bool {
    guard let width = textColumnWidth else { return false }
    var changed = false

    let titleHeight = max(Self.titleLineHeight, measured(titleView, width: width))
    if abs(titleHeight - measuredTitleHeight) > 0.5 {
      measuredTitleHeight = titleHeight
      titleHeightConstraint.constant = titleHeight
      changed = true
    }

    if notesShown {
      let next = min(Self.notesMaxHeight,
                     max(Self.notesMinHeight, measured(notesView, width: width)))
      if abs(next - measuredNotesHeight) > 0.5 {
        measuredNotesHeight = next
        notesHeightConstraint.constant = next
        changed = true
      }
      notesScroll.hasVerticalScroller = next >= Self.notesMaxHeight - 1
    } else if abs(measuredNotesHeight - Self.notesMinHeight) > 0.5 {
      measuredNotesHeight = Self.notesMinHeight
      notesHeightConstraint.constant = Self.notesMinHeight
      notesScroll.hasVerticalScroller = false
      changed = true
    }

    if changed, notify { onContentHeightChanged?() }
    return changed
  }

  /// Wrapped text height at `width`, insets included.
  private func measured(_ view: NSTextView, width: CGFloat) -> CGFloat {
    view.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
    view.frame.size.width = width
    guard let manager = view.layoutManager, let container = view.textContainer else { return 0 }
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    let height = ceil(used.height + view.textContainerInset.height * 2)
    let minHeight = view === titleView ? Self.titleLineHeight : Self.notesMinHeight
    let clamped = max(minHeight, height)
    if abs(view.frame.size.height - clamped) > 0.5 || view.frame.origin != .zero {
      view.frame = NSRect(x: 0, y: 0, width: width, height: clamped)
    }
    return height
  }

  // MARK: - Commit

  /// Current field contents, for the controller's autosave.
  var pendingTitle: String { titleView.string }
  var pendingNotes: String? { Self.normalizedNotes(notesView.string) }

  /// Notes as they are SAVED and COMPARED — both sides go through this, so an
  /// untouched row never looks edited. Only TRAILING whitespace goes: leading
  /// indentation and interior blank lines are markdown structure (a nested
  /// list, a code block) and stay. Empty is nil.
  static func normalizedNotes(_ notes: String?) -> String? {
    guard let notes else { return nil }
    var end = notes.endIndex
    while end > notes.startIndex {
      let previous = notes.index(before: end)
      guard notes[previous].isWhitespace else { break }
      end = previous
    }
    let trimmed = String(notes[..<end])
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Report the typed title / notes when they differ from the last commit.
  /// Safe to call any number of times.
  func commit() {
    checklistView.flushPendingEdits()
    let title = pendingTitle
    let notes = pendingNotes
    guard title != committedTitle || notes != committedNotes else { return }
    committedTitle = title
    committedNotes = notes
    onCommit?(title, notes)
  }

  // MARK: - Keyboard

  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    switch commandSelector {
    // Return opened the row, so Return in the title closes it. Notes is prose
    // — Return inserts a line there; ⌘↩ (caught by the table, see
    // `SeptaskKitTaskListController.commitComposerEditing`) or Esc is its exit.
    case #selector(NSResponder.insertNewline(_:)) where textView === titleView:
      deferCommitAndCollapse()
      return true
    // ↓ on the title's LAST line moves the caret into notes, revealing them
    // the open row reads top-to-bottom like a document. Notes
    // never hands focus back up on ↑: it's prose, the caret stays inside.
    case #selector(NSResponder.moveDown(_:))
      where textView === titleView && caretOnLastLine(of: titleView):
      focusNotes()
      return true
    // …and ↑ on the FIRST line of notes climbs back to the end of the title,
    // so the two fields read as one document in both directions.
    case #selector(NSResponder.moveUp(_:))
      where textView === notesView && caretOnFirstLine(of: notesView):
      focusTitle()
      return true
    // ↓ on the last line of notes walks on into the checklist steps.
    case #selector(NSResponder.moveDown(_:))
      where textView === notesView && checklistView.hasItems && caretOnLastLine(of: notesView):
      checklistView.focusFirstItem()
      return true
    // Autosaves like the SwiftUI inline host — Esc folds the row, it doesn't
    // discard what was typed. One press from either field (notes used to hop
    // to the title first, so closing took two).
    case #selector(NSResponder.cancelOperation(_:)):
      deferCommitAndCollapse()
      return true
    // Tab moves the keyboard cursor along the composer instead of inserting a
    // tab character. Routed EXPLICITLY rather than through
    // `window?.selectNextKeyView` and the `nextKeyView` chain: the pills are
    // `NSButton`s, and an NSControl only joins the key-view loop when the
    // system's Full Keyboard Access is switched on (it's off by default). So
    // the loop skipped the whole rail and walked out of the row entirely —
    // Tab appeared to do nothing.
    case #selector(NSResponder.insertTab(_:)):
      moveComposerFocus(forward: true)
      return true
    case #selector(NSResponder.insertBacktab(_:)):
      moveComposerFocus(forward: false)
      return true
    default:
      return false
    }
  }

  /// `commit()` calls through to `TaskMutator`, which posts its change
  /// notification SYNCHRONOUSLY — and that notification's OWN observers (the
  /// sidebar rebuild in particular) can reselect and call back down into
  /// `focusList()`, i.e. `makeFirstResponder`, on the very row/text view
  /// whose `doCommandBy:` is still on the call stack asking it to resign.
  /// AppKit's first-responder machinery isn't safely reentrant like that —
  /// this is what "Esc doesn't close the row, and clicking away doesn't
  /// either" traced back to: a first-responder fight left mid-transition with
  /// a defunct field editor still visually attached, no longer wired to
  /// anything real. Deferring one runloop tick — the same trick used
  /// elsewhere in this file for "let the current event finish first" AppKit
  /// hazards — runs the commit AFTER this `doCommandBy:` call has already
  /// returned and the text system has finished its own resign-first-responder
  /// sequence, so the reentrant `makeFirstResponder` lands on a clean stack.
  private func deferCommitAndCollapse() {
    // One close per open: a double Return / Esc used to queue two commits
    // and two collapses, and the second could land on a different row.
    guard !isClosing else { return }
    isClosing = true
    DispatchQueue.main.async { [weak self] in
      self?.commit()
      self?.onCollapse?()
    }
  }

  /// Esc on a focused pill (or anything else in this cell that doesn't eat
  /// the command) also folds — "anywhere in open-task mode".
  override func cancelOperation(_ sender: Any?) {
    deferCommitAndCollapse()
  }

  /// Both text views' edits keep their undo in the row-local manager (see
  /// `textUndo`), never on the shared task stack.
  func undoManager(for view: NSTextView) -> UndoManager? { textUndo }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }
    // The first keystroke in either field retires the Paste pill (#210).
    if !pastePill.isHidden { pastePill.isHidden = true }
    if textView === titleView {
      flattenTitleLineBreaks()
    } else if textView === notesView {
      MarkdownNotesStyle.restyle(notesView, fontSize: SeptaskKitTheme.notesFontSize)
    }
    recomputeContentHeights(notify: true)
  }

  /// A title is one line. A pasted multi-line string would otherwise sit in
  /// the view with its breaks intact and be written to the model that way.
  /// Notes keeps its breaks — that field is prose. Same contract as
  /// `NSTextField.septaskFlattenPastedLineBreaks` on the bare-rename path:
  /// `TaskTitleText.singleLine` joins with one space so words don't fuse, and
  /// the caret lands at the end (a paste puts it there anyway).
  private func flattenTitleLineBreaks() {
    let raw = titleView.string
    guard raw.contains(where: \.isNewline) else { return }
    let flat = TaskTitleText.singleLine(raw)
    titleView.textStorage?.setAttributedString(
      NSAttributedString(string: flat, attributes: Self.titleAttributes))
    titleView.setSelectedRange(NSRange(location: (flat as NSString).length, length: 0))
  }
}

// MARK: - Nested scroll view

/// A scroll view inside a list row (the composer's title, notes and pill
/// rail). AppKit sends a wheel or trackpad scroll to the innermost scroll view
/// under the pointer, and a plain `NSScrollView` keeps it even when it has
/// nothing to scroll — so over an open editor the list stopped moving and the
/// field rubber-banded instead. This one keeps a scroll gesture only when its
/// content overflows on that gesture's axis; every other gesture goes up the
/// responder chain to the list. The choice is made once per gesture (at its
/// first event that moves) so a trackpad swipe and its momentum never split
/// between the two scroll views.
final class KitNestedScrollView: NSScrollView {
  /// This gesture's owner: nil until an event shows its axis, then true when
  /// the list takes it.
  private var forwardsGesture: Bool?

  override func scrollWheel(with event: NSEvent) {
    // A mouse wheel has no phases: every click is its own gesture.
    if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
      forwardsGesture = nil
    }
    if forwardsGesture == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
      forwardsGesture = !canScroll(along: event)
    }
    // Undecided (a began event with no movement yet) goes to the list too.
    if forwardsGesture ?? true {
      nextResponder?.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }

  private func canScroll(along event: NSEvent) -> Bool {
    guard let document = documentView else { return false }
    let visible = contentView.bounds.size
    if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
      return document.frame.width > visible.width + 0.5
    }
    return document.frame.height > visible.height + 0.5
  }
}

// MARK: - Text view with placeholder

/// `NSTextView` has no placeholder of its own. Drawing it inside the view (at
/// the text origin, in the view's own font) keeps it exactly where the first
/// glyph will land — an overlaid label never quite lines up with a text
/// container's origin. Reminders' "Add Note" / Things' "Notes" do the same.
@MainActor
extension NSTextView {
  /// Whether the caret sits on the last visual line — ↓ there leaves the
  /// field for whatever sits below it. The caret at the very end counts too:
  /// after a trailing line break it sits on AppKit's extra empty line, which
  /// has no glyph of its own, so the glyph test alone missed it.
  var caretOnLastLine: Bool {
    guard let manager = layoutManager, let container = textContainer else { return true }
    let length = (string as NSString).length
    if selectedRange().location >= length { return true }
    manager.ensureLayout(for: container)
    let glyphCount = manager.numberOfGlyphs
    guard glyphCount > 0, length > 0 else { return true }
    let caret = min(selectedRange().location, length - 1)
    let glyph = min(manager.glyphIndexForCharacter(at: caret), glyphCount - 1)
    let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    let bottom = manager.extraLineFragmentRect.isEmpty
      ? manager.usedRect(for: container).maxY
      : manager.extraLineFragmentRect.minY
    return line.maxY >= bottom - 1
  }
}

final class KitComposerTextView: NSTextView {
  var placeholder = "" {
    didSet { needsDisplay = true }
  }

  /// A task title is one line. A break in it isn't a formatting choice, it's
  /// corrupt data — it can't render in a closed row, in the sidebar, on the
  /// watch, or in any of the other surfaces that draw a title as one line — so
  /// it is refused HERE, in the view, where nothing can route around it.
  ///
  /// The delegate normally turns Return into commit-and-close before these
  /// overrides ever run. That is exactly why this backstop exists: the
  /// delegate was never assigned, so the `doCommandBy` handler was dead and
  /// Return put a newline straight into the title. Belt and braces — the
  /// delegate is wired now, and a title still cannot hold a break if it ever
  /// comes loose again.
  var isSingleLine = false

  /// What to do instead of breaking the line — Return still means "finish".
  var onLineBreakAttempt: (() -> Void)?

  override func insertNewline(_ sender: Any?) {
    guard !isSingleLine else { onLineBreakAttempt?(); return }
    super.insertNewline(sender)
  }

  override func insertLineBreak(_ sender: Any?) {
    guard !isSingleLine else { onLineBreakAttempt?(); return }
    super.insertLineBreak(sender)
  }

  /// ⌥↩ / ⌃↩ inside a text view. Silently refused rather than treated as a
  /// commit: it's the "I meant a soft break" key, and answering it by closing
  /// the row would be a surprise.
  override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
    guard !isSingleLine else { return }
    super.insertNewlineIgnoringFieldEditor(sender)
  }

  /// Typed, dictated, autocompleted, or pasted text all land here. Joining on
  /// a space matches `TaskTitleText.singleLine`, so a multi-line paste reads
  /// the same whichever path flattened it.
  override func insertText(_ string: Any, replacementRange: NSRange) {
    guard isSingleLine else {
      super.insertText(string, replacementRange: replacementRange)
      return
    }
    switch string {
    case let text as String where text.contains(where: \.isNewline):
      super.insertText(TaskTitleText.singleLine(text), replacementRange: replacementRange)
    case let text as NSAttributedString where text.string.contains(where: \.isNewline):
      super.insertText(TaskTitleText.singleLine(text.string), replacementRange: replacementRange)
    default:
      super.insertText(string, replacementRange: replacementRange)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty else { return }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
      .foregroundColor: NSColor.placeholderTextColor,
    ]
    let origin = NSPoint(
      x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
      y: textContainerOrigin.y)
    (placeholder as NSString).draw(at: origin, withAttributes: attributes)
  }

  /// Empty ↔ non-empty flips the placeholder; the text system only redraws
  /// the glyph rects, which are empty when the string is.
  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
  }
}

// MARK: - Pill

/// One elective pill, drawn as a true stadium (corner radius = half height)
/// matching SwiftUI's `AttributePill`. `NSButton.BezelStyle.recessed` is a
/// rounded rect, not a capsule — that's why the rail read as chips. Filled
/// pills wear a gray wash plus matching ink (never a black slab with white
/// text), same as the SwiftUI inline rail's `neutral` treatment.
@MainActor
final class KitPillButton: NSButton {
  var onPress: ((NSView) -> Void)?

  /// The registry attribute this pill stands for (`taskAttributes`). An
  /// attribute pill is a stadium with the symbol and a short label (the set
  /// value when there is one, else the registry label), the iOS
  /// `AttributePill` design. An icon alone was too obscure. The rail scrolls
  /// sideways, so pills keep their natural width and never squeeze to "…".
  /// Nil for free-text pills (conversation), which keep a plain text stadium.
  var attribute: RegistryTaskAttribute? {
    didSet {
      guard attribute != nil else { return }
      imagePosition = .imageLeading
      heightConstraint.constant = Self.attributeHeight
      show(value: nil)
      invalidateIntrinsicContentSize()
    }
  }

  /// Optional dynamic icon override (e.g. area emoji/dot or project progress
  /// ring on the List pill). Called on every `restyle()` so appearance switches
  /// pick up the right ink color.
  var iconProvider: (@MainActor (NSColor) -> NSImage?)? {
    didSet {
      restyle()
      invalidateIntrinsicContentSize()
    }
  }

  /// The attribute's value (`nil` falls back to the registry label). The full
  /// "label: value" goes to the tooltip and VoiceOver.
  func show(value: String?) {
    guard let label = attribute?.label else { return }
    title = value ?? label
    let summary = value.map { "\(label): \($0)" } ?? label
    toolTip = summary
    setAccessibilityLabel(summary)
  }
  private let glass = KitPassthroughGlassView()
  /// Text stadiums stay 24pt (popovers, conversation options); an attribute
  /// pill is taller, inside the rail height (room for the focus ring).
  private static let textHeight: CGFloat = 24
  private static let attributeHeight: CGFloat = 30
  /// A long value ("Fri 28 Nov · Evening", a long list name) truncates here
  /// instead of making one pill eat the rail.
  private static let maxAttributeWidth: CGFloat = 200
  private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: Self.textHeight)

  var isOn: Bool {
    get { state == .on }
    set {
      state = newValue ? .on : .off
      restyle()
    }
  }

  /// `attributedTitle` writes back through `title`; without this the restyle
  /// would recurse. `title` still has to restyle so a label change ("When" →
  /// "When: Friday") keeps the fill/ink pairing.
  private var isRestyling = false

  override var title: String {
    get { super.title }
    set {
      super.title = newValue
      restyle()
      invalidateIntrinsicContentSize()
    }
  }

  init() {
    super.init(frame: .zero)
    isBordered = false
    bezelStyle = .inline
    setButtonType(.momentaryPushIn)
    (cell as? NSButtonCell)?.highlightsBy = []
    (cell as? NSButtonCell)?.showsStateBy = []
    alignment = .center
    lineBreakMode = .byTruncatingTail
    font = SeptaskKitTheme.chip
    focusRingType = .exterior
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.masksToBounds = false
    glass.style = .regular
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass, positioned: .below, relativeTo: nil)
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    target = self
    action = #selector(pressed)
    heightConstraint.isActive = true
    restyle()
  }

  required init?(coder: NSCoder) { fatalError("KitPillButton is code-only") }

  override var intrinsicContentSize: NSSize {
    let text = attributedTitle.size()
    let icon = image.map { $0.size.width + Self.iconGap } ?? 0
    let width = ceil(text.width + icon) + Self.horizontalPadding * 2
    if attribute != nil {
      return NSSize(width: min(width, Self.maxAttributeWidth), height: Self.attributeHeight)
    }
    return NSSize(width: width, height: Self.textHeight)
  }

  override func layout() {
    super.layout()
    keepGlassAtBack()
    applyCapsule()
  }

  /// AppKit makes the button's image view after `init` and puts it at the
  /// back, under the glass, where the icon cannot be seen. `sortSubviews`
  /// moves the glass without dropping its constraints.
  private func keepGlassAtBack() {
    guard subviews.first !== glass else { return }
    sortSubviews({ a, b, glass in
      if Unmanaged.passUnretained(a).toOpaque() == glass { return .orderedAscending }
      if Unmanaged.passUnretained(b).toOpaque() == glass { return .orderedDescending }
      return .orderedSame
    }, context: Unmanaged.passUnretained(glass).toOpaque())
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    restyle()
  }

  /// So the system focus ring follows the stadium, not a rounded-rect bezel.
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds,
                 xRadius: bounds.height / 2,
                 yRadius: bounds.height / 2).fill()
  }

  private func restyle() {
    guard !isRestyling else { return }
    isRestyling = true
    attributedTitle = NSAttributedString(
      string: super.title,
      attributes: [
        .font: SeptaskKitTheme.chip,
        .foregroundColor: isOn ? SeptaskKitTheme.inkPrimary : SeptaskKitTheme.inkSecondary,
      ])
    contentTintColor = isOn ? SeptaskKitTheme.inkPrimary : SeptaskKitTheme.inkSecondary
    // A pill that is on draws its filled symbol (DesignSpec: on = filled),
    // unless a dynamic icon override (such as an area emoji or project ring)
    // supplies the pill's leading glyph.
    if let iconProvider {
      image = iconProvider(contentTintColor ?? .labelColor)
    } else if let attribute {
      image = symbolImage(attribute.sfSymbol(on: isOn), ink: contentTintColor ?? .labelColor)
    }
    isRestyling = false
    applyCapsule()
  }

  /// The symbol drawn in the pill's ink, resolved for this appearance. A
  /// template image tinted by `contentTintColor` rendered near-black under
  /// the glass in dark mode (the icons vanished), so the color is baked into
  /// the symbol's palette instead; `viewDidChangeEffectiveAppearance` redraws.
  private func symbolImage(_ name: String, ink: NSColor) -> NSImage? {
    var resolved = ink
    effectiveAppearance.performAsCurrentDrawingAppearance {
      resolved = ink.usingColorSpace(.sRGB) ?? ink
    }
    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
      .applying(NSImage.SymbolConfiguration(paletteColors: [resolved]))
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    image?.isTemplate = false
    return image
  }

  private func applyCapsule() {
    guard let layer else { return }
    let radius = bounds.height / 2
    layer.cornerRadius = radius
    layer.cornerCurve = .continuous
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    glass.isHidden = reduce
    if reduce {
      layer.backgroundColor = (isOn ? SeptaskKitTheme.pillOnFill : SeptaskKitTheme.chipFill).cgColor
    } else {
      glass.cornerRadius = radius
      glass.tintColor = isOn ? SeptaskKitTheme.pillOnFill : nil
      layer.backgroundColor = NSColor.clear.cgColor
    }
  }

  @objc private func pressed() { onPress?(self) }

  private static let horizontalPadding: CGFloat = 12
  private static let iconGap: CGFloat = 4
}

// MARK: - 1-level Checklist editor (CL1, docs/CHECKLISTS_SPEC.md)

/// Reusable keyboard-fast 1-level checklist editor shared by `KitComposerCell`
/// and `SeptaskKitInspectorController`. Hidden completely until the task has
/// steps or the user clicks Checklist / presses `⇧⌘C` (progressive disclosure).
@MainActor
final class KitChecklistView: NSView {
  var onChanged: (() -> Void)?
  /// ↑ on the first step (-1) or ↓ on the last (+1): the host moves the
  /// keyboard out of the checklist (composer: up to notes, down to the rail).
  var onLeave: ((Int) -> Void)?

  private var taskID: String?
  private var items: [ChecklistItem] = []
  private var rowViews: [KitChecklistItemRow] = []
  private let stack = NSStackView()
  private let addButton = NSButton()
  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }
  private var context: ModelContext { LocalStore.shared.container.mainContext }

  private static let rowHeight: CGFloat = 24
  private static let rowSpacing: CGFloat = 4

  var summary: (done: Int, total: Int) {
    (items.filter(\.checked).count, items.count)
  }

  var preferredHeight: CGFloat {
    guard !isHidden else { return 0 }
    let count = items.count
    let rowsH = CGFloat(count) * Self.rowHeight + CGFloat(count) * Self.rowSpacing
    return rowsH + Self.rowHeight
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Self.rowSpacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    addButton.isBordered = false
    addButton.bezelStyle = .inline
    addButton.imagePosition = .imageLeading
    addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
    addButton.title = String(localized: "Add step", comment: "Checklist add step button")
    addButton.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    addButton.contentTintColor = SeptaskKitTheme.inkSecondary
    addButton.target = self
    addButton.action = #selector(addStepPressed)
    addButton.translatesAutoresizingMaskIntoConstraints = false
    addButton.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("KitChecklistView is code-only") }

  func configure(taskID: String) {
    self.taskID = taskID
    reload(focusItemID: nil)
  }

  func flushPendingEdits() {
    for row in rowViews { row.flushIfDirty() }
  }

  var hasItems: Bool { !items.isEmpty }

  func focusFirstItem() { rowViews.first?.focusTitle() }
  func focusLastItem() { rowViews.last?.focusTitle() }

  /// ⌘K while a step's field holds the keyboard toggles THAT step, not the
  /// task. Returns false when no step is focused, so ⌘K completes the task.
  static func toggleFocusedStep(in window: NSWindow?) -> Bool {
    guard let editor = window?.firstResponder as? NSTextView,
          let field = editor.delegate as? NSTextField else { return false }
    var view: NSView? = field
    while let current = view, !(current is KitChecklistItemRow) { view = current.superview }
    guard let row = view as? KitChecklistItemRow else { return false }
    row.toggleFromKeyboard()
    return true
  }

  func appendItemAndFocus() {
    guard let taskID else { return }
    flushPendingEdits()
    guard let created = mutator.addChecklistItem(taskID: taskID, title: "") else { return }
    TaskUndo.recordChecklistAdd(created, mutator: mutator)
    reload(focusItemID: created.id)
    onChanged?()
  }

  @objc private func addStepPressed() {
    appendItemAndFocus()
  }

  func reload(focusItemID: String?) {
    guard let taskID else {
      items = []
      isHidden = true
      rebuildRows(focusItemID: nil)
      return
    }
    items = LocalCache.checklistItems(forTaskID: taskID, in: context)
    isHidden = items.isEmpty
    rebuildRows(focusItemID: focusItemID)
  }

  private func rebuildRows(focusItemID: String?) {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    rowViews = []

    let total = items.count
    for (idx, item) in items.enumerated() {
      let row = KitChecklistItemRow(item: item, index: idx, total: total)
      row.onToggle = { [weak self] current, keepFocus in self?.toggle(current, keepFocus: keepFocus) }
      row.onCommitTitle = { [weak self] current, nextTitle in self?.commitTitle(current, nextTitle: nextTitle) }
      row.onInsertBelow = { [weak self] current in self?.insertBelow(current) }
      row.onDelete = { [weak self] current, focusPrevious in self?.delete(current, focusPrevious: focusPrevious) }
      row.onMoveFocus = { [weak self] current, delta in self?.moveFocus(from: current.id, delta: delta) }
      row.onMoveOrder = { [weak self] current, delta in self?.moveOrder(itemID: current.id, delta: delta) }
      row.onPasteLines = { [weak self] current, lines in self?.splitPaste(current, lines: lines) }
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
      rowViews.append(row)
    }
    if !items.isEmpty {
      stack.addArrangedSubview(addButton)
    }

    if let focusItemID, let target = rowViews.first(where: { $0.itemID == focusItemID }) {
      DispatchQueue.main.async { [weak target] in target?.focusTitle() }
    }
  }

  private func toggle(_ item: ChecklistItem, keepFocus: Bool) {
    flushPendingEdits()
    var after = item
    after.checked.toggle()
    mutator.updateChecklistItem(id: item.id, checked: after.checked)
    TaskUndo.recordChecklistUpdate(before: item, after: after, mutator: mutator)
    reload(focusItemID: keepFocus ? item.id : nil)
    onChanged?()
  }

  private func commitTitle(_ item: ChecklistItem, nextTitle: String) {
    let trimmed = nextTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != item.title else { return }
    var after = item
    after.title = trimmed
    mutator.updateChecklistItem(id: item.id, title: trimmed)
    TaskUndo.recordChecklistUpdate(before: item, after: after, mutator: mutator)
    if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].title = trimmed }
    onChanged?()
  }

  private func insertBelow(_ item: ChecklistItem) {
    guard let taskID else { return }
    flushPendingEdits()
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
    reload(focusItemID: created.id)
    onChanged?()
  }

  private func delete(_ item: ChecklistItem, focusPrevious: Bool) {
    let idx = items.firstIndex(where: { $0.id == item.id })
    let prevID: String? = focusPrevious ? idx.flatMap { $0 > 0 ? items[$0 - 1].id : nil } : nil
    mutator.deleteChecklistItem(id: item.id)
    TaskUndo.recordChecklistDelete(item, mutator: mutator)
    reload(focusItemID: prevID)
    onChanged?()
  }

  private func moveFocus(from itemID: String, delta: Int) {
    guard let idx = rowViews.firstIndex(where: { $0.itemID == itemID }) else { return }
    let next = idx + delta
    guard rowViews.indices.contains(next) else { onLeave?(delta); return }
    rowViews[next].focusTitle()
  }

  private func moveOrder(itemID: String, delta: Int) {
    guard let taskID,
          let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
    let target = idx + delta
    guard items.indices.contains(target) else { return }
    let beforeIDs = items.map(\.id)
    var afterIDs = beforeIDs
    afterIDs.swapAt(idx, target)
    mutator.reorderChecklistItems(taskID: taskID, orderedIDs: afterIDs)
    TaskUndo.recordChecklistReorder(taskID: taskID, beforeIDs: beforeIDs, afterIDs: afterIDs, mutator: mutator)
    reload(focusItemID: itemID)
    onChanged?()
  }

  private func splitPaste(_ item: ChecklistItem, lines: [String]) {
    guard let taskID, let first = lines.first else { return }
    commitTitle(item, nextTitle: first)
    let rest = Array(lines.dropFirst())
    guard !rest.isEmpty else { return }
    let idx = items.firstIndex(where: { $0.id == item.id }) ?? (items.count - 1)
    let belowPos = idx + 1 < items.count ? items[idx + 1].position : (items[idx].position + TaskOrder.gap * Double(rest.count + 1))
    let span = belowPos - items[idx].position
    var lastID = item.id
    for (offset, text) in rest.enumerated() {
      let pos = items[idx].position + span * Double(offset + 1) / Double(rest.count + 1)
      if let created = mutator.addChecklistItem(taskID: taskID, title: text, position: pos) {
        TaskUndo.recordChecklistAdd(created, mutator: mutator)
        lastID = created.id
      }
    }
    reload(focusItemID: lastID)
    onChanged?()
  }
}

@MainActor
private final class KitChecklistItemRow: NSView, NSTextFieldDelegate {
  private var item: ChecklistItem
  var itemID: String { item.id }

  var onToggle: ((ChecklistItem, Bool) -> Void)?
  var onCommitTitle: ((ChecklistItem, String) -> Void)?
  var onInsertBelow: ((ChecklistItem) -> Void)?
  var onDelete: ((ChecklistItem, Bool) -> Void)?
  var onMoveFocus: ((ChecklistItem, Int) -> Void)?
  var onMoveOrder: ((ChecklistItem, Int) -> Void)?
  var onPasteLines: ((ChecklistItem, [String]) -> Void)?

  private let checkButton = NSButton()
  private let field = NSTextField()
  private let deleteButton = NSButton()

  init(item: ChecklistItem, index: Int, total: Int) {
    self.item = item
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    checkButton.isBordered = false
    checkButton.bezelStyle = .inline
    checkButton.imagePosition = .imageOnly
    checkButton.refusesFirstResponder = true
    checkButton.image = NSImage(
      systemSymbolName: item.checked ? "checkmark.circle.fill" : "circle",
      accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    checkButton.contentTintColor = item.checked ? SeptaskKitTheme.inkSecondary : SeptaskKitTheme.iconMuted
    checkButton.target = self
    checkButton.action = #selector(togglePressed)
    checkButton.setAccessibilityLabel(
      String(localized: "\(item.title.isEmpty ? "Step" : item.title), checklist item \(index + 1) of \(total), \(item.checked ? "checked" : "unchecked")",
             comment: "Checklist item VoiceOver label")
    )

    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: SeptaskKitTheme.notesFontSize)
    field.placeholderString = String(localized: "Checklist item", comment: "Checklist item placeholder")
    field.lineBreakMode = .byTruncatingTail
    field.delegate = self
    applyFieldStyle()

    deleteButton.isBordered = false
    deleteButton.bezelStyle = .inline
    deleteButton.imagePosition = .imageOnly
    deleteButton.refusesFirstResponder = true
    deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    deleteButton.contentTintColor = SeptaskKitTheme.iconMuted
    deleteButton.target = self
    deleteButton.action = #selector(deletePressed)
    deleteButton.setAccessibilityLabel(String(localized: "Delete step", comment: "Checklist delete button a11y"))

    let rowMenu = NSMenu()
    if index > 0 {
      let up = NSMenuItem(title: String(localized: "Move Up", comment: "Checklist context menu"),
                          action: #selector(moveUpPressed), keyEquivalent: "")
      up.target = self
      rowMenu.addItem(up)
    }
    if index + 1 < total {
      let down = NSMenuItem(title: String(localized: "Move Down", comment: "Checklist context menu"),
                            action: #selector(moveDownPressed), keyEquivalent: "")
      down.target = self
      rowMenu.addItem(down)
    }
    let del = NSMenuItem(title: String(localized: "Delete Step", comment: "Checklist context menu"),
                         action: #selector(deletePressed), keyEquivalent: "")
    del.target = self
    rowMenu.addItem(del)
    self.menu = rowMenu

    let row = NSStackView(views: [checkButton, field, deleteButton])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)

    checkButton.setContentHuggingPriority(.required, for: .horizontal)
    deleteButton.setContentHuggingPriority(.required, for: .horizontal)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    NSLayoutConstraint.activate([
      row.topAnchor.constraint(equalTo: topAnchor),
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
      checkButton.widthAnchor.constraint(equalToConstant: 18),
      deleteButton.widthAnchor.constraint(equalToConstant: 18),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitChecklistItemRow is code-only") }

  private func applyFieldStyle() {
    var attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: SeptaskKitTheme.notesFontSize),
      .foregroundColor: item.checked ? SeptaskKitTheme.inkSecondary : NSColor.labelColor,
    ]
    if item.checked {
      attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    field.attributedStringValue = NSAttributedString(string: item.title, attributes: attrs)
  }

  func focusTitle() {
    window?.makeFirstResponder(field)
    if let editor = field.currentEditor() {
      editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }
  }

  func flushIfDirty() {
    let text = field.stringValue
    if text != item.title {
      onCommitTitle?(item, text)
      item.title = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  @objc private func togglePressed() { onToggle?(item, false) }
  func toggleFromKeyboard() { onToggle?(item, true) }
  @objc private func deletePressed() { onDelete?(item, false) }
  @objc private func moveUpPressed() { onMoveOrder?(item, -1) }
  @objc private func moveDownPressed() { onMoveOrder?(item, 1) }

  func controlTextDidChange(_ obj: Notification) {
    let text = field.stringValue
    if text.contains("\n") || text.contains("\r") {
      let lines = text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      if lines.count > 1 {
        onPasteLines?(item, lines)
      }
    }
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    flushIfDirty()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    switch sel {
    case #selector(NSResponder.insertNewline(_:)):
      flushIfDirty()
      onInsertBelow?(item)
      return true
    case #selector(NSResponder.deleteBackward(_:)):
      if textView.string.isEmpty {
        onDelete?(item, true)
        return true
      }
      return false
    case #selector(NSResponder.moveUp(_:)):
      flushIfDirty()
      onMoveFocus?(item, -1)
      return true
    case #selector(NSResponder.moveDown(_:)):
      flushIfDirty()
      onMoveFocus?(item, 1)
      return true
    // Tab walks the steps like ↓ (and out to the rail past the last), the
    // same loop as the SwiftUI editor's `focusOrder`.
    case #selector(NSResponder.insertTab(_:)):
      flushIfDirty()
      onMoveFocus?(item, 1)
      return true
    case #selector(NSResponder.insertBacktab(_:)):
      flushIfDirty()
      onMoveFocus?(item, -1)
      return true
    default:
      return false
    }
  }
}

// MARK: - Mac Task Attachments (Quick Look, Drag & Drop, Paste, Undo — docs/ATTACHMENTS_MAC_PARITY_SPEC.md)

/// Shared Quick Look panel coordinator for Mac task attachment chips.
@MainActor
final class KitQuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  static let shared = KitQuickLookCoordinator()
  private var urls: [URL] = []

  func preview(urls: [URL], startingAt index: Int = 0) {
    guard !urls.isEmpty else { return }
    self.urls = urls
    guard let panel = QLPreviewPanel.shared() else { return }
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    panel.currentPreviewItemIndex = min(max(0, index), urls.count - 1)
    if panel.isVisible {
      panel.orderFront(nil)
    } else {
      panel.makeKeyAndOrderFront(nil)
    }
  }

  nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    MainActor.assumeIsolated { urls.count }
  }

  nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
    MainActor.assumeIsolated {
      guard urls.indices.contains(index) else { return nil }
      return urls[index] as NSURL
    }
  }
}

/// Helper for attaching files or clipboard images onto a task via
/// `TaskAttachmentStore`. Returns how many attachments were added.
@MainActor
enum KitAttachmentPasteHelper {
  @discardableResult
  static func attachFiles(_ urls: [URL], to taskID: String, presentErrorIn window: NSWindow? = nil) -> Int {
    let store = SeptenaServices.shared.taskAttachmentStore
    var added = 0
    var lastError: Error?
    for url in urls {
      do {
        try store.add(taskID: taskID, sourceURL: url)
        added += 1
      } catch {
        lastError = error
      }
    }
    if let lastError, added == 0 {
      presentError(lastError, in: window)
    }
    return added
  }

  /// Attaches file URLs or an image (e.g. screenshot) from `NSPasteboard.general`.
  /// Returns `true` if the pasteboard contained attachable file(s) or image data.
  @discardableResult
  static func attachFromPasteboard(to taskID: String, presentErrorIn window: NSWindow? = nil) -> Bool {
    let pb = NSPasteboard.general
    if let urls = pb.readObjects(forClasses: [NSURL.self],
                                 options: [.urlReadingFileURLsOnly: true]) as? [URL],
       !urls.isEmpty {
      let fileURLs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
      if !fileURLs.isEmpty {
        _ = attachFiles(fileURLs, to: taskID, presentErrorIn: window)
        return true
      }
    }
    if let pngData = pb.data(forType: .png) {
      return attachImageData(pngData, ext: "png", uti: UTType.png.identifier, to: taskID, window: window)
    }
    if let tiffData = pb.data(forType: .tiff),
       let rep = NSBitmapImageRep(data: tiffData),
       let pngData = rep.representation(using: .png, properties: [:]) {
      return attachImageData(pngData, ext: "png", uti: UTType.png.identifier, to: taskID, window: window)
    }
    return false
  }

  private static func attachImageData(_ data: Data, ext: String, uti: String,
                                      to taskID: String, window: NSWindow?) -> Bool {
    let filename = TaskAttachmentFiles.pastedImageFilename(ext: ext)
    do {
      try SeptenaServices.shared.taskAttachmentStore.add(
        taskID: taskID, data: data, filename: filename, contentType: uti)
      return true
    } catch {
      presentError(error, in: window)
      return true
    }
  }

  static func presentError(_ error: Error, in window: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(localized: "Couldn't attach file", comment: "Attachment error title")
    alert.informativeText = error.localizedDescription
    if let window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }
}

/// Progressive-disclosure attachment strip shared by `KitComposerCell` and
/// `SeptaskKitInspectorController`. Hidden (height 0) when the task has no
/// attachments; supports Quick Look on click, right-click Save/Reveal/Delete
/// with `TaskUndo`, `NSOpenPanel`, and Finder drag-and-drop.
@MainActor
final class KitAttachmentsView: NSView {
  static let chipHeight: CGFloat = 24
  private static let upsellHeight: CGFloat = 20
  private static let rowSpacing: CGFloat = 4

  var onChanged: (() -> Void)?

  private let stack = NSStackView()
  private var taskID: String?
  private var items: [TaskAttachmentEntity] = []
  private var explicitUpsell: RegistryPlanNote?

  private var store: TaskAttachmentStore { SeptenaServices.shared.taskAttachmentStore }
  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }

  var attachmentCount: Int { items.count }

  private var hasLocalOnlyItems: Bool {
    items.contains { TaskSyncEngine.shared.isAttachmentLocalOnly($0.id) }
  }

  private var hasElsewhereItems: Bool {
    items.contains { TaskSyncEngine.shared.isAttachmentElsewhere($0) }
  }

  private var activeUpsell: RegistryPlanNote? {
    if let explicitUpsell { return explicitUpsell }
    if hasElsewhereItems || hasLocalOnlyItems { return RegistryPlans.upsell("file_elsewhere") }
    return nil
  }

  var preferredHeight: CGFloat {
    guard !items.isEmpty else { return 0 }
    var h = CGFloat(items.count) * Self.chipHeight
      + CGFloat(max(0, items.count - 1)) * Self.rowSpacing
    if activeUpsell != nil {
      h += Self.rowSpacing + Self.upsellHeight
    }
    return h
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    registerForDraggedTypes([.fileURL])

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Self.rowSpacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("KitAttachmentsView is code-only") }

  func configure(taskID: String) {
    if self.taskID != taskID { explicitUpsell = nil }
    self.taskID = taskID
    reload()
  }

  func reload() {
    guard let taskID else {
      items = []
      isHidden = true
      rebuild()
      return
    }
    items = store.attachments(taskID: taskID)
    isHidden = items.isEmpty
    rebuild()
  }

  func pickFilesToAttach() {
    guard let taskID else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.prompt = String(localized: "Attach", comment: "NSOpenPanel attach prompt")
    let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self, response == .OK else { return }
      let added = KitAttachmentPasteHelper.attachFiles(panel.urls, to: taskID, presentErrorIn: self.window)
      if added > 0 {
        self.reload()
        self.onChanged?()
      }
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: handle)
    } else {
      handle(panel.runModal())
    }
  }

  private func rebuild() {
    for v in stack.arrangedSubviews {
      stack.removeArrangedSubview(v)
      v.removeFromSuperview()
    }
    for (idx, item) in items.enumerated() {
      let baseSize = ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)
      let localOnly = TaskSyncEngine.shared.isAttachmentLocalOnly(item.id)
      let sizeText = localOnly ? "\(baseSize) · \(RegistryPlans.Status.device)" : baseSize
      let chip = KitAttachmentChipView(
        filename: item.filename,
        sizeText: sizeText,
        hasLocalFile: TaskAttachmentFiles.url(for: item).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
      )
      chip.onQuickLook = { [weak self] in self?.quickLook(at: idx) }
      chip.onReveal = { [weak self] in self?.reveal(item) }
      chip.onSaveCopy = { [weak self] in self?.saveCopy(item) }
      chip.onDelete = { [weak self] in self?.delete(item) }
      stack.addArrangedSubview(chip)
      chip.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
      chip.heightAnchor.constraint(equalToConstant: Self.chipHeight).isActive = true
    }
    if let moment = activeUpsell {
      let row = upsellRowView(moment)
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
      row.heightAnchor.constraint(equalToConstant: Self.upsellHeight).isActive = true
    }
  }

  private func upsellRowView(_ moment: RegistryPlanNote) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    let showElsewhereTitle = explicitUpsell != nil || hasElsewhereItems
    let label = NSTextField(labelWithString: showElsewhereTitle ? moment.title : moment.detail)
    label.font = SeptaskKitTheme.meta
    label.textColor = SeptaskKitTheme.inkSecondary
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    let button = NSButton(title: RegistryPlans.Paywall.seePlus, target: self, action: #selector(seePlus))
    button.bezelStyle = .inline
    button.font = SeptaskKitTheme.meta
    button.refusesFirstResponder = true
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    row.addArrangedSubview(label)
    row.addArrangedSubview(button)
    return row
  }

  @objc private func seePlus() {
    guard let presenter = window?.contentViewController else { return }
    SeptaskPlusSheet.present(upsellID: activeUpsell?.id ?? "file_elsewhere", from: presenter)
  }

  private func quickLook(at index: Int) {
    guard items.indices.contains(index) else { return }
    let target = items[index]
    if let url = TaskAttachmentFiles.url(for: target), FileManager.default.fileExists(atPath: url.path) {
      let urls = items.compactMap { entity -> URL? in
        guard let u = TaskAttachmentFiles.url(for: entity),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
      }
      let startIdx = urls.firstIndex(of: url) ?? 0
      KitQuickLookCoordinator.shared.preview(urls: urls, startingAt: startIdx)
      return
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if let downloaded = try await self.store.localFile(for: target) {
          self.reload()
          KitQuickLookCoordinator.shared.preview(urls: [downloaded], startingAt: 0)
        } else if TaskSyncEngine.shared.isAttachmentElsewhere(target),
                  let moment = RegistryPlans.upsell("file_elsewhere") {
          self.explicitUpsell = moment
          self.rebuild()
          self.onChanged?()
        }
      } catch TaskBackendError.limitReached(let limit) {
        PlanStatus.shared.noteLimitReached(limit)
        self.explicitUpsell = limit.upsellNote ?? RegistryPlans.upsell("file_elsewhere")
        self.rebuild()
        self.onChanged?()
      } catch TaskBackendError.http(let status, _) where status == 404 {
        if !PlanStatus.shared.attachmentsAllowed || TaskSyncEngine.shared.isAttachmentElsewhere(target),
           let moment = RegistryPlans.upsell("file_elsewhere") {
          self.explicitUpsell = moment
          self.rebuild()
          self.onChanged?()
        }
      } catch {
        KitAttachmentPasteHelper.presentError(error, in: self.window)
      }
    }
  }

  private func reveal(_ entity: TaskAttachmentEntity) {
    guard let url = TaskAttachmentFiles.url(for: entity),
          FileManager.default.fileExists(atPath: url.path) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func saveCopy(_ entity: TaskAttachmentEntity) {
    guard let src = TaskAttachmentFiles.url(for: entity),
          FileManager.default.fileExists(atPath: src.path) else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = entity.filename
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let dest = panel.url else { return }
      try? FileManager.default.removeItem(at: dest)
      try? FileManager.default.copyItem(at: src, to: dest)
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      finish(panel.runModal())
    }
  }

  private func delete(_ entity: TaskAttachmentEntity) {
    let snap = store.removeForUndo(entity)
    TaskUndo.recordAttachmentDelete(snap, store: store, mutator: mutator)
    reload()
    onChanged?()
  }

  // MARK: Drag & Drop

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard taskID != nil,
          let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                           options: [.urlReadingFileURLsOnly: true]) as? [URL],
          !urls.isEmpty else { return [] }
    return .copy
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard let taskID,
          let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                           options: [.urlReadingFileURLsOnly: true]) as? [URL],
          !urls.isEmpty else { return false }
    let added = KitAttachmentPasteHelper.attachFiles(urls, to: taskID, presentErrorIn: window)
    if added > 0 {
      reload()
      onChanged?()
    }
    return added > 0
  }
}

@MainActor
private final class KitAttachmentChipView: NSView {
  var onQuickLook: (() -> Void)?
  var onReveal: (() -> Void)?
  var onSaveCopy: (() -> Void)?
  var onDelete: (() -> Void)?

  private let deleteButton = NSButton()
  private var hovered = false
  private var tracking: NSTrackingArea?

  init(filename: String, sizeText: String, hasLocalFile: Bool) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.borderWidth = 0.75
    layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor

    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: hasLocalFile ? "paperclip" : "icloud.and.arrow.down",
                         accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
    icon.contentTintColor = SeptaskKitTheme.inkSecondary
    icon.translatesAutoresizingMaskIntoConstraints = false

    let nameLabel = NSTextField(labelWithString: filename)
    nameLabel.font = .systemFont(ofSize: SeptenaTypeScale.size(.caption1), weight: .medium)
    nameLabel.textColor = .labelColor
    nameLabel.lineBreakMode = .byTruncatingMiddle
    nameLabel.maximumNumberOfLines = 1
    nameLabel.translatesAutoresizingMaskIntoConstraints = false

    let sizeLabel = NSTextField(labelWithString: sizeText)
    sizeLabel.font = .systemFont(ofSize: SeptenaTypeScale.size(.caption2))
    sizeLabel.textColor = SeptaskKitTheme.inkSecondary
    sizeLabel.setContentHuggingPriority(.required, for: .horizontal)
    sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    sizeLabel.translatesAutoresizingMaskIntoConstraints = false

    deleteButton.isBordered = false
    deleteButton.bezelStyle = .inline
    deleteButton.imagePosition = .imageOnly
    deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete attachment")?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    deleteButton.contentTintColor = SeptaskKitTheme.inkSecondary
    deleteButton.target = self
    deleteButton.action = #selector(deletePressed)
    deleteButton.translatesAutoresizingMaskIntoConstraints = false
    deleteButton.alphaValue = 0.65

    addSubview(icon)
    addSubview(nameLabel)
    addSubview(sizeLabel)
    addSubview(deleteButton)

    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 12),
      nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
      nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      sizeLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
      sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      deleteButton.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 4),
      deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
      deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      deleteButton.widthAnchor.constraint(equalToConstant: 14),
      deleteButton.heightAnchor.constraint(equalToConstant: 14),
    ])

    let menu = NSMenu()
    menu.addItem(withTitle: String(localized: "Quick Look", comment: "Attachment menu"),
                 action: #selector(quickLookPressed), keyEquivalent: "").target = self
    menu.addItem(withTitle: String(localized: "Save Copy…", comment: "Attachment menu"),
                 action: #selector(saveCopyPressed), keyEquivalent: "").target = self
    menu.addItem(withTitle: String(localized: "Reveal in Finder", comment: "Attachment menu"),
                 action: #selector(revealPressed), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: String(localized: "Delete", comment: "Attachment menu"),
                 action: #selector(deletePressed), keyEquivalent: "").target = self
    self.menu = menu
    setAccessibilityRole(.button)
    setAccessibilityLabel("\(filename), \(sizeText)")
  }

  required init?(coder: NSCoder) { fatalError("KitAttachmentChipView is code-only") }

  override func draw(_ dirtyRect: NSRect) {
    if hovered {
      NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                              owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; deleteButton.alphaValue = 1.0; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; deleteButton.alphaValue = 0.65; needsDisplay = true }
  override func mouseUp(with event: NSEvent) { onQuickLook?() }

  @objc private func quickLookPressed() { onQuickLook?() }
  @objc private func saveCopyPressed() { onSaveCopy?() }
  @objc private func revealPressed() { onReveal?() }
  @objc private func deletePressed() { onDelete?() }
}
#endif
