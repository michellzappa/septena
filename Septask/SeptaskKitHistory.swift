#if os(macOS)
import AppKit

// The inspector's History section: who changed the task and what, newest
// first, from the task backend's change log (`TaskHistory`, SeptenaCore).
// Collapsed by default. The log loads only when the section is open, and
// again for each task shown while it stays open, so selecting rows never
// waits on the network.
@MainActor
final class KitHistoryView: NSStackView {
  /// Names an area or project id for "Moved to …"; nil when unknown.
  var listTitle: (String) -> String? = { _ in nil }

  private let toggle = NSButton()
  private let rows = NSStackView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private var taskID: String?
  private var expanded = false
  private var loaded: String?
  private var loadTask: Task<Void, Never>?

  init() {
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 8

    toggle.isBordered = false
    toggle.bezelStyle = .inline
    toggle.imagePosition = .imageLeading
    toggle.font = SeptaskKitTheme.chip
    toggle.contentTintColor = SeptaskKitTheme.iconMuted
    toggle.target = self
    toggle.action = #selector(toggleExpanded)
    // Keyboard focus stays on the fields, like the close button.
    toggle.refusesFirstResponder = true

    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 10
    status.font = SeptaskKitTheme.meta
    status.textColor = SeptaskKitTheme.inkSecondary

    addArrangedSubview(toggle)
    addArrangedSubview(status)
    addArrangedSubview(rows)
    // Full width, so the wrapping labels wrap at the pane edge.
    rows.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    status.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    updateToggle()
    render(nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// Shows the section for a task. Returns false, and hides it, where the
  /// backend does not own tasks: there is no log to read.
  @discardableResult
  func configure(taskID: String) -> Bool {
    isHidden = !TaskHistory.isAvailable
    guard !isHidden else { return false }
    if taskID != self.taskID {
      self.taskID = taskID
      loaded = nil
      loadTask?.cancel()
      render(nil)
    }
    if expanded { loadIfNeeded() }
    return true
  }

  @objc private func toggleExpanded() {
    expanded.toggle()
    // Each open reads the log again: it may have grown since.
    loaded = nil
    loadTask?.cancel()
    updateToggle()
    render(nil)
    if expanded { loadIfNeeded() }
  }

  private func updateToggle() {
    toggle.title = String(localized: "History", comment: "SeptaskKit: inspector section")
    toggle.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                           accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    toggle.setAccessibilityExpanded(expanded)
  }

  private func loadIfNeeded() {
    guard let id = taskID, loaded != id else { return }
    loaded = id
    status.stringValue = String(localized: "Loading…", comment: "SeptaskKit: history loading")
    status.isHidden = false
    loadTask = Task { [weak self] in
      let result: Result<[BackendChange], Error>
      do { result = .success(try await TaskBackendClient.shared.history(taskID: id)) } catch { result = .failure(error) }
      guard let self, !Task.isCancelled, self.taskID == id, self.expanded else { return }
      switch result {
      case .success(let changes): self.render(TaskHistory.rows(changes, listTitle: self.listTitle))
      case .failure:
        self.render([])
        self.status.stringValue = String(localized: "Couldn’t load history.", comment: "SeptaskKit: history error")
        self.status.isHidden = false
      }
    }
  }

  /// nil clears the rows (collapsed, or a load in flight).
  private func render(_ items: [TaskHistoryRow]?) {
    rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
    status.isHidden = !expanded || items == nil
    rows.isHidden = !expanded
    guard let items else { return }
    if items.isEmpty {
      status.stringValue = String(localized: "No changes yet.", comment: "SeptaskKit: history empty")
      return
    }
    status.isHidden = true
    let now = DayClock.appNow
    for item in items {
      let row = Self.rowView(item, now: now)
      rows.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
  }

  private static func rowView(_ item: TaskHistoryRow, now: Date) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    for line in item.lines {
      let label = NSTextField(wrappingLabelWithString: line)
      label.font = SeptaskKitTheme.meta
      label.textColor = SeptaskKitTheme.inkPrimary
      label.maximumNumberOfLines = 2
      label.cell?.truncatesLastVisibleLine = true
      stack.addArrangedSubview(label)
      label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    let byline = NSTextField(labelWithString: "\(item.who) · \(TaskHistory.relative(item.date, now: now))")
    // Claude's changes carry a heavier label, not a second color.
    byline.font = item.byClaude ? SeptaskKitTheme.metaStrong : SeptaskKitTheme.meta
    byline.textColor = SeptaskKitTheme.inkSecondary
    stack.addArrangedSubview(byline)
    return stack
  }
}
#endif
