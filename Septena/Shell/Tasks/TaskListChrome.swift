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
  /// Visual drag position in `.global` coordinates.
  var fingerLocation: CGPoint = .zero
  /// Center of the resting Magic Plus orb in `.global` coordinates (cancel zone).
  var homeCenter: CGPoint = .zero
  /// Currently targeted drop zone, if any.
  var activeTarget: ActiveTarget? = nil

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
    fingerLocation = location
    activeTarget = nil
    Haptics.tap()
    resolveTarget(for: location)
  }

  func updateDrag(at location: CGPoint) {
    fingerLocation = location
    resolveTarget(for: location)
  }

  func endDrag(at location: CGPoint) {
    fingerLocation = location
    resolveTarget(for: location)
    let hit = activeTarget
    let action = hit.flatMap { zones[$0.id]?.onDrop }
    a11yAnimate(.snappy(duration: 0.22)) {
      isDragging = false
      activeTarget = nil
    }
    if let hit, let action {
      action(hit.before)
    }
  }

  /// Clear stale zones when switching tabs / navigation routes.
  func reset() {
    isDragging = false
    activeTarget = nil
    zones.removeAll()
  }

  private func resolveTarget(for location: CGPoint) {
    // Dragging back onto the resting orb socket cancels cleanly.
    let dx = location.x - homeCenter.x
    let dy = location.y - homeCenter.y
    if homeCenter != .zero && hypot(dx, dy) < 40 {
      if activeTarget != nil {
        a11yAnimate(.snappy(duration: 0.18)) { activeTarget = nil }
      }
      return
    }

    // Aim slightly above the fingertip where the floating ghost card sits.
    let probe = CGPoint(x: location.x, y: location.y - 24)
    let candidates = zones.values.filter { zone in
      let padY: CGFloat = zone.priority >= 2 ? 4 : 0
      return zone.frame.insetBy(dx: -8, dy: -padY).contains(probe)
    }

    let best = candidates.max { a, b in
      if a.priority != b.priority { return a.priority < b.priority }
      return abs(a.frame.midY - probe.y) > abs(b.frame.midY - probe.y)
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
      Haptics.tap()
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
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .strokeBorder(Color.accentColor.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.accentColor.opacity(0.06))
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
/// Plus orb and morphs it live into a ghost task card or contextual action pill
/// as it glides over drop targets.
struct MagicPlusFloatingOverlay: View {
  let drag: MagicPlusDragState

  var body: some View {
    GeometryReader { geo in
      if drag.isDragging {
        let localOrigin = geo.frame(in: .global).origin
        let rawX = drag.fingerLocation.x - localOrigin.x
        let rawY = drag.fingerLocation.y - localOrigin.y - 36
        let halfW = estimatedWidth / 2
        let clampedX = min(max(rawX, halfW + 16), max(halfW + 16, geo.size.width - halfW - 16))
        let clampedY = max(rawY, 64)

        morphedContent
          .position(x: clampedX, y: clampedY)
          .a11yAnimation(.snappy(duration: 0.2), value: drag.activeTarget?.kind)
          .transition(.scale(scale: 0.8).combined(with: .opacity))
      }
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }

  private var estimatedWidth: CGFloat {
    switch drag.activeTarget?.kind {
    case .taskRow:     return 280
    case .taskSection: return 220
    case .newProject:  return 220
    case .newArea:     return 150
    case nil:          return 62
    }
  }

  @ViewBuilder
  private var morphedContent: some View {
    switch drag.activeTarget?.kind {
    case .taskRow(let context):
      // Morph into a crisp live ghost task row ready to land in the parted gap.
      HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .frame(width: 20, height: 20)
        Text("New Task")
          .font(.septenaTaskTitle)
          .foregroundStyle(.primary)
        Spacer(minLength: 8)
        if let context, !context.isEmpty {
          Text(context)
            .font(.septenaCaption)
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
        }
      }
      .padding(.horizontal, 14)
      .frame(width: 280, height: 46)
      .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
      )
      .shadow(color: .black.opacity(0.28), radius: 14, y: 6)

    case .taskSection(let label):
      morphPill(icon: "checkmark.circle.fill", title: label)

    case .newProject(let label):
      morphPill(icon: "number.circle.fill", title: label)

    case .newArea:
      morphPill(icon: "square.stack.3d.up.fill", title: "New Area")

    case nil:
      // Free-floating lifted blue "+" orb.
      ZStack {
        Circle()
          .fill(Color.accentColor.gradient)
          .overlay(
            Circle()
              .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
        Image(systemName: "plus")
          .scaledFont(size: 24, weight: .bold)
          .foregroundStyle(Color.white)
      }
      .frame(width: 62, height: 62)
    }
  }

  private func morphPill(icon: String, title: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .scaledFont(size: 16, weight: .semibold)
        .foregroundStyle(Color.white)
      Text(title)
        .font(.septenaButton)
        .foregroundStyle(Color.white)
        .lineLimit(1)
    }
    .padding(.horizontal, 16)
    .frame(height: 44)
    .background(Color.accentColor.gradient, in: Capsule())
    .overlay(
      Capsule()
        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
  }
}
#endif

// MARK: - Multi-task stacked drag preview

/// Tactile drag preview for `.draggable(TaskDragIDs)`: a compact rounded task
/// card when lifting one row, or a subtle physical stack with an accent count
/// badge when lifting a multi-selection (`docs/MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md` §6.1).
struct TaskDragStackPreview: View {
  let title: String
  let count: Int
  var accent: Color = .accentColor

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

// MARK: - iOS swipe-to-select (pull-left toggle on SelectableScrollList)

extension View {
  /// Things-style horizontal pull-left gesture to toggle task selection on iOS
  /// and iPadOS (`docs/MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md` §3). Pass-through
  /// on macOS or when `enabled` is false.
  @ViewBuilder
  func taskRowSwipeToSelect(
    enabled: Bool,
    isSelected: Bool,
    onToggleSelect: @escaping () -> Void
  ) -> some View {
    #if os(iOS)
    if enabled {
      modifier(TaskRowSwipeToSelectModifier(isSelected: isSelected,
                                            onToggleSelect: onToggleSelect))
    } else {
      self
    }
    #else
    self
    #endif
  }
}

#if os(iOS)
private struct TaskRowSwipeToSelectModifier: ViewModifier {
  let isSelected: Bool
  let onToggleSelect: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dragOffset: CGFloat = 0
  @State private var armed = false

  private static let commitThreshold: CGFloat = 36
  private static let disarmThreshold: CGFloat = 28
  private static let maxTravel: CGFloat = 56

  private var progress: CGFloat {
    min(1, max(0, -dragOffset / Self.commitThreshold))
  }

  func body(content: Content) -> some View {
    ZStack(alignment: .trailing) {
      if dragOffset < -2 {
        Image(systemName: indicatorSymbol)
          .scaledFont(size: 18, weight: .semibold)
          .foregroundStyle(armed ? Color.accentColor : Theme.inkSecondary)
          .scaleEffect(armed ? 1.12 : 0.85 + 0.15 * progress)
          .opacity(Double(min(1, progress * 1.25)))
          .padding(.trailing, 14)
          .a11yAnimation(.snappy(duration: 0.16), value: armed)
          .accessibilityHidden(true)
      }

      content
        .offset(x: reduceMotion ? 0 : dragOffset)
    }
    .clipped()
    .gesture(
      HorizontalLeftPanGesture(
        onChanged: { rawDx in
          let pull = max(0, -rawDx)
          let dampened: CGFloat
          if pull <= Self.commitThreshold {
            dampened = pull
          } else {
            let extra = pull - Self.commitThreshold
            dampened = Self.commitThreshold + (Self.maxTravel - Self.commitThreshold) * (1 - exp(-extra / 36))
          }
          dragOffset = -dampened
          if !armed, pull >= Self.commitThreshold {
            armed = true
            Haptics.tick()
          } else if armed, pull < Self.disarmThreshold {
            armed = false
          }
        },
        onEnded: { _ in
          let shouldToggle = armed
          a11yAnimate(.snappy(duration: 0.22)) {
            dragOffset = 0
            armed = false
          }
          if shouldToggle {
            onToggleSelect()
          }
        },
        onCancelled: {
          a11yAnimate(.snappy(duration: 0.22)) {
            dragOffset = 0
            armed = false
          }
        }
      )
    )
    .accessibilityAction(named: isSelected ? "Deselect" : "Select") {
      onToggleSelect()
    }
  }

  private var indicatorSymbol: String {
    if isSelected {
      return armed ? "minus.circle.fill" : "checkmark.circle.fill"
    }
    return armed ? "checkmark.circle.fill" : "circle"
  }
}

/// First-party SwiftUI wrapper over `UIPanGestureRecognizer` that claims only
/// deliberate horizontal leftward pulls, immediately yielding vertical pans to
/// `ScrollView` and leading-edge swipes to `NavigationStack`.
private struct HorizontalLeftPanGesture: UIGestureRecognizerRepresentable {
  let onChanged: (CGFloat) -> Void
  let onEnded: (CGFloat) -> Void
  let onCancelled: () -> Void

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
    Coordinator()
  }

  func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
    let pan = UIPanGestureRecognizer()
    pan.maximumNumberOfTouches = 1
    pan.delegate = context.coordinator
    return pan
  }

  func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
    let dx = recognizer.translation(in: recognizer.view).x
    switch recognizer.state {
    case .began, .changed:
      onChanged(dx)
    case .ended:
      onEnded(dx)
    case .cancelled, .failed:
      onCancelled()
    default:
      break
    }
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
            let view = pan.view else { return false }
      // Never steal the system interactive back-swipe from the leading screen edge.
      if let window = view.window, pan.location(in: window).x < 24 {
        return false
      }
      let velocity = pan.velocity(in: view)
      // Require clearly horizontal leftward intent so vertical scrolling always wins.
      return velocity.x < -20 && abs(velocity.x) > abs(velocity.y) * 1.4
    }
  }
}
#endif
