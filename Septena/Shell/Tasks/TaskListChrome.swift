import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

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
  var isEditing: Bool = false
  @State private var hovered = false
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme
  #if SEPTASK
  private let appearance = AppearancePreferences.shared
  #endif

  private var effectiveShape: UnevenRoundedRectangle {
    #if os(iOS)
    isEditing ? TaskCardPosition.solo.cardShape : position.cardShape
    #else
    position.cardShape
    #endif
  }

  private var useLiquidGlass: Bool {
    #if SEPTASK
    return appearance.hasActiveTexture && !reduceTransparency && !isEditing
    #else
    return false
    #endif
  }

  func body(content: Content) -> some View {
    let shape = effectiveShape
    content
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .clipShape(shape)
      .environment(\.rowHInset, TaskCardMetrics.contentInset)
      .background(alignment: .bottom) {
        ZStack(alignment: .bottom) {
          if useLiquidGlass {
            #if os(iOS)
            // Translucent frosted glass without per-row live CoreAnimation
            // backdrop blurs (`shape.fill(.thinMaterial)` on 15+ scrolling rows
            // stalls ProMotion 120 Hz). Keeps the exact luminous floating-glass
            // feel over the crisp Header Wash contours at zero blur cost.
            shape.fill(Theme.cardSurface.opacity(colorScheme == .dark ? 0.78 : 0.80))
            shape.strokeBorder(
              Color.white.opacity(colorScheme == .dark ? 0.07 : 0.48),
              lineWidth: 0.5
            )
            #else
            shape.fill(.thinMaterial)
            shape.fill(Theme.cardSurface.opacity(colorScheme == .dark ? 0.28 : 0.36))
            #endif
            if isSelected {
              shape.fill(Theme.listSelectionFill)
            }
            if (position == .top || position == .solo) && !isSelected {
              VStack(spacing: 0) {
                Color.white.opacity(colorScheme == .dark ? 0.14 : 0.72)
                  .frame(height: 0.75)
                Spacer(minLength: 0)
              }
              .clipShape(shape)
            }
          } else {
            shape.fill((isSelected && !isEditing) ? Theme.listSelectionFill : Theme.cardSurface)
          }
          #if os(iOS)
          if isEditing {
            shape.strokeBorder(Theme.border, lineWidth: 0.5)
          }
          #endif
          #if os(macOS)
          if hovered && !isSelected && !isEditing {
            shape.fill(Color.primary.opacity(Theme.pointerHoverOpacity))
          }
          #endif
          if (position == .top || position == .middle) && !isSelected && !isEditing {
            Rectangle().fill(Theme.border).frame(height: 0.5)
          }
        }
        #if os(iOS)
        .shadow(
          color: isEditing ? Color.black.opacity(0.10) : .clear,
          radius: isEditing ? 12 : 0,
          y: isEditing ? 4 : 0
        )
        .overlay {
          if isEditing {
            // Absorb stray taps on empty space inside the open editor card so
            // they never fall through to the scroll list's dismiss backdrop.
            Color.clear
              .contentShape(shape)
              .onTapGesture {}
          }
        }
        #endif
      }
      .padding(.horizontal, TaskCardMetrics.margin)
      .padding(.bottom, position.trailingGap)
      #if os(macOS)
      .onHover { hovered = $0 }
      #endif
  }
}

/// iOS focus treatment while an inline task editor is open: every other row,
/// header, and surface in the list fades back and intercepts taps to close the
/// open editor instead of running its own action or opening another editor.
private struct InlineEditDimmedModifier: ViewModifier {
  let isDimmed: Bool
  let onDismiss: () -> Void

  func body(content: Content) -> some View {
    #if os(iOS)
    content
      .opacity(isDimmed ? 0.32 : 1)
      .allowsHitTesting(!isDimmed)
      .overlay {
        if isDimmed {
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture { onDismiss() }
        }
      }
      .a11yAnimation(Theme.Motion.inlineEdit, value: isDimmed)
    #else
    content
    #endif
  }
}

extension View {
  func taskCardChrome(_ position: TaskCardPosition,
                      isSelected: Bool = false,
                      isEditing: Bool = false) -> some View {
    modifier(TaskCardChrome(position: position, isSelected: isSelected, isEditing: isEditing))
  }

  func inlineEditDimmed(_ isDimmed: Bool, onDismiss: @escaping () -> Void) -> some View {
    modifier(InlineEditDimmedModifier(isDimmed: isDimmed, onDismiss: onDismiss))
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

// MARK: - Magic Plus interactive drag coordinator (iPhone compact)

/// What kind of drop target the dragged Magic Plus orb is currently hovering.
/// Every kind shows the same insertion line (`MagicPlusInsertionMark`).
enum MagicPlusDropKind: Equatable {
  /// Between two rows in a reorderable list.
  case taskRow(context: String?)
  /// Onto a section/heading/group/day header or a non-reorderable card. It
  /// makes a new task.
  case taskSection(label: String)
  /// A place on the Tasks index (list root), where the orb makes only
  /// Projects and Areas. `edge` says which insertion points the zone offers.
  case listInsert(edge: MagicPlusInsertEdge)
}

/// The insertion points a Tasks index zone offers (`MagicPlusDropKind.listInsert`).
enum MagicPlusInsertEdge: Equatable {
  /// Above and below the row (a Project between Projects).
  case both
  /// Above the row only (a new Area before this area's card).
  case top
  /// Below the row only (a new Project first in this area).
  case bottom
  /// The given distance below the row: the gap under the last card (a new
  /// Area at the end). It sits a card gap away from "below the row", so the
  /// two stay distinct places.
  case belowGap(CGFloat)
}

/// Live coordinator for the iPhone Magic Plus finger-tracking & morphing drag.
/// Injected optionally via `EnvironmentValues.magicPlusDrag` (nil on macOS,
/// iPad split, sheets, and previews — making every drop modifier a zero-cost
/// pass-through there with no launch-crash risk).
@MainActor
@Observable
final class MagicPlusDragState {
  struct ActiveTarget: Equatable {
    let id: String
    let kind: MagicPlusDropKind
    let before: Bool
    let frame: CGRect
  }

  private struct Zone {
    let id: String
    let kind: MagicPlusDropKind
    let priority: Int
    var frame: CGRect
    let onDrop: (_ before: Bool) -> Void
  }

  var isDragging = false
  /// True while the finger is dragged back over the bottom-right home socket
  /// (releasing here cancels the drag cleanly).
  var isOverCancelSocket = false
  /// Visual drag position in `.global` coordinates.
  var fingerLocation: CGPoint = .zero
  /// Center of the resting Magic Plus orb in `.global` coordinates (cancel zone).
  var homeCenter: CGPoint = .zero
  /// Currently targeted drop zone, if any.
  var activeTarget: ActiveTarget? = nil
  /// Drop action when no zone is registered at all (an empty list): the host
  /// creates a plain new task, so a drop outside the cancel socket always lands.
  @ObservationIgnored var fallbackDrop: (() -> Void)? = nil

  /// Non-observed registry so scrolling rows never trigger SwiftUI view invalidations.
  @ObservationIgnored private var zones: [String: Zone] = [:]

  func register(
    id: String,
    kind: MagicPlusDropKind,
    priority: Int,
    frame: CGRect,
    onDrop: @escaping (_ before: Bool) -> Void
  ) {
    guard frame.width > 0, frame.height > 0 else { return }
    zones[id] = Zone(id: id, kind: kind, priority: priority, frame: frame, onDrop: onDrop)
  }

  func unregister(id: String) {
    zones.removeValue(forKey: id)
    if activeTarget?.id == id {
      activeTarget = nil
    }
  }

  func beginDrag(at location: CGPoint) {
    isDragging = true
    isOverCancelSocket = false
    fingerLocation = location
    activeTarget = nil
    Haptics.press()
    resolveTarget(for: location)
  }

  func updateDrag(at location: CGPoint) {
    fingerLocation = location
    resolveTarget(for: location)
  }

  func endDrag(at location: CGPoint) {
    fingerLocation = location
    resolveTarget(for: location)
    let hit = isOverCancelSocket ? nil : activeTarget
    let action = hit.flatMap { zones[$0.id]?.onDrop }
    a11yAnimate(.snappy(duration: 0.22)) {
      isDragging = false
      isOverCancelSocket = false
      activeTarget = nil
    }
    if let hit, let action {
      action(hit.before)
    } else if !isOverHome(location) {
      fallbackDrop?()
    }
  }

  private func isOverHome(_ location: CGPoint) -> Bool {
    homeCenter != .zero
      && hypot(location.x - homeCenter.x, location.y - homeCenter.y) < 40
  }

  /// Clear stale zones when switching tabs / navigation routes.
  func reset() {
    isDragging = false
    isOverCancelSocket = false
    activeTarget = nil
    zones.removeAll()
  }

  private func resolveTarget(for location: CGPoint) {
    // Dragging back onto the resting orb socket cancels cleanly.
    let dx = location.x - homeCenter.x
    let dy = location.y - homeCenter.y
    let inCancelZone = homeCenter != .zero && hypot(dx, dy) < 48
    if inCancelZone {
      if !isOverCancelSocket {
        Haptics.selection()
      }
      if !isOverCancelSocket || activeTarget != nil {
        a11yAnimate(.snappy(duration: 0.18)) {
          isOverCancelSocket = true
          activeTarget = nil
        }
      }
      return
    }
    if isOverCancelSocket {
      a11yAnimate(.snappy(duration: 0.18)) {
        isOverCancelSocket = false
      }
    }

    // The drag draws no card (decided 2026-11-23): aim at the fingertip.
    let probeY = location.y

    // One list of insertion points (`insertionPoints`), and the list does
    // not move during the drag, so the target is the nearest point to what
    // the user sees. A small margin keeps the current point until another is
    // clearly nearer, so a finger resting between two points never flickers.
    let gaps = insertionPoints()
    guard !gaps.isEmpty else {
      if activeTarget != nil {
        a11yAnimate(.snappy(duration: 0.15)) { activeTarget = nil }
      }
      return
    }
    let open = activeTarget.flatMap { t in
      gaps.firstIndex { $0.id == t.id && $0.before == t.before }
    }
    var bestIndex = 0
    var bestDistance = CGFloat.infinity
    for k in gaps.indices {
      let d = abs(gaps[k].y - probeY)
      if d < bestDistance { bestDistance = d; bestIndex = k }
    }
    if let open, open != bestIndex,
       abs(gaps[open].y - probeY) - bestDistance < 10 {
      return
    }
    let g = gaps[bestIndex]
    if bestIndex == open { return }
    let next = ActiveTarget(id: g.id, kind: g.kind, before: g.before, frame: g.frame)
    Haptics.selection()
    a11yAnimate(.snappy(duration: 0.15)) {
      activeTarget = next
    }
  }

  /// One insertion point: where the mark shows, and which zone owns the drop.
  private struct Gap {
    let y: CGFloat
    let id: String
    let kind: MagicPlusDropKind
    let before: Bool
    let frame: CGRect
    /// Owner preference when two points share a place: a row's top is the
    /// most exact drop, then a header, then a row's bottom.
    let rank: Int
  }

  /// Every insertion point on screen, top to bottom, one per place.
  /// A row offers its top and its bottom; a header offers the place under
  /// it. Points closer than 16pt are ONE place ("after A" / "before B" on
  /// touching rows; "under the header" / "before the first row"), so the
  /// slot can never hop between two names for the same spot. A real
  /// distinct place is at least a row (44pt) away.
  private func insertionPoints() -> [Gap] {
    var points: [Gap] = []
    var listPoints: [Gap] = []
    for zone in zones.values {
      let frame = zone.frame
      switch zone.kind {
      case .taskRow:
        points.append(Gap(y: frame.minY, id: zone.id, kind: zone.kind,
                          before: true, frame: frame, rank: 0))
        points.append(Gap(y: frame.maxY, id: zone.id, kind: zone.kind,
                          before: false, frame: frame, rank: 2))
      case .taskSection:
        points.append(Gap(y: frame.maxY, id: zone.id, kind: zone.kind,
                          before: true, frame: frame, rank: 1))
      case .listInsert(let edge):
        // Tasks index points never merge: the card gap between "end of this
        // area" and "new Area" is 14pt, under the 16pt merge distance, and
        // both are real places. The line's inset tells them apart.
        switch edge {
        case .both:
          listPoints.append(Gap(y: frame.minY, id: zone.id, kind: zone.kind,
                                before: true, frame: frame, rank: 0))
          listPoints.append(Gap(y: frame.maxY, id: zone.id, kind: zone.kind,
                                before: false, frame: frame, rank: 2))
        case .top:
          listPoints.append(Gap(y: frame.minY, id: zone.id, kind: zone.kind,
                                before: true, frame: frame, rank: 0))
        case .bottom:
          listPoints.append(Gap(y: frame.maxY, id: zone.id, kind: zone.kind,
                                before: false, frame: frame, rank: 2))
        case .belowGap(let gap):
          listPoints.append(Gap(y: frame.maxY + gap, id: zone.id, kind: zone.kind,
                                before: false, frame: frame, rank: 2))
        }
      }
    }
    points.sort { $0.y < $1.y }
    var merged: [Gap] = []
    var clusterStart: CGFloat = -.infinity
    for p in points {
      if let last = merged.last, p.y - clusterStart < 16 {
        if p.rank < last.rank { merged[merged.count - 1] = p }
      } else {
        merged.append(p)
        clusterStart = p.y
      }
    }
    return (merged + listPoints).sorted { $0.y < $1.y }
  }
}

private struct MagicPlusDragKey: EnvironmentKey {
  static let defaultValue: MagicPlusDragState? = nil
}

extension EnvironmentValues {
  var magicPlusDrag: MagicPlusDragState? {
    get { self[MagicPlusDragKey.self] }
    set { self[MagicPlusDragKey.self] = newValue }
  }
}

/// Registers a reorderable task row as a live Magic Plus target. The
/// insertion line shows above or below the row as the finger hovers.
struct MagicPlusRowDropModifier: ViewModifier {

  @Environment(\.magicPlusDrag) private var drag
  let id: String
  let context: String?
  let enabled: Bool
  let onDrop: (_ before: Bool) -> Void

  private var hoverBefore: Bool? {
    guard let drag, drag.isDragging, let target = drag.activeTarget, target.id == id else {
      return nil
    }
    return target.before
  }

  func body(content: Content) -> some View {
    if enabled, let drag {
      content
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
          drag.register(id: id, kind: .taskRow(context: context), priority: 2,
                        frame: rect, onDrop: onDrop)
        }
        .onDisappear { drag.unregister(id: id) }
        // The list never moves during the drag: the mark draws OVER the row
        // edge instead of opening a gap (see `MagicPlusInsertionMark`).
        .overlay(alignment: .top) {
          if hoverBefore == true { MagicPlusInsertionMark() }
        }
        .overlay(alignment: .bottom) {
          if hoverBefore == false { MagicPlusInsertionMark() }
        }
        .a11yAnimation(.snappy(duration: 0.15), value: hoverBefore)
    } else {
      content
    }
  }

}

/// The insertion mark: the ONE landing mark of a Magic Plus drag. A row gap,
/// a header and a Tasks index row all show it, so the drop always reads as
/// "a new task goes here" and never as "this row is the target".
///
/// It is a thin tinted glass bar drawn over the row edge, and the list does
/// NOT part around it (decided 2026-11-23). A parting gap moved every row
/// under the finger, and every hit-test model built on top of that motion
/// (live frames, rest frames, display-space gaps) still felt flaky. With a
/// still list, the target is just the nearest edge of what the user sees.
/// The new row animates in on drop.
struct MagicPlusInsertionMark: View {
  var body: some View {
    Color.clear
      .glassCard(cornerRadius: 3, tint: AppearancePreferences.shared.magicPlusSwiftUIColor)
      .frame(height: 6)
      .padding(.horizontal, TaskCardMetrics.margin)
      .allowsHitTesting(false)
  }
}

/// Registers a section header, heading, Upcoming day, or Tasks index row as a
/// Magic Plus target. Hovering it shows the insertion mark under it (the first
/// place in that list); the row itself gets no highlight.
struct MagicPlusSectionDropModifier: ViewModifier {
  @Environment(\.magicPlusDrag) private var drag
  let id: String
  let kind: MagicPlusDropKind
  let priority: Int
  let onDrop: () -> Void

  private var isTargeted: Bool {
    guard let drag, drag.isDragging, let target = drag.activeTarget else { return false }
    return target.id == id
  }

  func body(content: Content) -> some View {
    if let drag {
      content
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
          drag.register(id: id, kind: kind, priority: priority, frame: rect) { _ in
            onDrop()
          }
        }
        .onDisappear { drag.unregister(id: id) }
        .overlay(alignment: .bottom) {
          if isTargeted { MagicPlusInsertionMark() }
        }
        .a11yAnimation(.snappy(duration: 0.15), value: isTargeted)
    } else {
      content
    }
  }
}

extension View {
  func magicPlusRowDrop(
    id: String,
    context: String? = nil,
    enabled: Bool,
    onDrop: @escaping (_ before: Bool) -> Void
  ) -> some View {
    modifier(MagicPlusRowDropModifier(id: id, context: context, enabled: enabled, onDrop: onDrop))
  }

  func magicPlusSectionDrop(
    id: String,
    kind: MagicPlusDropKind,
    priority: Int = 2,
    onDrop: @escaping () -> Void
  ) -> some View {
    modifier(MagicPlusSectionDropModifier(id: id, kind: kind, priority: priority,
                                          onDrop: onDrop))
  }
}

// MARK: - Magic Plus on the Tasks index

/// Registers a Tasks index row (an Area or a Project) as a Magic Plus target.
/// The drop turns the insertion line into an inline draft row. `active` gates
/// the zone: the index stays mounted under every pushed list, and its zones
/// must never catch a drop made on another page.
struct MagicPlusListInsertModifier: ViewModifier {
  /// Holds the last row frame without SwiftUI observation, so scrolling never
  /// invalidates the row.
  private final class FrameBox { var rect: CGRect = .zero }

  @Environment(\.magicPlusDrag) private var drag
  @State private var box = FrameBox()
  let id: String
  let edge: MagicPlusInsertEdge
  /// Leading inset of the line: a Project line starts past the icon column,
  /// an Area line spans the card.
  let lineInset: CGFloat
  let active: Bool
  let onDrop: (_ before: Bool) -> Void

  private var hoverBefore: Bool? {
    guard let drag, drag.isDragging, let target = drag.activeTarget, target.id == id else {
      return nil
    }
    return target.before
  }

  private func register() {
    guard let drag, active, box.rect != .zero else { return }
    drag.register(id: id, kind: .listInsert(edge: edge), priority: 2,
                  frame: box.rect, onDrop: onDrop)
  }

  /// A line between two cards draws in the middle of the card gap; a line
  /// inside a card draws on the row edge.
  private var lineOffset: CGFloat {
    switch edge {
    case .top:                return -MagicPlusListMetrics.cardGap / 2
    case .belowGap(let gap):  return gap / 2
    case .both, .bottom:      return 0
    }
  }

  func body(content: Content) -> some View {
    if let drag {
      content
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
          box.rect = rect
          register()
        }
        .onChange(of: active) { _, on in
          if on { register() } else { drag.unregister(id: id) }
        }
        .onDisappear { drag.unregister(id: id) }
        .overlay(alignment: hoverBefore == true ? .top : .bottom) {
          if hoverBefore != nil {
            MagicPlusInsertionMark()
              .padding(.leading, lineInset)
              .offset(y: lineOffset)
          }
        }
        .a11yAnimation(.snappy(duration: 0.15), value: hoverBefore)
    } else {
      content
    }
  }
}

/// The Tasks index card gap the Area lines sit in. Matches the sidebar's
/// `listSectionSpacing`.
enum MagicPlusListMetrics {
  static let cardGap: CGFloat = 14
}

extension View {
  func magicPlusListInsert(
    id: String,
    edge: MagicPlusInsertEdge,
    lineInset: CGFloat = 0,
    active: Bool,
    onDrop: @escaping (_ before: Bool) -> Void
  ) -> some View {
    modifier(MagicPlusListInsertModifier(id: id, edge: edge, lineInset: lineInset,
                                         active: active, onDrop: onDrop))
  }
}

/// Pass-through wrapper that registers a `magicPlusSectionDrop` only when a
/// non-nil `onDropIDs` closure is supplied.
struct MagicPlusOptionalSectionDrop: ViewModifier {
  let id: String
  let label: String
  let onDropIDs: (([String]) -> Bool)?

  func body(content: Content) -> some View {
    if let onDropIDs {
      content.magicPlusSectionDrop(id: id, kind: .taskSection(label: label)) {
        _ = onDropIDs(TaskDragIDs.newTask.ids)
      }
    } else {
      content
    }
  }
}

// MARK: - Multi-task stacked drag preview

/// Tactile drag preview for `.draggable(TaskDragIDs)`: a compact rounded task
/// card when lifting one row, or a subtle physical stack with an accent count
/// badge when lifting a multi-selection (`docs/MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md` §6.1).
struct TaskDragStackPreview: View {
  let title: String
  let count: Int
  var accent: Color = .accentColor
  var destination: String? = nil
  var destinationTint: Color? = nil

  var body: some View {
    ZStack(alignment: .topTrailing) {
      ZStack {
        if count > 2 {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.cardSurface.opacity(0.75))
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
            )
            .padding(.horizontal, 10)
            .offset(y: 7)
        }
        if count > 1 {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.cardSurface.opacity(0.9))
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
            )
            .padding(.horizontal, 5)
            .offset(y: 3.5)
        }
        HStack(spacing: 8) {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Theme.inkSecondary.opacity(0.55), lineWidth: 1.25)
            .frame(width: 14, height: 14)
          Text(title.isEmpty ? "Task" : title)
            .scaledFont(size: 13, weight: .medium)
            .foregroundStyle(Theme.inkPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
          if let destination {
            let tint = destinationTint ?? accent
            Text(destination)
              .scaledFont(size: 11, weight: .semibold)
              .foregroundStyle(tint)
              .lineLimit(1)
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(tint.opacity(0.14), in: Capsule())
              .layoutPriority(-1)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
      }
      .padding(.top, count > 1 ? 6 : 0)
      .padding(.trailing, count > 1 ? 8 : 0)
      .padding(.bottom, count > 2 ? 8 : (count > 1 ? 4 : 0))

      if count > 1 {
        Text("\(count)")
          .scaledFont(size: 11, weight: .bold)
          .monospacedDigit()
          .foregroundStyle(Color.white)
          .padding(.horizontal, 6)
          .frame(minWidth: 20, minHeight: 20)
          .background(AdaptiveColor.fillForWhiteInk(accent), in: Capsule())
          .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
      }
    }
  }
}

#if os(iOS)
// MARK: - Phase M3: One-handed iPhone spring-loaded Quick-Drop Project Tray

/// Cancellable spring-load timer owned by `TaskSpringLoadMoveDrop` so hovering
/// a dragged task stack over the Move button opens the in-window Project Tray
/// after a short beat without fighting UIKit's active `UIDragSession`.
@MainActor
private final class SpringLoadTimer {
  private var task: Task<Void, Never>?

  func arm(delay: Duration = .milliseconds(350), onFire: @escaping @MainActor () -> Void) {
    cancel()
    task = Task { @MainActor in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      onFire()
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}

/// Drop modifier attached to the iOS touch selection bar's Move button:
///   • Hovering a dragged `TaskDragIDs` for 0.35s springs open the in-window
///     `QuickDropProjectTray` so the user can drop directly onto any project.
///   • Releasing directly onto Move before 0.35s calls `onDirectDrop(ids)` to
///     open `MovePickerSheet` for those exact tasks.
struct TaskSpringLoadMoveDrop: ViewModifier {
  let enabled: Bool
  let onSpringLoad: () -> Void
  let onDirectDrop: (_ ids: [String]) -> Void

  @State private var isTargeted = false
  @State private var timer = SpringLoadTimer()

  func body(content: Content) -> some View {
    if enabled {
      content
        .background(
          Circle()
            .fill(isTargeted ? Theme.listSelectionFill : Color.clear)
            .a11yAnimation(.easeOut(duration: 0.12), value: isTargeted)
        )
        .scaleEffect(isTargeted ? 1.12 : 1)
        .a11yAnimation(.snappy(duration: 0.16), value: isTargeted)
        .onDrop(
          of: [.septenaTaskDragIDs],
          delegate: TaskSpringLoadMoveDropDelegate(
            isTargeted: $isTargeted,
            timer: timer,
            onSpringLoad: onSpringLoad,
            onDirectDrop: onDirectDrop
          )
        )
    } else {
      content
    }
  }
}

private struct TaskSpringLoadMoveDropDelegate: DropDelegate {
  @Binding var isTargeted: Bool
  let timer: SpringLoadTimer
  let onSpringLoad: () -> Void
  let onDirectDrop: (_ ids: [String]) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.septenaTaskDragIDs])
  }

  func dropEntered(info: DropInfo) {
    isTargeted = true
    timer.arm {
      Haptics.threshold()
      onSpringLoad()
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    isTargeted = true
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    isTargeted = false
    timer.cancel()
  }

  func performDrop(info: DropInfo) -> Bool {
    isTargeted = false
    timer.cancel()
    guard let provider = info.itemProviders(for: [.septenaTaskDragIDs]).first else { return false }
    provider.loadDataRepresentation(forTypeIdentifier: UTType.septenaTaskDragIDs.identifier) { data, _ in
      guard let data,
            let payload = try? JSONDecoder().decode(TaskDragIDs.self, from: data),
            !payload.ids.isEmpty,
            !TaskDragIDs.isNewTaskPayload(payload.ids)
      else { return }
      DispatchQueue.main.async { onDirectDrop(payload.ids) }
    }
    return true
  }
}

/// In-window floating Project / Area drop tray for compact iPhone
/// (`docs/MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md` §6.3, Phase M3).
/// Rendered as an in-window `ZStack` overlay (never a `.sheet`) so UIKit's live
/// `UIDragSession` stays uninterrupted while the user glides onto a project.
struct QuickDropProjectTray: View {
  let areas: [Area]
  let projects: [Project]
  let projectProgress: [String: Double]
  let onDropInbox: (_ ids: [String]) -> Bool
  let onDropToday: (_ ids: [String]) -> Bool
  let onDropArea: (_ ids: [String], _ areaId: String) -> Bool
  let onDropProject: (_ ids: [String], _ projectId: String) -> Bool
  let onDismiss: () -> Void

  private var activeProjects: [Project] {
    projects.filter { $0.status == .active }
  }

  private var looseProjects: [Project] {
    activeProjects.filter { $0.area == nil }
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black.opacity(0.24)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }

      VStack(spacing: 0) {
        HStack {
          Text("Drop into…")
            .font(.septenaLabel.weight(.semibold))
            .foregroundStyle(Theme.inkPrimary)
          Spacer(minLength: 0)
          Button("Cancel") { onDismiss() }
            .font(.septenaMeta.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)

        Divider()

        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
              quickTargetChip(title: TaskFilter.triage.title, symbol: "tray", tint: Color.accentColor) { ids in
                let ok = onDropInbox(ids)
                onDismiss()
                return ok
              }
              quickTargetChip(title: TaskFilter.today.title, symbol: "sun.max.fill", tint: Theme.todayAccent) { ids in
                let ok = onDropToday(ids)
                onDismiss()
                return ok
              }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ForEach(looseProjects) { project in
              projectDropRow(project, indented: false)
            }

            ForEach(areas) { area in
              let areaProjects = activeProjects.filter { $0.area == area.id }
              areaDropRow(area)
              ForEach(areaProjects) { project in
                projectDropRow(project, indented: true)
              }
            }
          }
          .padding(.bottom, 14)
        }
        .frame(maxHeight: 340)
      }
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .strokeBorder(Theme.border, lineWidth: 0.5)
      )
      .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
      .padding(.horizontal, 12)
      .padding(.bottom, 12)
    }
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  private func quickTargetChip(
    title: String,
    symbol: String,
    tint: Color,
    perform: @escaping (_ ids: [String]) -> Bool
  ) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .scaledFont(size: 13, weight: .semibold)
        .foregroundStyle(tint)
      Text(title)
        .font(.septenaTaskTitle.weight(.medium))
        .foregroundStyle(Theme.inkPrimary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity)
    .background(Theme.cardSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .modifier(TaskMoveDrop(perform: perform))
  }

  private func areaDropRow(_ area: Area) -> some View {
    HStack(spacing: 8) {
      if let emoji = area.emoji, !emoji.isEmpty {
        Text(emoji)
          .scaledFont(size: 14)
          .frame(width: 20, alignment: .center)
      } else {
        Image(systemName: "square.stack.3d.up")
          .scaledFont(size: 13, weight: .medium)
          .foregroundStyle(Theme.inkSecondary)
          .frame(width: 20, alignment: .center)
      }
      Text(area.title)
        .font(.septenaTaskTitle.weight(.semibold))
        .foregroundStyle(Theme.inkPrimary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .contentShape(Rectangle())
    .modifier(TaskMoveDrop(perform: { ids in
      let ok = onDropArea(ids, area.id)
      onDismiss()
      return ok
    }))
    .padding(.horizontal, 6)
  }

  private func projectDropRow(_ project: Project, indented: Bool) -> some View {
    HStack(spacing: 8) {
      ProjectProgressIcon(progress: projectProgress[project.id] ?? 0,
                          tint: Theme.inkSecondary, diameter: 14)
        .frame(width: 20, alignment: .center)
      Text(project.title)
        .font(.septenaTaskTitle)
        .foregroundStyle(Theme.inkPrimary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.leading, indented ? 30 : 14)
    .padding(.trailing, 14)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .modifier(TaskMoveDrop(perform: { ids in
      let ok = onDropProject(ids, project.id)
      onDismiss()
      return ok
    }))
    .padding(.horizontal, 6)
  }
}
#endif
