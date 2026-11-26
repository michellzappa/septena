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
/// Inside a task list there is ONE landing mark (mz, 2026-11-24):
/// `TaskInsertionMark`, for a task drag and for a Magic Plus drag, on rows and
/// on headers (`showsMark`). A container whose tasks are not on screen (a
/// sidebar row, a project card, a Move panel row) has no place to mark, so it
/// wears the canonical `Theme.listSelectionFill` instead.
struct TaskMoveDrop: ViewModifier {
  let perform: ((_ ids: [String]) -> Bool)?
  /// The target is a row or a header in a task list: show the insertion mark
  /// under it.
  var showsMark = false
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    if let perform {
      content
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isTargeted && !showsMark ? Theme.listSelectionFill : Color.clear)
            .a11yAnimation(.easeOut(duration: 0.12), value: isTargeted)
        )
        .taskInsertionMark(before: isTargeted && showsMark ? false : nil)
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
  private let appearance = AppearancePreferences.shared

  /// Every row — including an open inline composer (create or edit) — inherits
  /// its card position's corner rounding (top / middle / bottom / solo) so it
  /// stays flush with adjacent closed rows instead of rounding all four corners
  /// mid-group (#204).
  private var effectiveShape: UnevenRoundedRectangle {
    position.cardShape
  }

  private var useLiquidGlass: Bool {
    return appearance.hasActiveTexture && !reduceTransparency && !isEditing
  }

  func body(content: Content) -> some View {
    let shape = effectiveShape
    content
      // Top, not center: while the row's height animates, its content stays on
      // the top edge instead of drifting with the middle (`geometryGroup`).
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
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
      // Title, checkbox and card surface move as ONE piece when the list
      // shifts. Without it every leaf animates its own position, and the
      // titles drift away from their rows.
      .geometryGroup()
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
    frame(maxWidth: .infinity, alignment: .topLeading)
      .geometryGroup()
  }

  /// Selectable task-row chrome and interaction routing.
  func asTaskRow(id: String, isSelected: Bool, isComplete: Bool? = nil) -> some View {
    selectableScrollRow(id: id, isSelected: isSelected, isComplete: isComplete)
  }

  /// Non-interactive decorative content within a task list.
  func plainListChrome() -> some View {
    frame(maxWidth: .infinity, alignment: .topLeading)
      .geometryGroup()
  }
}

// MARK: - Row exit

/// How a row (or a group header) leaves a task list. The rows below slide up on
/// the same transaction, and the leaving row's bottom edge rises on that same
/// curve, so the two edges stay together: no gap opens in the card, and the old
/// title never shows through the row that slides over it.
///
/// A row that is alone in its card, and a header, also fade: nothing slides
/// over them from the same card. Arrivals fade in.
struct TaskListRowExit: Transition {
  var fades = false

  func body(content: Content, phase: TransitionPhase) -> some View {
    content
      .clipShape(TaskListRowExitClip(remaining: phase == .didDisappear ? 0 : 1))
      .opacity(phase == .willAppear || (fades && phase == .didDisappear) ? 0 : 1)
  }
}

/// Clips the bottom edge only. The other edges sit far outside the row, so the
/// insertion mark and the open editor's shadow are never cut.
private struct TaskListRowExitClip: Shape {
  var remaining: CGFloat
  private static let outset: CGFloat = 200

  var animatableData: CGFloat {
    get { remaining }
    set { remaining = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let bottom = remaining >= 1 ? rect.height + Self.outset : rect.height * max(0, remaining)
    return Path(CGRect(x: rect.minX - Self.outset,
                       y: rect.minY - Self.outset,
                       width: rect.width + Self.outset * 2,
                       height: bottom + Self.outset))
  }
}

// MARK: - Magic Plus interactive drag coordinator (iPhone compact)

/// What kind of drop target the dragged Magic Plus orb is currently hovering.
/// Every kind shows the same insertion line (`TaskInsertionMark`).
enum MagicPlusDropKind: Equatable {
  /// Between two rows in a reorderable list.
  case taskRow(context: String?)
  /// Onto a section/heading/group/day header or a non-reorderable card. It
  /// makes a new task.
  case taskSection(label: String)
  /// A place on the Tasks index (list root), where the orb makes only
  /// Projects and Areas. `edge` says which insertion points the zone offers;
  /// `isArea` and `label` tell the user live what releasing here will create.
  case listInsert(edge: MagicPlusInsertEdge, isArea: Bool, label: String)
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
    if let open, open != bestIndex {
      // Homepage list-insert slots sit ~24pt apart across the 14pt card gap
      // (last project in Area A vs. New Area before Area B), so use a tighter
      // 4pt hysteresis there while keeping 10pt for task lists.
      let hysteresis: CGFloat
      if case .listInsert = gaps[open].kind {
        hysteresis = 4
      } else if case .listInsert = gaps[bestIndex].kind {
        hysteresis = 4
      } else {
        hysteresis = 10
      }
      if abs(gaps[open].y - probeY) - bestDistance < hysteresis {
        return
      }
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
      case .listInsert(let edge, _, _):
        // Tasks index points never merge: the card gap between "end of this
        // area" and "new Area before next card" is 14pt, under the 16pt merge
        // distance, and both are real places. Pull `.bottom` 6pt inside the
        // row and `.top` 4pt inside the next card so the two hit targets sit
        // ~24pt apart and feel distinct under a fingertip.
        switch edge {
        case .both:
          listPoints.append(Gap(y: frame.minY, id: zone.id, kind: zone.kind,
                                before: true, frame: frame, rank: 0))
          listPoints.append(Gap(y: frame.maxY, id: zone.id, kind: zone.kind,
                                before: false, frame: frame, rank: 2))
        case .top:
          listPoints.append(Gap(y: frame.minY + 4, id: zone.id, kind: zone.kind,
                                before: true, frame: frame, rank: 0))
        case .bottom:
          listPoints.append(Gap(y: frame.maxY - 6, id: zone.id, kind: zone.kind,
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
        .taskInsertionMark(before: hoverBefore)
    } else {
      content
    }
  }

}

/// The insertion mark: the ONE landing mark in a task list, for a task drag
/// (`TaskReorderDrop`, `TaskMoveDrop`) and for a Magic Plus drag. A row gap, a
/// header and a Tasks index row all show it, so the drop always reads as "the
/// task goes here" and never as "this row is the target". The AppKit list
/// draws the same bar (`KitCardRowView.dropLine`).
///
/// It is a thin tinted glass bar drawn over the row edge, and the list does
/// NOT part around it (decided 2026-11-23). A parting gap moved every row
/// under the finger, and every hit-test model built on top of that motion
/// (live frames, rest frames, display-space gaps) still felt flaky. With a
/// still list, the target is just the nearest edge of what the user sees.
/// The row animates in on drop.
struct TaskInsertionMark: View {
  static let height: CGFloat = 6

  var body: some View {
    bar
      .frame(height: Self.height)
      .padding(.horizontal, TaskCardMetrics.margin)
      .allowsHitTesting(false)
  }

  @ViewBuilder private var bar: some View {
    let tint = AppearancePreferences.shared.magicPlusSwiftUIColor
    #if os(iOS)
    Color.clear.glassCard(cornerRadius: Self.height / 2, tint: tint)
    #else
    // Cards are flat on macOS (`glassCard` has no glass there).
    RoundedRectangle(cornerRadius: Self.height / 2, style: .continuous).fill(tint)
    #endif
  }
}

extension View {
  /// Draws the insertion mark over this row's edge: above it (`true`), below
  /// it (`false`) or not at all (`nil`). The mark above a row covers the last
  /// points of the row before it, so "above B" and "below A" are the same
  /// place on screen and the mark never hops between the two.
  func taskInsertionMark(before: Bool?) -> some View {
    overlay(alignment: .top) {
      if before == true { TaskInsertionMark().offset(y: -TaskInsertionMark.height) }
    }
    .overlay(alignment: .bottom) {
      if before == false { TaskInsertionMark() }
    }
    .a11yAnimation(.snappy(duration: 0.15), value: before)
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
        .taskInsertionMark(before: isTargeted ? false : nil)
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
  /// Whether releasing here creates an Area (`true`) or a Project (`false`).
  let isArea: Bool
  /// Self-explanatory live label shown on the insertion mark (e.g. "New Area",
  /// "New Project in Home").
  let label: String
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
    drag.register(id: id, kind: .listInsert(edge: edge, isArea: isArea, label: label), priority: 2,
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
            ZStack(alignment: .leading) {
              TaskInsertionMark()
                .padding(.leading, lineInset)
              if !label.isEmpty {
                MagicPlusInsertBadge(isArea: isArea, label: label)
                  .padding(.leading, max(TaskCardMetrics.margin, lineInset))
              }
            }
            .offset(y: lineOffset)
            .allowsHitTesting(false)
          }
        }
        .zIndex(hoverBefore != nil ? 10 : 0)
        .a11yAnimation(.snappy(duration: 0.15), value: hoverBefore)
    } else {
      content
    }
  }
}

/// Compact pill drawn on a Tasks index insertion bar while dragging Magic Plus
/// so the user can tell at a glance whether releasing here creates an Area or a
/// Project (and inside which Area).
private struct MagicPlusInsertBadge: View {
  let isArea: Bool
  let label: String

  var body: some View {
    let appearance = AppearancePreferences.shared
    let fill = appearance.magicPlusSwiftUIColor
    let ink = appearance.magicPlusInkSwiftUIColor
    HStack(spacing: 5) {
      if isArea {
        Circle()
          .fill(ink)
          .frame(width: 5.5, height: 5.5)
      } else {
        Circle()
          .stroke(ink, lineWidth: 1.5)
          .frame(width: 8, height: 8)
      }
      Text(label)
        .scaledFont(size: 11, weight: .semibold)
        .foregroundStyle(ink)
        .lineLimit(1)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(fill))
    .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
    .allowsHitTesting(false)
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
    isArea: Bool = false,
    label: String = "",
    lineInset: CGFloat = 0,
    active: Bool,
    onDrop: @escaping (_ before: Bool) -> Void
  ) -> some View {
    modifier(MagicPlusListInsertModifier(id: id, edge: edge, isArea: isArea, label: label,
                                         lineInset: lineInset, active: active, onDrop: onDrop))
  }
}

#if os(iOS)
/// Floating circular Magic Plus orb shared by the iPhone root stack and the
/// iPad split sidebar:
/// - Solid accent circle + subtle 3×2 grip dots beneath `+` communicates a
///   grabbable object rather than a flat tap-only button.
/// - Tap makes a task on a task list, opens `New Task` / `New Section` on a
///   Project, `New Task` / `New Project` on an Area, or `New Project` /
///   `New Area` / `Join a Shared Project…` on the homepage/sidebar.
/// - Instant drag (no hold delay) hides the orb, reveals a cancel socket (`×`),
///   and shows the insertion line (with live `New Area` / `New Project` badge
///   on the homepage/sidebar).
struct MagicPlusOrb: View {
  let drag: MagicPlusDragState
  @State private var showingMenu = false
  /// New Task was picked in the menu. The task starts when the popover is gone:
  /// a popover that closes takes the keyboard away from the new title field.
  @State private var newTaskAfterMenu = false
  /// Finger-down state: the orb sinks while touched, so the press reads as
  /// received before the tap even ends.
  @GestureState private var isPressed = false
  /// Bumped on each tap: drives the release pop (grow, then settle back).
  @State private var popTick = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let isViewingProject: Bool
  var isViewingArea: Bool = false
  let isViewingHome: Bool
  let onNewTask: () -> Void
  let onNewSection: () -> Void
  let onNewProject: () -> Void
  let onNewArea: () -> Void
  var onJoinShared: (() -> Void)? = nil

  private var opensQuickMenuOnTap: Bool {
    isViewingHome || isViewingProject || isViewingArea
  }

  var body: some View {
    let appearance = AppearancePreferences.shared
    let accent = appearance.magicPlusSwiftUIColor
    let ink = appearance.magicPlusInkSwiftUIColor

    // Keep both the resting "+" orb and the cancel socket inside one stable
    // ZStack (toggling opacity/scale, never swapping container identity) so
    // SwiftUI's active DragGesture never drops mid-drag.
    ZStack {
      ZStack {
        Circle()
          .fill(accent.gradient)
          .overlay(
            Circle()
              .strokeBorder(ink.opacity(0.22), lineWidth: 0.75)
          )
          .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        VStack(spacing: 4) {
          Image(systemName: "plus")
            .scaledFont(size: 21, weight: .bold)
            .foregroundStyle(ink)
          gripDots(ink: ink)
        }
        .offset(y: 2)
      }
      .scaleEffect(isPressed && !drag.isDragging ? 0.88 : 1)
      .a11yAnimation(.spring(response: 0.22, dampingFraction: 0.6), value: isPressed)
      .keyframeAnimator(initialValue: CGFloat(1), trigger: popTick) { content, scale in
        content.scaleEffect(scale)
      } keyframes: { _ in
        SpringKeyframe(1.14, duration: 0.12, spring: .snappy)
        SpringKeyframe(1, duration: 0.32, spring: .bouncy)
      }
      .opacity(drag.isDragging ? 0 : 1)
      .scaleEffect(drag.isDragging ? 0.75 : 1)

      ZStack {
        Color.clear
        Image(systemName: "xmark")
          .scaledFont(size: 18, weight: .semibold)
          .foregroundStyle(drag.isOverCancelSocket ? Color.red : Color.secondary)
      }
      .glassCircle(tint: drag.isOverCancelSocket ? .red : nil)
      .opacity(drag.isDragging ? 1 : 0)
      .scaleEffect(drag.isDragging ? (drag.isOverCancelSocket ? 1.08 : 0.94) : 0.75)
    }
    .frame(width: 58, height: 58)
    .contentShape(Circle())
    .a11yAnimation(.snappy(duration: 0.2), value: drag.isDragging)
    .a11yAnimation(.snappy(duration: 0.18), value: drag.isOverCancelSocket)
    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
      drag.homeCenter = CGPoint(x: rect.midX, y: rect.midY)
    }
    .onTapGesture {
      guard !drag.isDragging else { return }
      Haptics.press()
      if !reduceMotion { popTick += 1 }
      if opensQuickMenuOnTap { showingMenu = true } else { onNewTask() }
    }
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .updating($isPressed) { _, pressed, _ in pressed = true }
    )
    .simultaneousGesture(
      DragGesture(minimumDistance: 8, coordinateSpace: .global)
        .onChanged { value in
          if !drag.isDragging {
            showingMenu = false
            drag.beginDrag(at: value.location)
          } else {
            drag.updateDrag(at: value.location)
          }
        }
        .onEnded { value in
          drag.endDrag(at: value.location)
        }
    )
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel("New")
    .accessibilityHint(isViewingHome
      ? Text("Tap for a new project or area, or drag onto a list position.")
      : isViewingProject
        ? Text("Tap for a new task or section, or drag onto a list position.")
        : isViewingArea
          ? Text("Tap for a new task or project, or drag onto a list position.")
          : Text("Tap for a new task, or drag onto a list position."))
    .popover(isPresented: $showingMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
      quickMenu
        .presentationCompactAdaptation(.popover)
        .onDisappear {
          guard newTaskAfterMenu else { return }
          newTaskAfterMenu = false
          onNewTask()
        }
    }
  }

  /// Subtle 3×2 tactile grip dots beneath `+` signaling the orb can be dragged.
  private func gripDots(ink: Color) -> some View {
    VStack(spacing: 2.5) {
      ForEach(0..<2, id: \.self) { _ in
        HStack(spacing: 3) {
          ForEach(0..<3, id: \.self) { _ in
            Circle()
              .fill(ink.opacity(0.55))
              .frame(width: 2.5, height: 2.5)
          }
        }
      }
    }
    .accessibilityHidden(true)
  }

  private var quickMenu: some View {
    VStack(alignment: .leading, spacing: 2) {
      if isViewingHome {
        menuRow(title: RegistryActions.title(.sidebarNewProject), icon: "number") {
          showingMenu = false
          onNewProject()
        }
        menuRow(title: RegistryActions.title(.sidebarNewArea), icon: "square.stack.3d.up") {
          showingMenu = false
          onNewArea()
        }
        if let onJoinShared {
          menuRow(title: RegistryActions.title(.sidebarJoinShared),
                  icon: RegistryIcons.sfSymbol(for: "action.share_project")) {
            showingMenu = false
            onJoinShared()
          }
        }
      } else {
        menuRow(title: RegistryActions.title(.appNewTask), icon: "checkmark.circle") {
          newTaskAfterMenu = true
          showingMenu = false
        }
        if isViewingProject {
          menuRow(title: RegistryActions.title(.sectionNew), icon: "rectangle.split.1x2") {
            showingMenu = false
            onNewSection()
          }
        } else if isViewingArea {
          menuRow(title: RegistryActions.title(.areaNewProject), icon: "number") {
            showingMenu = false
            onNewProject()
          }
        }
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 6)
    .frame(minWidth: 196)
  }

  private func menuRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .scaledFont(size: 16, weight: .medium)
          .foregroundStyle(AppearancePreferences.shared.accentSwiftUIColor)
          .frame(width: 22)
        Text(title)
          .font(.septenaSidebarRow)
          .foregroundStyle(.primary)
        Spacer(minLength: 8)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
#endif

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
      AreaIcon(tint: Theme.inkSecondary, diameter: 16, emoji: area.emoji)
        .frame(width: 20, alignment: .center)
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
