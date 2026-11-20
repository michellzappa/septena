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

  /// The card slice this position paints: outer corners round only at the
  /// card's top and bottom. One geometry for the chrome and the context-menu
  /// preview, so the lifted row has exactly the card's outline.
  var cardShape: UnevenRoundedRectangle {
    let radius = TaskCardMetrics.radius
    let topRadius = (self == .top || self == .solo) ? radius : 0
    let bottomRadius = (self == .bottom || self == .solo) ? radius : 0
    return UnevenRoundedRectangle(
      topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius,
      bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius,
      style: .continuous)
  }

  /// Space `TaskCardChrome` adds under the slice to part this card from the
  /// next one.
  var trailingGap: CGFloat {
    (self == .bottom || self == .solo) ? TaskCardMetrics.groupGap : 0
  }
}

/// A row's visible card slice, in the frame of the view AFTER
/// `taskCardChrome` (which adds the side margins and the gap below a card).
/// Used as the context-menu preview shape, so the system lift carries the
/// card background with the row instead of only its text.
struct TaskCardSliceShape: Shape {
  let position: TaskCardPosition

  func path(in rect: CGRect) -> Path {
    let margin = TaskCardMetrics.margin
    let slice = CGRect(x: rect.minX + margin,
                       y: rect.minY,
                       width: max(0, rect.width - margin * 2),
                       height: max(0, rect.height - position.trailingGap))
    return position.cardShape.path(in: slice)
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
    let shape = position.cardShape
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
      .padding(.bottom, position.trailingGap)
      .onHover { hovered = $0 }
  }
}

extension View {
  func taskCardChrome(_ position: TaskCardPosition, isSelected: Bool = false) -> some View {
    modifier(TaskCardChrome(position: position, isSelected: isSelected))
  }

  /// The row's context menu. Attach it AFTER `taskCardChrome`: the system
  /// lift snapshots the view the menu sits on, so a menu attached inside the
  /// chrome lifts only the text and leaves the card behind. The preview shape
  /// clips the snapshot to the card slice (no side margins, no group gap).
  func taskCardContextMenu<MenuItems: View>(
    _ position: TaskCardPosition,
    @ViewBuilder menuItems: () -> MenuItems
  ) -> some View {
    #if os(iOS)
    contentShape(.contextMenuPreview, TaskCardSliceShape(position: position))
      .contextMenu(menuItems: menuItems)
    #else
    // macOS shows no lift preview; the menu alone.
    contextMenu(menuItems: menuItems)
    #endif
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
