import SwiftUI
import UniformTypeIdentifiers

// MARK: - Grouped task-card chrome

/// A row's position inside a continuous task card. The card is painted by its
/// rows (rather than a wrapping container) so keyboard selection, drag, and
/// inline editing can remain direct children of the task scroll list.
enum TaskCardPosition {
  case solo, top, middle, bottom

  init(index: Int, count: Int) {
    if count <= 1 { self = .solo }
    else if index == 0 { self = .top }
    else if index == count - 1 { self = .bottom }
    else { self = .middle }
  }
}

/// Geometry shared by task rows, group headers, inline editors, sidebar cards,
/// and the Next feed. Keeping it here makes their alignment a single contract.
enum TaskCardMetrics {
  static let margin = Theme.pageGutter
  static let contentInset: CGFloat = 10
  static let radius: CGFloat = 14
  static let headerLeading = margin + contentInset
  static let groupGap = Theme.Spacing.sm
}

/// Drop target decoration for filing task rows into Today/areas/projects.
/// Kept independent of `TaskListView` so the task list owns only its drop
/// policy, not the presentation and transferable-data plumbing.
///
/// There are exactly TWO drop vocabularies on the task surfaces, and they mean
/// different things — do not "unify" them:
///   • drop INTO a container (this modifier) emphasizes the row/header itself,
///     so it reuses the canonical `Theme.listSelectionFill`, per the one
///     selection/target-language rule in CLAUDE.md;
///   • drop BETWEEN rows (`TaskReorderDrop`) marks a *position*, not a row, so
///     it parts a gap and draws an accent insertion line — the platform-standard
///     indicator, and the only way to show where in the order the drop lands.
/// A row can never wear both at once: reorder targets a gap, filing targets a row.
struct TaskMoveDrop: ViewModifier {
  let perform: ((_ ids: [String]) -> Bool)?
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    if let perform {
      content
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isTargeted ? Theme.listSelectionFill : Color.clear)
            .a11yAnimation(.easeOut(duration: 0.12), value: isTargeted)
        )
        .onDrop(of: [.septenaTaskDragIDs],
                delegate: TaskMoveDropDelegate(isTargeted: $isTargeted,
                                               perform: perform))
    } else {
      content
    }
  }
}

private struct TaskMoveDropDelegate: DropDelegate {
  @Binding var isTargeted: Bool
  let perform: (_ ids: [String]) -> Bool

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.septenaTaskDragIDs])
  }

  func dropEntered(info: DropInfo) { isTargeted = true }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    isTargeted = true
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) { isTargeted = false }

  func performDrop(info: DropInfo) -> Bool {
    isTargeted = false
    guard let provider = info.itemProviders(for: [.septenaTaskDragIDs]).first else { return false }
    provider.loadDataRepresentation(forTypeIdentifier: UTType.septenaTaskDragIDs.identifier) { data, _ in
      guard let data,
            let payload = try? JSONDecoder().decode(TaskDragIDs.self, from: data),
            !payload.ids.isEmpty
      else { return }
      DispatchQueue.main.async { _ = perform(payload.ids) }
    }
    return true
  }
}

private struct TaskCardChrome: ViewModifier {
  let position: TaskCardPosition
  var isSelected: Bool = false
  @State private var hovered = false

  func body(content: Content) -> some View {
    let radius = TaskCardMetrics.radius
    let topRadius = (position == .top || position == .solo) ? radius : 0
    let bottomRadius = (position == .bottom || position == .solo) ? radius : 0
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius,
      bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius,
      style: .continuous)
    content
      .environment(\.rowHInset, TaskCardMetrics.contentInset)
      .background(alignment: .bottom) {
        ZStack(alignment: .bottom) {
          shape.fill(isSelected ? Theme.listSelectionFill : Theme.cardSurface)
          if hovered && !isSelected {
            shape.fill(Color.primary.opacity(Theme.pointerHoverOpacity))
          }
          if (position == .top || position == .middle) && !isSelected {
            Rectangle().fill(Theme.border).frame(height: 0.5)
          }
        }
      }
      .padding(.horizontal, TaskCardMetrics.margin)
      .padding(.bottom, (position == .bottom || position == .solo) ? TaskCardMetrics.groupGap : 0)
      .onHover { hovered = $0 }
  }
}

extension View {
  func taskCardChrome(_ position: TaskCardPosition, isSelected: Bool = false) -> some View {
    modifier(TaskCardChrome(position: position, isSelected: isSelected))
  }

  /// Non-selectable full-width list content: headers, quick-add lines, and
  /// footer spacing. A custom `SelectableScrollList` needs no native List
  /// separator/inset overrides.
  func asListRow() -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Selectable task-row chrome and interaction routing.
  func asTaskRow(id: String, isSelected: Bool, isComplete: Bool? = nil) -> some View {
    selectableScrollRow(id: id, isSelected: isSelected, isComplete: isComplete)
  }

  /// Non-interactive decorative content within a task list.
  func plainListChrome() -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
  }
}
