import SwiftUI

// The single keyboard-navigation contract for every selectable `List` in the
// app — the Tasks tab, the Next feed, and (later) section drawers all share it
// so "selecting with the keyboard" behaves identically everywhere.
//
// The model is deliberately thin and leans on native `List(selection:)`:
//   • The list takes programmatic focus on appear, so ↑↓ run native
//     `List(selection:)` row traversal with no custom key handling.
//   • Return / Escape map to the surface's own activate / clear handlers.
//     List completion stays on the explicit ⌘K Task-menu command, so Space
//     remains available to focused controls.
//   • While a text field or composer owns the keyboard (`inputActive`), those
//     three keys are forwarded to that field instead of the list; when it flips
//     back to false we reclaim focus on the next runloop (the editor steals it
//     on open and nothing returns it otherwise), so the cursor survives an edit.
//
// `focusEffectDisabled()` suppresses the macOS blue focus ring around the whole
// list — the native selection highlight on the focused row is indicator enough.
// ↑↓ traversal and deletion are intentionally NOT bound here: arrows are native,
// and a hard delete stays gated behind ⌘⌫ (the "Delete" menu command) so it
// can't fire on a bare keypress.
private struct ListKeyboardNavigation: ViewModifier {
  /// True while a text field / composer owns the keyboard. Suppresses the
  /// list's Return/Escape so typing isn't hijacked, and — on its
  /// falling edge — triggers a focus-reclaim so ↑↓ keep selecting.
  let inputActive: Bool
  /// When false, the surface is off-screen (another tab, a covered route).
  /// Reclaim list focus when it flips back to true so ↑↓ work immediately.
  let isActive: Bool
  /// Whether this surface runs the pointer+keyboard selection model at all.
  /// False on iPhone compact, where a tap activates directly and nothing should
  /// claim keyboard focus.
  let focusable: Bool
  let hasSelection: Bool
  let onReturn: () -> Void
  let onEscape: () -> Void

  @FocusState private var listFocused: Bool

  func body(content: Content) -> some View {
    content
      .focusable(focusable)
      .focused($listFocused)
      .focusEffectDisabled()
      .onAppear { if isActive, focusable { listFocused = true } }
      .onChange(of: inputActive) { _, active in
        guard !active, isActive, focusable else { return }
        DispatchQueue.main.async { listFocused = true }
      }
      .onChange(of: isActive) { _, active in
        guard active, !inputActive, focusable else { return }
        DispatchQueue.main.async { listFocused = true }
      }
      .onKeyPress(.return) {
        guard !inputActive, hasSelection else { return .ignored }
        onReturn()
        return .handled
      }
      .onKeyPress(.escape) {
        guard !inputActive, hasSelection else { return .ignored }
        onEscape()
        return .handled
      }
  }
}

extension View {
  /// Make a selectable `List` keyboard-driven: focusable for native ↑↓
  /// traversal, with Return / Escape wired to the surface's handlers.
  /// See `ListKeyboardNavigation`.
  ///
  /// A surface whose container ISN'T a native `List` (the Tasks section drawer,
  /// whose rows are `DrawerSection`s) still uses this for the focus contract and
  /// Return / Escape, and binds its own ↑↓ — that's the one part native `List`
  /// would have supplied. What it must NOT do is hand-roll a second copy of the
  /// focus-reclaim dance; there were four before this.
  func listKeyboardNavigation(
    inputActive: Bool,
    isActive: Bool = true,
    focusable: Bool = true,
    hasSelection: Bool,
    onReturn: @escaping () -> Void,
    onEscape: @escaping () -> Void
  ) -> some View {
    modifier(ListKeyboardNavigation(
      inputActive: inputActive,
      isActive: isActive,
      focusable: focusable,
      hasSelection: hasSelection,
      onReturn: onReturn,
      onEscape: onEscape
    ))
  }
}
