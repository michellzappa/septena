import SwiftUI

// The Undo toast: shown while a removal waits out its undo window
// (`WatchStore.undoable`). Sits at the bottom, over whatever list is showing.

private struct UndoToast: ViewModifier {
  private var store: WatchStore { .shared }

  func body(content: Content) -> some View {
    content.overlay(alignment: .bottom) {
      if let u = store.undoable {
        Button { store.undo() } label: {
          HStack(spacing: 6) {
            Text(u.message).lineLimit(1)
            Spacer(minLength: 4)
            Text("Undo").fontWeight(.semibold).foregroundStyle(Color.accentColor)
          }
          .font(.footnote)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.ultraThinMaterial, in: Capsule())
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityLabel("\(u.message). Undo")
      }
    }
    .animation(.snappy, value: store.undoable)
  }
}

extension View {
  func undoToast() -> some View { modifier(UndoToast()) }
}
