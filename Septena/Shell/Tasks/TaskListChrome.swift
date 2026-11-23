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
  /// Onto a section/heading/group/day header or non-reorderable card.
  case taskSection(label: String)
  /// Onto an Area or Project on the Tasks index.
  case newProject(label: String)
  /// Onto the Tasks index background / between Area cards.
  case newArea
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
    let candidates = zones.values.filter { zone in
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
    } ?? zones.values.min { a, b in
      let da = Self.distance(from: probe, to: a.frame)
      let db = Self.distance(from: probe, to: b.frame)
      if da != db { return da < db }
      return a.priority > b.priority
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
          if hoverBefore == true { ghostSlotPlaceholder }
        }
        .overlay(alignment: .bottom) {
          if hoverBefore == false { ghostSlotPlaceholder }
        }
        .a11yAnimation(.snappy(duration: 0.2), value: hoverBefore)
    } else {
      content
    }
  }

  /// Subtle dashed-outline landing slot revealed in the parted row gap.
  private var ghostSlotPlaceholder: some View {
    let accent = AppearancePreferences.shared.magicPlusSwiftUIColor
    return RoundedRectangle(cornerRadius: 10, style: .continuous)
      .strokeBorder(accent.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(accent.opacity(0.06))
      )
      .padding(.horizontal, TaskCardMetrics.margin)
      .padding(.vertical, 4)
      .frame(height: Self.gapHeight)
  }
}

/// Registers a section header, heading, Upcoming day, or Tasks index row as a
/// Magic Plus target with canonical `Theme.listSelectionFill` highlight.
struct MagicPlusSectionDropModifier: ViewModifier {
  @Environment(\.magicPlusDrag) private var drag
  let id: String
  let kind: MagicPlusDropKind
  let priority: Int
  let highlights: Bool
  let onDrop: () -> Void

  private var isTargeted: Bool {
    guard let drag, drag.isDragging, let target = drag.activeTarget else { return false }
    return target.id == id
  }

  func body(content: Content) -> some View {
    if let drag {
      content
        .background {
          if highlights {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(isTargeted ? Theme.listSelectionFill : Color.clear)
              .a11yAnimation(.easeOut(duration: 0.14), value: isTargeted)
          }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
          drag.register(id: id, kind: kind, priority: priority, frame: rect) { _ in
            onDrop()
          }
        }
        .onDisappear { drag.unregister(id: id) }
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
    highlights: Bool = true,
    onDrop: @escaping () -> Void
  ) -> some View {
    modifier(MagicPlusSectionDropModifier(id: id, kind: kind, priority: priority,
                                          highlights: highlights, onDrop: onDrop))
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
    case .newProject(let label):  return label
    case .newArea:                return RegistryActions.title("sidebar.newArea")
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

// MARK: - iOS task-row horizontal swipes (left = Select, right = Quick Action)

/// Descriptor for the leading (swipe-right) quick action on a task row
/// (`docs/IOS_SWIPE_ACTIONS_SPEC.md` #132).
struct TaskRowLeadingSwipeAction {
  let title: String
  let symbol: String
  let tint: Color
  let perform: () -> Void
}

extension View {
  /// Unified scroll-safe horizontal swipe on iOS/iPadOS `SelectableScrollList` rows:
  ///   • Swipe left  → toggle task selection (`docs/MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md` §3).
  ///   • Swipe right → run `leadingAction` (`docs/IOS_SWIPE_ACTIONS_SPEC.md` #132).
  /// Pass-through on macOS or when neither direction is enabled.
  @ViewBuilder
  func taskRowSwipe(
    allowSelect: Bool,
    isSelected: Bool,
    onToggleSelect: @escaping () -> Void,
    leadingAction: TaskRowLeadingSwipeAction? = nil
  ) -> some View {
    #if os(iOS)
    if allowSelect || leadingAction != nil {
      modifier(TaskRowHorizontalSwipeModifier(allowSelect: allowSelect,
                                              isSelected: isSelected,
                                              onToggleSelect: onToggleSelect,
                                              leadingAction: leadingAction))
    } else {
      self
    }
    #else
    self
    #endif
  }
}

#if os(iOS)
private struct TaskRowHorizontalSwipeModifier: ViewModifier {
  let allowSelect: Bool
  let isSelected: Bool
  let onToggleSelect: () -> Void
  let leadingAction: TaskRowLeadingSwipeAction?

  private enum Direction { case left, right }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dragOffset: CGFloat = 0
  @State private var activeDirection: Direction? = nil
  @State private var armed = false

  private static let leftCommitThreshold: CGFloat = 36
  private static let leftDisarmThreshold: CGFloat = 28
  private static let leftMaxTravel: CGFloat = 56

  private static let rightCommitThreshold: CGFloat = 44
  private static let rightDisarmThreshold: CGFloat = 34
  private static let rightMaxTravel: CGFloat = 66

  private var leftProgress: CGFloat {
    min(1, max(0, -dragOffset / Self.leftCommitThreshold))
  }

  private var rightProgress: CGFloat {
    min(1, max(0, dragOffset / Self.rightCommitThreshold))
  }

  func body(content: Content) -> some View {
    ZStack {
      if dragOffset < -2, allowSelect {
        HStack {
          Spacer(minLength: 0)
          Image(systemName: selectIndicatorSymbol)
            .scaledFont(size: 18, weight: .semibold)
            .foregroundStyle(armed ? Color.accentColor : Theme.inkSecondary)
            .scaleEffect(armed ? 1.12 : 0.85 + 0.15 * leftProgress)
            .opacity(Double(min(1, leftProgress * 1.25)))
            .padding(.trailing, 14)
            .a11yAnimation(.snappy(duration: 0.16), value: armed)
            .accessibilityHidden(true)
        }
      }

      if dragOffset > 2, let leadingAction {
        HStack {
          Image(systemName: leadingAction.symbol)
            .scaledFont(size: 18, weight: .semibold)
            .foregroundStyle(armed ? leadingAction.tint : Theme.inkSecondary)
            .scaleEffect(armed ? 1.14 : 0.85 + 0.15 * rightProgress)
            .opacity(Double(min(1, rightProgress * 1.25)))
            .padding(.leading, 14)
            .a11yAnimation(.snappy(duration: 0.16), value: armed)
            .accessibilityHidden(true)
          Spacer(minLength: 0)
        }
      }

      content
        .offset(x: reduceMotion ? 0 : dragOffset)
    }
    .clipped()
    .gesture(
      HorizontalPanGesture(
        allowLeft: allowSelect,
        allowRight: leadingAction != nil,
        onChanged: handlePanChanged,
        onEnded: handlePanEnded,
        onCancelled: handlePanCancelled
      )
    )
    .modifier(TaskRowSwipeA11yActions(allowSelect: allowSelect,
                                      isSelected: isSelected,
                                      onToggleSelect: onToggleSelect,
                                      leadingAction: leadingAction))
  }

  private func handlePanChanged(_ rawDx: CGFloat) {
    if activeDirection == nil {
      if rawDx < -1, allowSelect {
        activeDirection = .left
      } else if rawDx > 1, leadingAction != nil {
        activeDirection = .right
      } else {
        return
      }
    }

    switch activeDirection {
    case .left:
      let pull = max(0, -rawDx)
      let dampened = rubberBand(pull: pull,
                                threshold: Self.leftCommitThreshold,
                                maxTravel: Self.leftMaxTravel)
      dragOffset = -dampened
      updateArmed(pull: pull,
                  commit: Self.leftCommitThreshold,
                  disarm: Self.leftDisarmThreshold)
    case .right:
      let pull = max(0, rawDx)
      let dampened = rubberBand(pull: pull,
                                threshold: Self.rightCommitThreshold,
                                maxTravel: Self.rightMaxTravel)
      dragOffset = dampened
      updateArmed(pull: pull,
                  commit: Self.rightCommitThreshold,
                  disarm: Self.rightDisarmThreshold)
    case nil:
      break
    }
  }

  private func handlePanEnded(_ rawDx: CGFloat, _ velocityX: CGFloat) {
    let dir = activeDirection
    let shouldCommit = armed
    a11yAnimate(.snappy(duration: 0.22)) {
      dragOffset = 0
      activeDirection = nil
      armed = false
    }
    guard shouldCommit else { return }
    switch dir {
    case .left:
      onToggleSelect()
    case .right:
      leadingAction?.perform()
    case nil:
      break
    }
  }

  private func handlePanCancelled() {
    a11yAnimate(.snappy(duration: 0.22)) {
      dragOffset = 0
      activeDirection = nil
      armed = false
    }
  }

  private func rubberBand(pull: CGFloat, threshold: CGFloat, maxTravel: CGFloat) -> CGFloat {
    guard pull > threshold else { return pull }
    let extra = pull - threshold
    return threshold + (maxTravel - threshold) * (1 - exp(-extra / 36))
  }

  private func updateArmed(pull: CGFloat, commit: CGFloat, disarm: CGFloat) {
    if !armed, pull >= commit {
      armed = true
      Haptics.threshold()
    } else if armed, pull < disarm {
      armed = false
    }
  }

  private var selectIndicatorSymbol: String {
    if isSelected {
      return armed ? "minus.circle.fill" : "checkmark.circle.fill"
    }
    return armed ? "checkmark.circle.fill" : "circle"
  }
}

private struct TaskRowSwipeA11yActions: ViewModifier {
  let allowSelect: Bool
  let isSelected: Bool
  let onToggleSelect: () -> Void
  let leadingAction: TaskRowLeadingSwipeAction?

  func body(content: Content) -> some View {
    content
      .modifier(OptionalA11yAction(
        title: allowSelect ? (isSelected ? "Deselect" : "Select") : nil,
        perform: onToggleSelect
      ))
      .modifier(OptionalA11yAction(
        title: leadingAction?.title,
        perform: { leadingAction?.perform() }
      ))
  }
}

private struct OptionalA11yAction: ViewModifier {
  let title: String?
  let perform: () -> Void

  func body(content: Content) -> some View {
    if let title {
      content.accessibilityAction(named: title, perform)
    } else {
      content
    }
  }
}

/// First-party SwiftUI wrapper over `UIPanGestureRecognizer` that claims only
/// deliberate horizontal pans in allowed directions, immediately yielding
/// vertical pans to `ScrollView` and leading-edge swipes to `NavigationStack`.
/// Every horizontal row swipe on iOS uses it (this one and the swipe-action
/// reveal in `TaskRowActions.swift`). A SwiftUI `DragGesture` on a row inside
/// a `ScrollView` competes with the scroll for every touch, and when it wins
/// the list does not move — the "drag on a task doesn't scroll" bug.
struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
  let allowLeft: Bool
  let allowRight: Bool
  let onChanged: (CGFloat) -> Void
  /// Final horizontal translation and velocity (points per second).
  let onEnded: (CGFloat, CGFloat) -> Void
  let onCancelled: () -> Void

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
    Coordinator(allowLeft: allowLeft, allowRight: allowRight)
  }

  func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
    let pan = UIPanGestureRecognizer()
    pan.maximumNumberOfTouches = 1
    pan.delegate = context.coordinator
    return pan
  }

  func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
    context.coordinator.allowLeft = allowLeft
    context.coordinator.allowRight = allowRight
  }

  func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
    let dx = recognizer.translation(in: recognizer.view).x
    switch recognizer.state {
    case .began, .changed:
      onChanged(dx)
    case .ended:
      onEnded(dx, recognizer.velocity(in: recognizer.view).x)
    case .cancelled, .failed:
      onCancelled()
    default:
      break
    }
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var allowLeft: Bool
    var allowRight: Bool

    init(allowLeft: Bool, allowRight: Bool) {
      self.allowLeft = allowLeft
      self.allowRight = allowRight
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
            let view = pan.view else { return false }
      // Never steal the system interactive back-swipe from the leading screen edge.
      if let window = view.window, pan.location(in: window).x < 24 {
        return false
      }
      let velocity = pan.velocity(in: view)
      guard abs(velocity.x) > abs(velocity.y) * 1.4 else { return false }
      if velocity.x < -20 { return allowLeft }
      if velocity.x > 20 { return allowRight }
      return false
    }

    /// A row stacks two of these (swipe-to-select and the swipe-action
    /// reveal); both follow the same horizontal swipe, as before. Every other
    /// recognizer — the scroll view's pan included — stays exclusive.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
      other.delegate is Coordinator
    }
  }
}

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
