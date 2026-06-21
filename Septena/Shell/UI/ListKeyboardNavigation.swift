import SwiftUI

// The single keyboard-navigation contract for every selectable `List` in the
// app — the Tasks tab, the Next feed, and (later) section drawers all share it
// so "selecting with the keyboard" behaves identically everywhere.
//
// The model is deliberately thin and leans on native `List(selection:)`:
//   • The list takes programmatic focus on appear, so ↑↓ run native
//     `List(selection:)` row traversal with no custom key handling.
//   • Return / Space / Escape map to the surface's own activate / toggle /
//     clear handlers.
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
  /// list's Return/Space/Escape so typing isn't hijacked, and — on its
  /// falling edge — triggers a focus-reclaim so ↑↓ keep selecting.
  let inputActive: Bool
  let hasSelection: Bool
  let onReturn: () -> Void
  let onSpace: () -> Void
  let onEscape: () -> Void

  @FocusState private var listFocused: Bool

  func body(content: Content) -> some View {
    content
      .focusable()
      .focused($listFocused)
      .focusEffectDisabled()
      .onAppear { listFocused = true }
      .onChange(of: inputActive) { _, active in
        guard !active else { return }
        DispatchQueue.main.async { listFocused = true }
      }
      .onKeyPress(.return) {
        guard !inputActive, hasSelection else { return .ignored }
        onReturn()
        return .handled
      }
      .onKeyPress(.space) {
        guard !inputActive, hasSelection else { return .ignored }
        onSpace()
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
  /// traversal, with Return / Space / Escape wired to the surface's handlers.
  /// See `ListKeyboardNavigation`.
  func listKeyboardNavigation(
    inputActive: Bool,
    hasSelection: Bool,
    onReturn: @escaping () -> Void,
    onSpace: @escaping () -> Void,
    onEscape: @escaping () -> Void
  ) -> some View {
    modifier(ListKeyboardNavigation(
      inputActive: inputActive,
      hasSelection: hasSelection,
      onReturn: onReturn,
      onSpace: onSpace,
      onEscape: onEscape
    ))
  }
}
