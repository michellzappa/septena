import SwiftUI

// Standard top-right "+" toolbar button for every destination panel
// openable from the homepage tile grid. Mirrors the webapp's contextual
// quick-log surface — tap "+" inside a section and you land directly on
// that section's Add Info page, ready to log/start/add in one more tap.
//
// Self-contained: each panel mounts its own AddInfoSheet, so the quick-add
// stacks cleanly on top of the destination sheet (no cross-tab plumbing
// through NavigationState).

private struct QuickAddToolbarModifier: ViewModifier {
  let section: AddInfoSection
  @State private var showAddInfo = false

  func body(content: Content) -> some View {
    content
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showAddInfo = true
          } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("Quick Add")
          .keyboardShortcut("k", modifiers: .command)
        }
      }
      .sheet(isPresented: $showAddInfo) {
        AddInfoSheet(initialSection: section)
          #if os(iOS)
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
          #else
          .frame(width: 560, height: 520)
          #endif
      }
  }
}

extension View {
  /// Adds the standard "+" quick-add affordance to a destination panel.
  /// Tapping presents `AddInfoSheet` jumped to `section`'s quick-add page.
  func quickAddToolbar(_ section: AddInfoSection) -> some View {
    modifier(QuickAddToolbarModifier(section: section))
  }
}
