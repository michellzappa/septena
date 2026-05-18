import SwiftUI

/// Floating "+" button anchored to the bottom-trailing corner, sized to
/// match the iOS tab bar so the two read as a single bottom control strip.
/// Replaces the old top-right toolbar `+` on Week and Next. Tap opens the
/// app-global Add Info sheet.
struct AddInfoFAB: View {
  @Environment(SectionTheme.self) private var theme
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 56, height: 56)
        .background(theme.accent, in: Circle())
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Add Info")
    .keyboardShortcut("k", modifiers: .command)
    .padding(.trailing, 20)
    .padding(.bottom, 20)
  }
}
