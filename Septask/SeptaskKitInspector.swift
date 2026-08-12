#if os(macOS)
import AppKit
import SwiftData

// The task inspector: title, notes, and the scheduling attributes for the
// selected row, in a native split-view inspector pane (⌥⌘I). This is where
// notes live in the AppKit shell — the equivalent of the SwiftUI drawer
// inspector, and the reason task detail doesn't need a sheet.
//
// Writes go through TaskMutator like every other surface. Edits commit on
// blur and on selection change (`flushPendingEdits`), never on every
// keystroke — a per-keystroke write would push a CloudKit change per letter.
@MainActor
final class SeptaskKitInspectorController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {

  private let titleField = NSTextField()
  private let notesView = NSTextView()
  private let whenButton = NSButton()
  private let deadlineButton = NSButton()
  private let repeatPopUp = NSPopUpButton()
  private let listLabel = NSTextField(labelWithString: "")
  private let placeholder = NSTextField(labelWithString: String(localized: "No Selection",
                                                                 comment: "SeptaskKit: inspector empty"))
  private let form = NSStackView()

  private var task: SeptenaTask?
  /// What was loaded into the fields, so a commit can tell "the user changed
  /// this" from "this is what the store already says".
  private var loadedTitle = ""
  private var loadedNotes = ""

  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }
  private var context: ModelContext { LocalStore.shared.container.mainContext }

  override func loadView() {
    let root = NSView()

    titleField.font = .systemFont(ofSize: SeptenaTypeScale.size(.headline), weight: .semibold)
    titleField.isBordered = false
    titleField.drawsBackground = false
    titleField.focusRingType = .none
    titleField.lineBreakMode = .byTruncatingTail
    titleField.delegate = self
    titleField.translatesAutoresizingMaskIntoConstraints = false

    let notesScroll = NSScrollView()
    notesScroll.hasVerticalScroller = true
    notesScroll.drawsBackground = false
    notesScroll.translatesAutoresizingMaskIntoConstraints = false
    notesView.delegate = self
    notesView.font = .systemFont(ofSize: SeptenaTypeScale.size(.subheadline))
    notesView.isRichText = false
    notesView.drawsBackground = false
    notesView.textContainerInset = NSSize(width: 2, height: 6)
    notesView.isAutomaticQuoteSubstitutionEnabled = false
    notesScroll.documentView = notesView

    let notesLabel = NSTextField(labelWithString: String(localized: "Notes",
                                                         comment: "SeptaskKit: inspector field"))
    notesLabel.font = SeptaskKitTheme.chip
    notesLabel.textColor = SeptaskKitTheme.iconMuted

    for (button, action) in [(whenButton, #selector(editWhen)),
                             (deadlineButton, #selector(editDeadline))] {
      button.bezelStyle = .rounded
      button.target = self
      button.action = action
      button.alignment = .left
    }
    listLabel.font = SeptaskKitTheme.meta
    listLabel.textColor = SeptaskKitTheme.inkSecondary

    repeatPopUp.menu = KitRecurrenceMenu.build(target: self, action: #selector(repeatChanged(_:)))
    repeatPopUp.target = self

    form.orientation = .vertical
    form.alignment = .leading
    form.spacing = 8
    form.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    form.translatesAutoresizingMaskIntoConstraints = false
    form.addArrangedSubview(titleField)
    form.addArrangedSubview(listLabel)
    form.addArrangedSubview(whenButton)
    form.addArrangedSubview(deadlineButton)
    form.addArrangedSubview(repeatPopUp)
    form.addArrangedSubview(notesLabel)
    form.addArrangedSubview(notesScroll)
    form.setCustomSpacing(14, after: repeatPopUp)

    placeholder.textColor = SeptaskKitTheme.iconMuted
    placeholder.translatesAutoresizingMaskIntoConstraints = false

    root.addSubview(form)
    root.addSubview(placeholder)
    NSLayoutConstraint.activate([
      form.topAnchor.constraint(equalTo: root.topAnchor),
      form.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      form.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      form.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      titleField.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28),
      notesScroll.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28),
      notesScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
      placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
    ])
    view = root
    show(nil)
  }

  // MARK: - Selection

  /// Load a task (or clear). Any in-flight edit for the previous task commits
  /// first, so switching rows can't silently drop what was typed.
  ///
  /// Re-showing the SAME task (e.g. `refresh()` after a background sync)
  /// does NOT touch `titleField`/`notesView` — only the read-only fields
  /// (dates, list, repeat) resync. This is load-bearing, not cosmetic: this
  /// method used to overwrite the title field unconditionally, so a refresh
  /// landing between typing and committing silently reverted whatever the
  /// user had typed back to the stored value — and since that reset BOTH the
  /// field and `loadedTitle` together, the next commit's "did it change"
  /// check then saw no difference and never wrote the edit. `refresh()`'s
  /// `isEditing` guard was supposed to prevent this, but a field/store
  /// mismatch shouldn't be possible in the first place — belt and braces.
  func show(_ next: SeptenaTask?) {
    guard next?.id != task?.id else {
      task = next
      if let next { refreshReadOnlyFields(next) }
      return
    }
    flushPendingEdits()
    task = next

    guard let next, !next.isHeading else {
      form.isHidden = true
      placeholder.isHidden = false
      return
    }
    form.isHidden = false
    placeholder.isHidden = true

    if next.showsAgentCue() {
      mutator.acknowledge(id: next.id)
    }

    loadedTitle = next.title
    loadedNotes = next.notes ?? ""
    titleField.stringValue = loadedTitle
    notesView.string = loadedNotes
    refreshReadOnlyFields(next)
  }

  /// The dates/list/repeat controls — safe to resync on every re-show,
  /// same-task or not, since nothing here is a live text edit in progress.
  private func refreshReadOnlyFields(_ next: SeptenaTask) {
    let when: String = if next.today {
      String(localized: "Today", comment: "Smart list title")
    } else if let scheduled = next.scheduled {
      KitDayFormat.display(scheduled)
    } else {
      String(localized: "Anytime", comment: "Smart list title")
    }
    whenButton.title = String(localized: "When: \(when)",
                              comment: "SeptaskKit: inspector when field")
    let deadlineValue = next.deadline.map(KitDayFormat.display)
      ?? String(localized: "None", comment: "No deadline")
    deadlineButton.title = String(localized: "Deadline: \(deadlineValue)",
                                  comment: "SeptaskKit: inspector deadline field")
    listLabel.stringValue = listDescription(for: next)

    let repeatIndex = KitRecurrenceMenu.index(of: next.recurrence)
    if repeatIndex >= 0 {
      repeatPopUp.selectItem(at: repeatIndex)
    } else {
      // A cadence this menu doesn't offer (set in the SwiftUI sheet) — show
      // it rather than mislabeling the task as one of the presets.
      repeatPopUp.selectItem(at: -1)
      repeatPopUp.setTitle(next.recurrence?.shortLabel ?? "")
    }
  }

  /// Re-read the shown task from the store — used when a refresh lands while
  /// the inspector is open. `show(_:)`'s own same-id guard is now the real
  /// protection for in-progress title/notes edits; `isEditing` here just
  /// avoids pointless work while actively typing.
  func refresh() {
    guard let id = task?.id, !isEditing else { return }
    let fresh = LocalCache.allTasks(in: context).first { $0.id == id }
    show(fresh)
  }

  private var isEditing: Bool {
    view.window?.firstResponder === notesView
      || (view.window?.firstResponder as? NSTextView)?.delegate === titleField
  }

  private func listDescription(for task: SeptenaTask) -> String {
    let snapshot = StructureCache.snapshot(in: context)
    if let id = task.project,
       let project = snapshot.projects.first(where: { $0.id == id }) {
      return String(localized: "In \(project.title)",
                    comment: "SeptaskKit: inspector list affiliation")
    }
    if let id = task.area,
       let area = snapshot.areas.first(where: { $0.id == id }) {
      return String(localized: "In \(area.title)",
                    comment: "SeptaskKit: inspector list affiliation")
    }
    return String(localized: "No list", comment: "SeptaskKit: inspector list affiliation")
  }

  // MARK: - Commits

  /// Commit whatever is in the fields. Safe to call repeatedly — it only
  /// writes when a value actually differs from what was loaded.
  func flushPendingEdits() {
    guard let current = task else { return }
    var changed = false

    let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty, title != loadedTitle {
      mutator.update(id: current.id, title: title)
      loadedTitle = title
      changed = true
    }

    let notes = notesView.string
    if notes != loadedNotes {
      // Empty clears the note rather than storing an empty string.
      mutator.update(id: current.id, notes: notes.isEmpty ? nil : notes)
      loadedNotes = notes
      changed = true
    }

    if changed {
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
  }

  func controlTextDidEndEditing(_ obj: Notification) { flushPendingEdits() }

  func textDidEndEditing(_ notification: Notification) { flushPendingEdits() }

  // MARK: - Dates

  @objc private func repeatChanged(_ sender: NSMenuItem) {
    guard let current = task else { return }
    mutator.setRecurrence(id: current.id,
                          recurrence: KitRecurrenceMenu.recurrence(for: sender,
                                                                   preserving: current.recurrence))
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    refresh()
  }

  @objc private func editWhen() { presentPopover(kind: .when, from: whenButton) }
  @objc private func editDeadline() { presentPopover(kind: .deadline, from: deadlineButton) }

  private func presentPopover(kind: SeptaskKitDatePopover.Kind, from button: NSButton) {
    guard let current = task else { return }
    let initial: Date? = switch kind {
    case .when: KitDayFormat.date(fromWire: current.scheduled)
    case .deadline: KitDayFormat.date(fromWire: current.deadline)
    }

    SeptaskKitDatePopover.present(kind: kind, initial: initial,
                                  relativeTo: button.bounds, of: button) { [weak self] date, today in
      guard let self else { return }
      switch kind {
      case .when:
        if today {
          self.mutator.moveToToday(id: current.id)
        } else {
          self.mutator.schedule(id: current.id, date: date)
          self.mutator.removeFromToday(id: current.id)
        }
      case .deadline:
        self.mutator.setDeadline(id: current.id, date: date)
      }
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
      self.refresh()
    }
  }
}
#endif
