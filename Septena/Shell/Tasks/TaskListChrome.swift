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
      .a11yAnimation(.easeOut(duration: 0.18), value: isDimmed)
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
/// Drives the live visual morph (orb → ghost task row / contextual pill).
enum MagicPlusDropKind: Equatable {
  /// Between two rows in a reorderable list (parts a full ghost-row gap).
  case taskRow(context: String?)
  /// Onto a section/heading/group/day header, a non-reorderable card, or a
  /// list row on the Tasks index. Every target makes a new task: the orb never
  /// makes an Area or a Project.
  case taskSection(label: String)
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
  /// Zone frames frozen at drag start. Targets resolve against this REST
  /// layout, never the live one: the open slot pushes every zone under it down
  /// by a slot height, and resolving against those moved frames fed the slot
  /// back into the hit test (the probe fell into the slot it had just opened,
  /// the nearest-zone fallback picked a neighbour, the slot moved, repeat).
  /// The list cannot scroll during the drag (the finger is on the orb), so the
  /// rest layout stays true for the whole gesture.
  @ObservationIgnored private var restFrames: [String: CGRect] = [:]

  func register(
    id: String,
    kind: MagicPlusDropKind,
    priority: Int,
    frame: CGRect,
    onDrop: @escaping (_ before: Bool) -> Void
  ) {
    guard frame.width > 0, frame.height > 0 else { return }
    zones[id] = Zone(id: id, kind: kind, priority: priority, frame: frame, onDrop: onDrop)
    // A zone that first appears mid-drag joins the rest layout only while no
    // slot is open; with a slot open its frame is already shifted.
    if isDragging, restFrames[id] == nil, activeTarget == nil {
      restFrames[id] = frame
    }
  }

  func unregister(id: String) {
    zones.removeValue(forKey: id)
    restFrames.removeValue(forKey: id)
    if activeTarget?.id == id {
      activeTarget = nil
    }
  }

  func beginDrag(at location: CGPoint) {
    isDragging = true
    isOverCancelSocket = false
    fingerLocation = location
    activeTarget = nil
    restFrames = zones.mapValues(\.frame)
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
    restFrames.removeAll()
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
    restFrames.removeAll()
  }

  /// Where a target's slot opens in the rest layout: above a row for
  /// `before`, under it otherwise (a section slot always opens under it).
  private static func slotY(_ target: ActiveTarget) -> CGFloat {
    if case .taskRow = target.kind, target.before { return target.frame.minY }
    return target.frame.maxY
  }

  /// Shortest distance from a point to a rect (0 inside it).
  private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return hypot(dx, dy)
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

    // Aim slightly above the fingertip where the floating ghost card sits.
    let probe = CGPoint(x: location.x, y: location.y - 24)
    // Resolve against the rest layout (see `restFrames`).
    let layout: [Zone] = zones.values.map { zone in
      var z = zone
      if let rest = restFrames[zone.id] { z.frame = rest }
      return z
    }
    let candidates = layout.filter { zone in
      let padY: CGFloat = zone.priority >= 2 ? 4 : 0
      return zone.frame.insetBy(dx: -8, dy: -padY).contains(probe)
    }

    // No holes: when the probe sits in a gap (row spacing, between sections,
    // empty space below the last row, the nav bar), fall back to the nearest
    // registered zone so every drop position has a destination. A row picked
    // this way resolves before/after by the midline, so space under the last
    // row lands after it and space above the first lands before it.
    let best = candidates.max { a, b in
      if a.priority != b.priority { return a.priority < b.priority }
      return abs(a.frame.midY - probe.y) > abs(b.frame.midY - probe.y)
    } ?? layout.min { a, b in
      let da = Self.distance(from: probe, to: a.frame)
      let db = Self.distance(from: probe, to: b.frame)
      if da != db { return da < db }
      return a.priority > b.priority
    }

    // Stickiness in the dead space between two lists (the end of one area and
    // the header of the next): when the probe sits in no zone, keep the current
    // target until another zone is clearly nearer. Picking the strictly
    // nearest zone flipped between the two lists at every pixel around the
    // midpoint.
    if candidates.isEmpty, let current = activeTarget,
       let currentZone = layout.first(where: { $0.id == current.id }),
       let best, best.id != current.id,
       Self.distance(from: probe, to: currentZone.frame)
         < Self.distance(from: probe, to: best.frame) + 20 {
      return
    }

    guard let best else {
      if activeTarget != nil {
        a11yAnimate(.snappy(duration: 0.18)) { activeTarget = nil }
      }
      return
    }

    let before: Bool
    if case .taskRow = best.kind {
      // Hysteresis around midline so parting the row gap never oscillates.
      if let current = activeTarget, current.id == best.id {
        before = current.before
          ? probe.y < best.frame.maxY - 8
          : probe.y < best.frame.minY + 8
      } else {
        before = probe.y < best.frame.midY
      }
    } else {
      before = true
    }

    let next = ActiveTarget(id: best.id, kind: best.kind, before: before, frame: best.frame)
    // Two targets whose slots open at (nearly) the same place are ONE slot:
    // "after row A" / "before row B" on touching rows, and "under a list's
    // header" / "before its first row" at the top of a list (header-to-row
    // spacing apart). Keep the current target then: switching would move the
    // slot's padding to the other view (a visible hop) and fire a second
    // tick. 16pt sits under any real slot-to-slot distance (a row is 44pt+).
    if let current = activeTarget, current.id != next.id,
       abs(Self.slotY(current) - Self.slotY(next)) < 16 {
      return
    }
    if activeTarget?.id != next.id || activeTarget?.before != next.before {
      Haptics.selection()
      a11yAnimate(.snappy(duration: 0.18)) {
        activeTarget = next
      }
    }
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

/// Registers a reorderable task row as a live Magic Plus gap-parting target.
/// Opens a 48pt ghost-row slot above or below the row as the finger hovers.
struct MagicPlusRowDropModifier: ViewModifier {
  static let gapHeight: CGFloat = 48

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
        // Capture un-parted global frame before gap padding shifts it.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
          drag.register(id: id, kind: .taskRow(context: context), priority: 2,
                        frame: rect, onDrop: onDrop)
        }
        .onDisappear { drag.unregister(id: id) }
        .padding(.top, hoverBefore == true ? Self.gapHeight : 0)
        .padding(.bottom, hoverBefore == false ? Self.gapHeight : 0)
        .overlay(alignment: .top) {
          if hoverBefore == true { MagicPlusGhostSlot() }
        }
        .overlay(alignment: .bottom) {
          if hoverBefore == false { MagicPlusGhostSlot() }
        }
        .a11yAnimation(.snappy(duration: 0.2), value: hoverBefore)
    } else {
      content
    }
  }

}

/// The glass new-task slot: the ONE landing mark of a Magic Plus drag. A row
/// gap, a header and a Tasks index row all show it, so the drop always reads
/// as "a new task goes here" and never as "this row is the target".
struct MagicPlusGhostSlot: View {
  var body: some View {
    // A tinted glass pane, the same material as the orb and the toolbar
    // circles (decided 2026-11-23: the dashed outline read as a wireframe).
    Color.clear
      .glassCard(cornerRadius: 12, tint: AppearancePreferences.shared.magicPlusSwiftUIColor)
      .padding(.horizontal, TaskCardMetrics.margin)
      .padding(.vertical, 4)
      .frame(height: MagicPlusRowDropModifier.gapHeight)
  }
}

/// Registers a section header, heading, Upcoming day, or Tasks index row as a
/// Magic Plus target. Hovering it opens the glass new-task slot under it (the
/// first place in that list); the row itself gets no highlight.
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
        // Capture the un-parted frame before the slot padding grows it.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
          drag.register(id: id, kind: kind, priority: priority, frame: rect) { _ in
            onDrop()
          }
        }
        .onDisappear { drag.unregister(id: id) }
        .padding(.bottom, isTargeted ? MagicPlusRowDropModifier.gapHeight : 0)
        .overlay(alignment: .bottom) {
          if isTargeted { MagicPlusGhostSlot() }
        }
        .a11yAnimation(.snappy(duration: 0.2), value: isTargeted)
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

#if os(iOS)
/// Full-screen non-hit-testing overlay that renders the finger-following Magic
/// Plus drag. It draws the same `TaskDragStackPreview` card that a task row
/// lifts into, so every task drag is one object. The card's destination chip
/// names the target under the finger, or Cancel over the cancel socket.
struct MagicPlusFloatingOverlay: View {
  let drag: MagicPlusDragState

  /// Upper bound of the card width, for the clamp against the screen edges.
  private static let cardWidth: CGFloat = 260

  var body: some View {
    GeometryReader { geo in
      if drag.isDragging {
        let localOrigin = geo.frame(in: .global).origin
        let rawX = drag.fingerLocation.x - localOrigin.x
        let rawY = drag.fingerLocation.y - localOrigin.y - 36
        let halfW = Self.cardWidth / 2
        let clampedX = min(max(rawX, halfW + 16), max(halfW + 16, geo.size.width - halfW - 16))
        let clampedY = max(rawY, 64)

        card
          .position(x: clampedX, y: clampedY)
          .a11yAnimation(.snappy(duration: 0.2), value: drag.activeTarget?.kind)
          .a11yAnimation(.snappy(duration: 0.2), value: drag.isOverCancelSocket)
          .transition(.scale(scale: 0.8).combined(with: .opacity))
      }
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }

  private var card: some View {
    let accent = AppearancePreferences.shared.magicPlusSwiftUIColor
    return TaskDragStackPreview(
      title: RegistryActions.title("app.newTask"),
      count: 1,
      accent: accent,
      destination: destination,
      destinationTint: drag.isOverCancelSocket ? .red : accent
    )
  }

  private var destination: String? {
    if drag.isOverCancelSocket { return "Cancel" }
    switch drag.activeTarget?.kind {
    case .taskRow(let context):   return (context?.isEmpty ?? true) ? nil : context
    case .taskSection(let label): return label
    case nil:                     return nil
    }
  }
}
#endif

// MARK: - Multi-task stacked drag preview

/// Tactile drag preview for `.draggable(TaskDragIDs)`: a compact rounded task
/// card when lifting one row, or a subtle physical stack with an accent count
/// badge when lifting a multi-selection (`docs/MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md` §6.1).
/// The Magic Plus drag (`MagicPlusFloatingOverlay`) draws this same card, with
/// `destination` naming the drop target under the finger.
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
