#if os(macOS)
import AppKit

// The inspector's History panel: who changed the task and what, newest
// first, from the task backend's change log (`TaskHistory`, SeptenaCore).
// The inspector's History button opens it (registry `taskAttributes`
// `history`, the same attribute as the SwiftUI History pill). Closed by
// default. The log loads only while the panel is open, and again for each
// task shown while it stays open, so selecting rows never waits on the
// network.
@MainActor
final class KitHistoryView: NSStackView {
  /// Names an area or project id for "Moved to …"; nil when unknown.
  var listTitle: (String) -> String? = { _ in nil }

  private let rows = NSStackView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private var taskID: String?
  private var expanded = false
  private var loaded: String?
  private var edgeUpsellID: String?
  private var loadTask: Task<Void, Never>?

  init() {
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 8

    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 10
    status.font = SeptaskKitTheme.meta
    status.textColor = SeptaskKitTheme.inkSecondary

    addArrangedSubview(status)
    addArrangedSubview(rows)
    // Full width, so the wrapping labels wrap at the pane edge.
    rows.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    status.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    isHidden = true
    render(nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// Points the panel at a task. Returns false where the backend does not
  /// own tasks: there is no log to read, and the History button hides.
  @discardableResult
  func configure(taskID: String) -> Bool {
    guard TaskHistory.isAvailable else {
      isHidden = true
      return false
    }
    if taskID != self.taskID {
      self.taskID = taskID
      loaded = nil
      loadTask?.cancel()
      render(nil)
    }
    if expanded { loadIfNeeded() }
    return true
  }

  /// Opens or closes the panel. Each open reads the log again: it may have
  /// grown since.
  func setExpanded(_ open: Bool) {
    expanded = open
    isHidden = !open
    loaded = nil
    loadTask?.cancel()
    render(nil)
    if open { loadIfNeeded() }
  }

  private func loadIfNeeded() {
    guard let id = taskID, loaded != id else { return }
    loaded = id
    status.stringValue = String(localized: "Loading…", comment: "SeptaskKit: history loading")
    status.isHidden = false
    loadTask = Task { [weak self] in
      let result: Result<BackendChangesResponse, Error>
      do { result = .success(try await TaskBackendClient.shared.history(taskID: id)) } catch { result = .failure(error) }
      guard let self, !Task.isCancelled, self.taskID == id, self.expanded else { return }
      switch result {
      case .success(let page):
        self.render(TaskHistory.rows(page.changes, listTitle: self.listTitle),
                    edge: TaskHistory.edgeUpsell(page))
      case .failure(let error):
        if case TaskBackendError.limitReached(let limit) = error {
          PlanStatus.shared.noteLimitReached(limit)
          if let note = limit.upsellNote {
            self.render([], edge: note)
            return
          }
        }
        self.render([])
        self.status.stringValue = String(localized: "Couldn’t load history.", comment: "SeptaskKit: history error")
        self.status.isHidden = false
      }
    }
  }

  /// nil clears the rows (collapsed, or a load in flight). `edge` is the
  /// `history_edge` upsell the server sent for the free plan (spec §3.2).
  private func render(_ items: [TaskHistoryRow]?, edge: RegistryPlanNote? = nil) {
    rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
    status.isHidden = !expanded || items == nil
    rows.isHidden = !expanded
    guard let items else { return }
    if items.isEmpty, edge == nil {
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
    if let edge {
      edgeUpsellID = edge.id
      let line = edgeView(edge)
      rows.addArrangedSubview(line)
      line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    } else {
      edgeUpsellID = nil
    }
  }

  /// A quiet last line: older changes are hidden, one click to Plus. The
  /// detail shows until the account has seen this moment; after that only
  /// the title and the button stay (spec §7.1).
  private func edgeView(_ moment: RegistryPlanNote) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    let seen = SettingsMirror.upsellsSeen(context: LocalStore.shared.container.mainContext).contains(moment.id)
    for text in seen ? [moment.title] : [moment.title, moment.detail] {
      let label = NSTextField(wrappingLabelWithString: text)
      label.font = SeptaskKitTheme.meta
      label.textColor = SeptaskKitTheme.inkSecondary
      stack.addArrangedSubview(label)
      label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    let button = NSButton(title: RegistryPlans.Paywall.seePlus, target: self, action: #selector(seePlus))
    button.bezelStyle = .inline
    button.font = SeptaskKitTheme.meta
    button.refusesFirstResponder = true
    stack.addArrangedSubview(button)
    return stack
  }

  @objc private func seePlus() {
    guard let presenter = window?.contentViewController else { return }
    SeptaskPlusSheet.present(upsellID: edgeUpsellID ?? "history_edge", from: presenter)
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
