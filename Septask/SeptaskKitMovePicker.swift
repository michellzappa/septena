#if os(macOS)
import AppKit
import SwiftData

// The Move command's picker (⌘M / ⌘⇧M / Task ▸ Move…, and the row context menu's
// "Move to…") — the AppKit counterpart of SwiftUI's `MovePickerSheet`
// (Septena/Shell/Tasks/TaskPickerSheets.swift). Lists No List, loose
// projects, then each area with its projects nested underneath — type to
// filter, arrows + Return to choose.
//
// It is the surface that shows BOTH tiers of SeptaskKitSurface.swift, because
// its scope changes with the selection: moving ONE row anchors a popover to
// that row (Tier 1, alongside When / Deadline / Repeat), while moving a
// multi-selection has no single row to point at and falls back to the centered
// command panel (Tier 2, alongside Quick Find). Same body either way — one
// destination list, one keyboard contract, two placements.
@MainActor
final class SeptaskKitMovePicker {
  private struct Row {
    let title: String
    let destination: KitMoveMenu.Destination
    let emoji: String?
    let indent: Bool
    let projectId: String?
  }

  private let onChoose: (KitMoveMenu.Destination) -> Void
  private var allRows: [Row] = []
  private var rows: [Row] = []
  private var progressByProject: [String: Double] = [:]
  /// Marks the checkmark row — nil for a bulk move (no single "current" to
  /// mark, matching `MovePickerSheet.showCurrentSelection`).
  private var currentDestination: KitMoveMenu.Destination?

  private lazy var surface: KitFilterSurface = {
    let surface = KitFilterSurface(
      size: NSSize(width: 420, height: 340),
      a11yTitle: String(localized: "Move", comment: "SeptaskKit: move picker a11y title"),
      fieldA11yTitle: String(localized: "Filter destinations",
                             comment: "SeptaskKit: move picker search field a11y"))
    surface.rowCount = { [weak self] in self?.rows.count ?? 0 }
    surface.rowView = { [weak self] row in self?.cell(for: row) }
    surface.onQueryChanged = { [weak self] in self?.reloadRows() }
    surface.onChoose = { [weak self] row in self?.choose(row) }
    return surface
  }()

  private var context: ModelContext { LocalStore.shared.container.mainContext }

  init(onChoose: @escaping (KitMoveMenu.Destination) -> Void) {
    self.onChoose = onChoose
  }

  // MARK: - Presentation

  /// `current` marks the checkmark row; `title` becomes the field's
  /// placeholder ("Move" vs "Move N Tasks", matching `MovePickerSheet`'s
  /// navigation title exactly). `anchor` decides the tier: pass the row's rect
  /// when exactly one row is moving, `.window` otherwise.
  func show(current: KitMoveMenu.Destination?, title: String, anchor: KitSurfaceAnchor) {
    currentDestination = current
    reloadProgress()
    // `show` clears the query, which reloads the rows through `onQueryChanged`.
    surface.show(anchor: anchor, placeholder: title)
  }

  // MARK: - Filtering

  private func reloadProgress() {
    var done: [String: Int] = [:]
    var total: [String: Int] = [:]
    for task in LocalCache.tasksWithProject(in: context) {
      guard let pid = task.project else { continue }
      switch task.status {
      case .done: done[pid, default: 0] += 1; total[pid, default: 0] += 1
      case .open: total[pid, default: 0] += 1
      case .cancelled: break
      }
    }
    progressByProject = total.reduce(into: [:]) { acc, kv in
      acc[kv.key] = Double(done[kv.key] ?? 0) / Double(kv.value)
    }
  }

  private func reloadRows() {
    let query = surface.query.lowercased()
    let snapshot = StructureCache.snapshot(in: context)
    allRows = KitMoveMenu.pickerDestinations(areas: snapshot.areas, projects: snapshot.projects)
      .map { entry in
        Row(title: entry.title, destination: entry.target, emoji: entry.emoji,
            indent: entry.indent, projectId: entry.projectId)
      }
    rows = query.isEmpty ? allRows : Self.filterPickerRows(allRows, query: query)
    surface.reload()
    selectCurrentOrFirst()
  }

  /// SwiftUI `MovePickerSheet` filter: keep No List / loose projects by title;
  /// keep an area if its title matches or any child project matches; keep a
  /// nested project only when its title matches (and emit its parent area
  /// first when needed).
  private static func filterPickerRows(_ all: [Row], query: String) -> [Row] {
    let q = query.lowercased()
    func matches(_ title: String) -> Bool { title.lowercased().contains(q) }

    var result: [Row] = []
    var index = 0
    while index < all.count {
      let row = all[index]
      switch row.destination {
      case .none:
        if matches(row.title) { result.append(row) }
        index += 1
      case .project where !row.indent:
        if matches(row.title) { result.append(row) }
        index += 1
      case .area:
        var children: [Row] = []
        var cursor = index + 1
        while cursor < all.count {
          let next = all[cursor]
          guard case .project = next.destination, next.indent else { break }
          if matches(next.title) { children.append(next) }
          cursor += 1
        }
        if matches(row.title) || !children.isEmpty {
          result.append(row)
          // Area-title match still only lists children whose titles match
          // (SwiftUI `projectsIn` always filters by query).
          result.append(contentsOf: children)
        }
        index = cursor
      case .project:
        index += 1
      }
    }
    return result
  }

  /// With no query, mark where the task already lives. With a query, select the
  /// first row that matches the query ITSELF.
  ///
  /// Both fallbacks matter. `filterPickerRows` emits an area whenever one of its
  /// projects matches, so a query that names a project alone still puts the
  /// parent area first in the list — selecting row 0 there meant typing a
  /// project name and pressing Return filed the task into the AREA. And the
  /// `currentDestination` checkmark must not win once a query is typed, or
  /// filtering down to a project inside the task's current area re-selected that
  /// area for the same wrong result.
  private func selectCurrentOrFirst() {
    guard !rows.isEmpty else { return }
    let query = surface.query.lowercased()
    let target: Int
    if query.isEmpty {
      target = currentDestination.flatMap { current in
        rows.firstIndex { $0.destination == current }
      } ?? 0
    } else {
      target = rows.firstIndex { $0.title.lowercased().contains(query) } ?? 0
    }
    surface.select(target)
  }

  // MARK: - Choosing

  private func choose(_ row: Int) {
    guard rows.indices.contains(row) else { return }
    onChoose(rows[row].destination)
  }

  private func cell(for row: Int) -> NSView? {
    guard rows.indices.contains(row) else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("moveRowCell")
    let cell = surface.tableView.makeView(withIdentifier: identifier, owner: nil) as? MoveRowCell
      ?? MoveRowCell(identifier: identifier)
    let entry = rows[row]
    let checked = currentDestination.map { $0 == entry.destination } ?? false
    let progress = entry.projectId.flatMap { progressByProject[$0] } ?? 0
    cell.configure(destination: entry.destination, emoji: entry.emoji, title: entry.title,
                   indent: entry.indent, progress: progress, checked: checked)
    return cell
  }

  /// Result row: tray / area emoji-or-folder / project pie, title, trailing
  /// checkmark on the current destination — same anatomy as
  /// `MovePickerSheet`'s row.
  private final class MoveRowCell: NSTableCellView {
    private let icon = NSImageView()
    private let emoji = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private var leadingConstraint: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
      super.init(frame: .zero)
      self.identifier = identifier
      icon.translatesAutoresizingMaskIntoConstraints = false
      icon.contentTintColor = SeptaskKitTheme.iconMuted
      emoji.translatesAutoresizingMaskIntoConstraints = false
      emoji.font = .systemFont(ofSize: SeptenaTypeScale.size(.subheadline))
      title.translatesAutoresizingMaskIntoConstraints = false
      title.font = SeptaskKitTheme.taskTitle
      title.lineBreakMode = .byTruncatingTail
      checkmark.translatesAutoresizingMaskIntoConstraints = false
      checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
      checkmark.contentTintColor = SeptaskKitTheme.inkSecondary
      addSubview(icon)
      addSubview(emoji)
      addSubview(title)
      addSubview(checkmark)
      textField = title
      leadingConstraint = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: KitSurface.listInset)
      NSLayoutConstraint.activate([
        leadingConstraint,
        icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 14),
        icon.heightAnchor.constraint(equalToConstant: 14),
        emoji.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
        emoji.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
        title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
        title.centerYAnchor.constraint(equalTo: centerYAnchor),
        checkmark.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),
        checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -KitSurface.listInset),
        checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }

    required init?(coder: NSCoder) { fatalError("MoveRowCell is code-only") }

    func configure(destination: KitMoveMenu.Destination, emoji emojiGlyph: String?,
                   title titleText: String, indent: Bool, progress: Double, checked: Bool) {
      leadingConstraint.constant = indent ? KitSurface.listInset + 24 : KitSurface.listInset
      switch destination {
      case .none:
        icon.image = NSImage(systemSymbolName: "tray.fill", accessibilityDescription: nil)?
          .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        icon.contentTintColor = SeptaskKitTheme.iconMuted
        icon.isHidden = false
        emoji.isHidden = true
        title.font = SeptaskKitTheme.taskTitle
      case .area:
        if let emojiGlyph {
          emoji.stringValue = emojiGlyph
          emoji.isHidden = false
          icon.isHidden = true
        } else {
          icon.image = KitGlyph.areaDot(diameter: 12)
          icon.contentTintColor = nil
          icon.isHidden = false
          emoji.isHidden = true
        }
        title.font = .systemFont(ofSize: SeptaskKitTheme.taskTitle.pointSize, weight: .semibold)
      case .project:
        icon.image = KitGlyph.progress(progress, tint: SeptaskKitTheme.inkSecondary, diameter: 12)
        icon.contentTintColor = nil
        icon.isHidden = false
        emoji.isHidden = true
        title.font = SeptaskKitTheme.taskTitle
      }
      title.stringValue = titleText
      checkmark.isHidden = !checked
    }
  }
}
#endif
