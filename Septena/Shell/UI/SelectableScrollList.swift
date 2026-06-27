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
//     nudge the cursor row into view without re-centering the viewport on click.
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
      .background(SelectableListRowBackground(isSelected: isSelected))
      .id(id)
      .accessibilityElement(children: .contain)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .modifier(SelectableRowGestures(id: id, actions: actions))
  }
}

/// Platform-split click/tap wiring kept off the main modifier so the macOS-only
/// `NSEvent` read and `septenaOnDoubleClick` overlay don't leak into iOS.
private struct SelectableRowGestures: ViewModifier {
  let id: String
  let actions: SelectableRowActions

  func body(content: Content) -> some View {
    #if os(macOS)
    content
      // Single click selects (reading ⌘/⇧ live); double-click activates via the
      // AppKit overlay that's purpose-built for LazyVStack rows and lets the
      // single click fall through to this `onTapGesture`.
      .onTapGesture {
        guard actions.selectable else { actions.activate(id); return }
        actions.click(id, currentEventModifiers())
      }
      .septenaOnDoubleClick { actions.activate(id) }
    #else
    content.onTapGesture { actions.activate(id) }
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
  @ViewBuilder var content: () -> Content

  @FocusState private var focused: Bool
  /// The keyboard cursor — the row ↑/↓ move and Return/Space act on. Distinct
  /// from `selection` so ⇧-range extension has a stable origin.
  @State private var cursor: String?
  /// Anchor for ⇧-click / ⇧-arrow range selection.
  @State private var anchor: String?

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      // Clicking the empty paper behind the rows clears the selection — the
      // LazyVStack only fills its content height, so taps below the last row
      // land here. Rows sit above and claim their own clicks first.
      .background(
        Theme.paperBackground
          .contentShape(Rectangle())
          .onTapGesture { onClear() }
      )
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
          jumpToEnd(down: down, extend: extend, proxy: proxy)
        } else {
          move(down ? 1 : -1, extend: extend, proxy: proxy)
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

  private func move(_ delta: Int, extend: Bool, proxy: ScrollViewProxy) {
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
    apply(index: nextIndex, extend: extend, proxy: proxy, scrollDown: delta > 0)
  }

  private func jumpToEnd(down: Bool, extend: Bool, proxy: ScrollViewProxy) {
    guard !orderedIDs.isEmpty else { return }
    apply(
      index: down ? orderedIDs.count - 1 : 0,
      extend: extend,
      proxy: proxy,
      scrollDown: down
    )
  }

  private func apply(
    index: Int,
    extend: Bool,
    proxy: ScrollViewProxy? = nil,
    scrollDown: Bool? = nil
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
    // not re-anchor the viewport (`.center` was the "page jumps" complaint).
    guard let proxy, let scrollDown else { return }
    let anchor: UnitPoint = scrollDown
      ? UnitPoint(x: 0.5, y: 0.85)
      : UnitPoint(x: 0.5, y: 0.15)
    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: anchor) }
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
