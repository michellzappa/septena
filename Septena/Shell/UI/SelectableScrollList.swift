import SwiftUI
#if os(macOS)
import AppKit
#endif

// A `ScrollView { LazyVStack }` that behaves like a native selectable `List`,
// minus the one thing native `List(selection:)` can't do on macOS: host an
// inline-editable `TextField` in a *selectable* row without corrupting the
// List's focus/selection (the documented "no inline TextField in a selectable
// macOS List" trap). By owning the container ourselves we get Things-style
// expand-in-place editing — a row that grows to reveal its full editor inline —
// while re-earning the handful of behaviors `List` gave for free.
//
// What we deliberately reproduce (so a migrated surface looks/behaves identical):
//   • Selection — click / ⌘-click (toggle) / ⇧-click (range), a `Set<String>`
//     that stays the single source of truth, exactly like `List(selection:)`.
//   • Keyboard traversal — ↑/↓ move a cursor, ⇧+↑/↓ extend the range, ⌘+↑/↓
//     jump to the ends; Return activates, Space toggles, Esc clears. Arrow keys
//     nudge the cursor row into view only when it would clip — no viewport
//     re-anchoring while the row is already on-screen.
//   • The neutral selection capsule — reuses `SelectableListRowBackground`, the
//     same view the `List` rows paint, so the highlight is pixel-identical.
//   • Accessibility — selected rows carry `.isSelected`.
//
// What we intentionally DON'T reproduce, because the migrated surfaces don't use
// them: `.swipeActions` and `.onMove` reorder. (Tasks has neither.)
//
// macOS click modifiers (⌘ / ⇧) are read once from `NSEvent.modifierFlags` at
// click time — a one-shot state read, NOT an event monitor (the banned pattern):
// SwiftUI has no first-class "which modifiers were held during this tap" API,
// and stacking modifier-scoped `TapGesture`s double-fires on a plain click.

// MARK: - Row action plumbing

/// The selection callbacks a row needs, injected by the container through the
/// environment so any row anywhere in the content tree can drive selection
/// without the container threading closures by hand.
struct SelectableRowActions {
  /// A click landed on `id`; `modifiers` carries ⌘/⇧ so the container can pick
  /// replace / toggle / range-extend.
  var click: (_ id: String, _ modifiers: EventModifiers) -> Void = { _, _ in }
  /// A primary activation (double-click on macOS, single tap on iOS).
  var activate: (_ id: String) -> Void = { _ in }
  /// Whether rows should wire click-selection at all (false on iPhone compact,
  /// which has no multi-select chrome — there a tap just activates).
  var selectable: Bool = true
}

private struct SelectableRowActionsKey: EnvironmentKey {
  static let defaultValue = SelectableRowActions()
}

/// Row frames in the scroll view's coordinate space — used to scroll only when
/// the cursor row would clip, instead of re-anchoring the viewport on every
/// arrow press.
private struct SelectableRowFrameKey: PreferenceKey {
  static var defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

/// Visible height of the scroll view's clip rect.
private struct SelectableScrollViewportHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private enum SelectableScrollListMetrics {
  static let coordinateSpace = "selectableScrollList"
}

/// How a row sits relative to the scroll view's visible clip.
private enum SelectableRowClip {
  case fullyVisible
  case clippedAbove
  case clippedBelow
}

/// Keyboard-only scroll nudge — set after ↑/↓ so `onChange` runs with fresh
/// layout metrics (a `DispatchQueue.main.async` closure would capture stale
/// `@State` from the struct copy).
private struct SelectableScrollRequest: Equatable {
  let id: String
  let scrollDown: Bool
  let force: Bool
}

extension EnvironmentValues {
  var selectableRowActions: SelectableRowActions {
    get { self[SelectableRowActionsKey.self] }
    set { self[SelectableRowActionsKey.self] = newValue }
  }
}

// MARK: - Row modifier

extension View {
  /// Make a row inside a `SelectableScrollList` selectable: it paints the shared
  /// neutral capsule when selected, takes the section accent-free highlight, is
  /// tagged for `scrollTo`, exposes the `.isSelected` a11y trait, and routes
  /// click (macOS) / tap (iOS) / double-click into the container's selection.
  ///
  /// The visual chrome is identical to a `List` row because it uses the very
  /// same `SelectableListRowBackground`; only the container differs.
  func selectableScrollRow(id: String, isSelected: Bool) -> some View {
    modifier(SelectableScrollRowModifier(id: id, isSelected: isSelected))
  }
}

private struct SelectableScrollRowModifier: ViewModifier {
  let id: String
  let isSelected: Bool
  @Environment(\.selectableRowActions) private var actions

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(ScrollRowSelectionBackground(isSelected: isSelected))
      .background {
        GeometryReader { geo in
          Color.clear.preference(
            key: SelectableRowFrameKey.self,
            value: [id: geo.frame(in: .named(SelectableScrollListMetrics.coordinateSpace))]
          )
        }
      }
      .id(id)
      .accessibilityElement(children: .contain)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .modifier(SelectableRowGestures(id: id, isSelected: isSelected, actions: actions))
  }
}

/// Platform-split click/tap wiring kept off the main modifier so the macOS-only
/// `NSEvent` read and `septenaOnDoubleClick` overlay don't leak into iOS.
private struct SelectableRowGestures: ViewModifier {
  let id: String
  let isSelected: Bool
  let actions: SelectableRowActions

  func body(content: Content) -> some View {
    #if os(macOS)
    content
      // Double-click activates (opens the inline editor). Detected with the
      // native count-2 tap — NOT the AppKit `DoubleClickCatcher` overlay, whose
      // `NSApp.currentEvent` hit-test loses the second click whenever the row is
      // `.draggable` (AppKit's drag-tracking swallows the mouse-down sequence, so
      // `clickCount` never reaches 2). SwiftUI's gesture system arbitrates this
      // count-2 tap against `.draggable` and the count-1 tap below correctly.
      // Attached BEFORE the single tap so the higher count gets priority.
      .onTapGesture(count: 2) { actions.activate(id) }
      // Single click selects (reading ⌘/⇧ live). On a non-selectable list
      // (iPhone-style) a single click just activates.
      .onTapGesture {
        guard actions.selectable else { actions.activate(id); return }
        actions.click(id, currentEventModifiers())
      }
    #else
    content.onTapGesture {
      // Regular-width iPad uses the same selection-first model as Mac: first
      // tap selects, second tap opens. Compact iPhone passes `selectable: false`
      // and keeps its direct tap-to-open behavior.
      guard actions.selectable else { actions.activate(id); return }
      if isSelected {
        actions.activate(id)
      } else {
        actions.click(id, [])
      }
    }
    #endif
  }
}

// MARK: - Container

/// A selectable, keyboard-navigable scroll list. Compose `content` exactly like
/// a `List` body — `Section`s, `ForEach`s, custom rows — and tag every
/// selectable row with `.selectableScrollRow(id:isSelected:)`. Pass the same
/// `orderedIDs` your arrow-key traversal should follow (the flat, render-order
/// id list — e.g. Tasks' `keyboardOrderedTaskIds`).
struct SelectableScrollList<Content: View>: View {
  @Binding var selection: Set<String>
  /// Flat render-order ids for ↑/↓ traversal and ⇧-range math. Recompute it the
  /// same way the rows are ordered or arrow-nav will skip/scramble rows.
  let orderedIDs: [String]
  /// True while a text field / inline editor owns the keyboard — suppresses the
  /// list's key handling so typing isn't hijacked, and (on its falling edge)
  /// reclaims list focus so ↑/↓ keep working after an edit. Mirrors the
  /// `listKeyboardNavigation` contract.
  var inputActive: Bool = false
  /// False when the surface is off-screen (another tab/route); reclaims focus
  /// when it flips back so arrows work immediately on return.
  var isActive: Bool = true
  /// Whether rows wire click-selection (false on iPhone compact).
  var selectable: Bool = true
  /// Return / double-click / single-tap(iOS) on a row.
  var onActivate: (String) -> Void = { _ in }
  /// Space on the cursor row (typically toggle-complete).
  var onToggle: (String) -> Void = { _ in }
  /// Esc with a selection, or a click on the empty paper behind the rows.
  var onClear: () -> Void = {}
  /// Monotonic tick — parent increments to force-scroll to `scrollToID`.
  var scrollToTick: Int = 0
  /// Row id to scroll into view when `scrollToTick` changes.
  var scrollToID: String? = nil
  /// Canvas fill behind the rows. Paper (white) for flat single-group lists;
  /// the gray grouped background for sectioned lists whose rows sit in cards,
  /// so the cards lift off the canvas (matching the sidebar / Next homes).
  var canvasFill: Color = Theme.paperBackground
  /// When set, reserves the iPad floating chrome bar directly on this
  /// `ScrollView`'s scroll content (must land on the scroll view — wrapping
  /// modifiers don't propagate `.contentMargins`). Pass the top padding the
  /// first row already contributes so the total matches the other tabs.
  var iPadTabBarInsetOwnPadding: CGFloat? = nil
  /// When rows carry an outer card margin, pass it so wide-pane insets include it.
  var wideContentGutter: CGFloat = 0
  @ViewBuilder var content: () -> Content

  @FocusState private var focused: Bool
  /// The keyboard cursor — the row ↑/↓ move and Return/Space act on. Distinct
  /// from `selection` so ⇧-range extension has a stable origin.
  @State private var cursor: String?
  /// Anchor for ⇧-click / ⇧-arrow range selection.
  @State private var anchor: String?
  @State private var viewportHeight: CGFloat = 0
  @State private var rowFrames: [String: CGRect] = [:]
  @State private var scrollRequest: SelectableScrollRequest?

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      #if os(iOS)
      .septenaTabScrollInsets(
        top: max(0, PageChromeMetrics.iPadBarHeight - (iPadTabBarInsetOwnPadding ?? 0)),
        contentGutter: wideContentGutter)
      #else
      .septenaTabScrollInsets(top: 0, contentGutter: wideContentGutter)
      #endif
      .coordinateSpace(name: SelectableScrollListMetrics.coordinateSpace)
      .onPreferenceChange(SelectableRowFrameKey.self) { newFrames in
        // Defer one run-loop turn — many rows report frames in the same layout
        // pass; writing @State synchronously triggers "updated multiple times
        // per frame" and can cascade extra layout.
        Task { @MainActor in
          guard !rowFrames.isApproximatelyEqual(to: newFrames) else { return }
          rowFrames = newFrames
          fulfillPendingScroll(proxy: proxy)
        }
      }
      .background {
        GeometryReader { geo in
          Color.clear.preference(
            key: SelectableScrollViewportHeightKey.self,
            value: geo.size.height
          )
        }
      }
      .onPreferenceChange(SelectableScrollViewportHeightKey.self) {
        viewportHeight = $0
        fulfillPendingScroll(proxy: proxy)
      }
      .onChange(of: scrollRequest) { _, request in
        guard request != nil else { return }
        fulfillPendingScroll(proxy: proxy)
      }
      .onChange(of: scrollToTick) { _, _ in
        guard scrollToTick > 0, let id = scrollToID else { return }
        scrollRequest = SelectableScrollRequest(id: id, scrollDown: true, force: true)
      }
      // Fill the detail pane edge-to-edge on macOS (click-to-clear on empty
      // paper). On iOS let the ScrollView size naturally so content scrolls
      // under the nav bar like Week — `.frame(maxHeight: .infinity)` pinned
      // the viewport below the bar and left a dead gray band.
      #if os(macOS)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      #else
      .frame(maxWidth: .infinity, alignment: .topLeading)
      #endif
      .background {
        canvasFill
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { onClear() }
      }
      .scrollEdgeEffectStyle(.soft, for: .top)
      .environment(\.selectableRowActions, SelectableRowActions(
        click: handleClick,
        activate: onActivate,
        selectable: selectable
      ))
      // Focusable for native key delivery; the blue focus ring is suppressed —
      // the selection capsule is indicator enough (same call the List makes).
      .focusable(selectable)
      .focused($focused)
      .focusEffectDisabled()
      .onAppear { if isActive && selectable { focused = true } }
      .onChange(of: inputActive) { _, active in
        guard !active, isActive, selectable else { return }
        DispatchQueue.main.async { focused = true }
      }
      .onChange(of: isActive) { _, active in
        guard active, !inputActive, selectable else { return }
        DispatchQueue.main.async { focused = true }
      }
      // `.repeat` as well as `.down` so HOLDING ↑/↓ streams through the list
      // (key-repeat) instead of moving a single row and stopping.
      .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
        guard !inputActive, selectable else { return .ignored }
        let extend = press.modifiers.contains(.shift)
        let down = press.key == .downArrow
        if press.modifiers.contains(.command) {
          jumpToEnd(down: down, extend: extend)
        } else {
          move(down ? 1 : -1, extend: extend)
        }
        return .handled
      }
      .onKeyPress(.return) {
        guard !inputActive, selectable, let id = activeRow else { return .ignored }
        onActivate(id)
        return .handled
      }
      .onKeyPress(.space) {
        guard !inputActive, selectable, let id = activeRow else { return .ignored }
        onToggle(id)
        return .handled
      }
      .onKeyPress(.escape) {
        guard !inputActive, selectable, !selection.isEmpty else { return .ignored }
        onClear()
        return .handled
      }
      .onChange(of: selection) { _, sel in
        // Keep the cursor coherent if selection is cleared/replaced externally
        // (delete, programmatic select, or the inline editor pinning the closed
        // task) so the next arrow press resumes FROM that row, not the top.
        if sel.isEmpty { cursor = nil; anchor = nil }
        else if let c = cursor, !sel.contains(c) { cursor = sel.first; anchor = sel.first }
        else if cursor == nil { cursor = sel.first; anchor = sel.first }
      }
    }
  }

  /// The row a keyboard command acts on: the cursor if set, else the lone
  /// selected row — so the first Return/Space after a click isn't a no-op.
  private var activeRow: String? {
    cursor ?? selection.first
  }

  // MARK: Selection

  private func handleClick(_ id: String, _ modifiers: EventModifiers) {
    focused = true
    if modifiers.contains(.command) {
      if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
      cursor = id; anchor = id
    } else if modifiers.contains(.shift) {
      shiftSelect(to: id)
    } else {
      selection = [id]; cursor = id; anchor = id
    }
  }

  private func shiftSelect(to id: String) {
    guard let origin = anchor ?? cursor,
          let i = orderedIDs.firstIndex(of: origin),
          let j = orderedIDs.firstIndex(of: id) else {
      selection = [id]; cursor = id; anchor = id; return
    }
    let range = i <= j ? i...j : j...i
    selection = Set(orderedIDs[range])
    cursor = id
  }

  private func move(_ delta: Int, extend: Bool) {
    guard !orderedIDs.isEmpty else { return }
    // Start from the cursor, or — if a row is selected but the cursor was reset
    // (e.g. just closed an inline editor) — from the selected row, so ↑/↓ move
    // FROM the selection instead of jumping to index 0.
    let current = activeRow.flatMap { orderedIDs.firstIndex(of: $0) }
    let nextIndex: Int
    if let current {
      nextIndex = min(max(current + delta, 0), orderedIDs.count - 1)
    } else {
      nextIndex = delta > 0 ? 0 : orderedIDs.count - 1
    }
    apply(index: nextIndex, extend: extend, scrollDown: delta > 0, forceScroll: false)
  }

  private func jumpToEnd(down: Bool, extend: Bool) {
    guard !orderedIDs.isEmpty else { return }
    apply(
      index: down ? orderedIDs.count - 1 : 0,
      extend: extend,
      scrollDown: down,
      forceScroll: true
    )
  }

  private func apply(
    index: Int,
    extend: Bool,
    scrollDown: Bool? = nil,
    forceScroll: Bool = false
  ) {
    let id = orderedIDs[index]
    cursor = id
    if extend, let a = anchor, let ai = orderedIDs.firstIndex(of: a) {
      let range = ai <= index ? ai...index : index...ai
      selection = Set(orderedIDs[range])
    } else {
      selection = [id]
      anchor = id
    }
    // Scroll only for keyboard traversal — clicks set `cursor` too but must
    // not move the viewport. Defer via `scrollRequest` so clip detection reads
    // post-layout row frames (not a stale struct copy).
    guard let scrollDown else { return }
    scrollRequest = SelectableScrollRequest(id: id, scrollDown: scrollDown, force: forceScroll)
  }

  private func fulfillPendingScroll(proxy: ScrollViewProxy) {
    guard let request = scrollRequest else { return }
    if request.force {
      scrollToRowIfNeeded(
        id: request.id,
        scrollDown: request.scrollDown,
        force: true,
        proxy: proxy
      )
      scrollRequest = nil
      return
    }
    switch rowClipStatus(request.id, scrollDown: request.scrollDown) {
    case .fullyVisible:
      scrollRequest = nil
    case .clippedAbove, .clippedBelow:
      scrollToRowIfNeeded(
        id: request.id,
        scrollDown: request.scrollDown,
        force: false,
        proxy: proxy
      )
      scrollRequest = nil
    case nil:
      // Wait for the initial layout pass — before any row has reported a frame,
      // `nil` only means the list has not measured yet. Once other rows have
      // frames, though, a missing target is the expected LazyVStack case: the
      // next keyboard row is beyond the materialized buffer. Ask the proxy to
      // reveal it so SwiftUI realizes that row; otherwise long Mac lists never
      // follow selection past the visible region.
      guard viewportHeight > 0 else { return }
      guard !rowFrames.isEmpty else { return }
      proxy.scrollTo(request.id, anchor: request.scrollDown ? .bottom : .top)
      scrollRequest = nil
    }
  }

  private func scrollToRowIfNeeded(
    id: String,
    scrollDown: Bool,
    force: Bool,
    proxy: ScrollViewProxy
  ) {
    if force {
      proxy.scrollTo(id, anchor: scrollDown ? .bottom : .top)
      return
    }
    switch rowClipStatus(id, scrollDown: scrollDown) {
    case .fullyVisible, nil:
      return
    case .clippedAbove:
      proxy.scrollTo(id, anchor: .top)
    case .clippedBelow:
      proxy.scrollTo(id, anchor: .bottom)
    }
  }

  /// `nil` when layout isn't ready — treat as visible so we don't spuriously
  /// scroll on the first arrow after a click.
  private func rowClipStatus(_ id: String, scrollDown: Bool) -> SelectableRowClip? {
    guard viewportHeight > 0, let frame = rowFrames[id] else { return nil }
    let slack: CGFloat = 2
    let above = frame.minY < -slack
    let below = frame.maxY > viewportHeight + slack
    if above && below { return scrollDown ? .clippedBelow : .clippedAbove }
    if above { return .clippedAbove }
    if below { return .clippedBelow }
    return .fullyVisible
  }

}

private extension Dictionary where Key == String, Value == CGRect {
  /// Layout noise from LazyVStack re-measure often re-reports the same frames;
  /// skip @State writes when nothing moved (reduces preference churn).
  func isApproximatelyEqual(to other: [String: CGRect]) -> Bool {
    guard count == other.count else { return false }
    for (key, frame) in self {
      guard let otherFrame = other[key] else { return false }
      if abs(frame.minX - otherFrame.minX) > 0.5 { return false }
      if abs(frame.minY - otherFrame.minY) > 0.5 { return false }
      if abs(frame.width - otherFrame.width) > 0.5 { return false }
      if abs(frame.height - otherFrame.height) > 0.5 { return false }
    }
    return true
  }
}

#if os(macOS)
/// One-shot read of the currently-held modifier keys at click time. This is a
/// state read of `NSEvent.modifierFlags`, not an installed event monitor — the
/// banned pattern is a *monitor* that intercepts the event stream. Kept a free
/// function (not a static on the generic `SelectableScrollList`) so callers
/// needn't specialize `Content` to read modifiers.
private func currentEventModifiers() -> EventModifiers {
  let flags = NSEvent.modifierFlags
  var modifiers = EventModifiers()
  if flags.contains(.command) { modifiers.insert(.command) }
  if flags.contains(.shift) { modifiers.insert(.shift) }
  if flags.contains(.option) { modifiers.insert(.option) }
  if flags.contains(.control) { modifiers.insert(.control) }
  return modifiers
}
#endif
