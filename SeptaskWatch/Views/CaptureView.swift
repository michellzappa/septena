import SwiftUI

// Capture, dictation first. The + opens the system text input at once
// (dictation, Scribble or keyboard, the user's last choice); after it, one
// tap says where the task goes. Inbox is first and the default.

struct CaptureButton: View {
  let onTitle: (String) -> Void
  private var store: WatchStore { .shared }

  var body: some View {
    TextFieldLink(prompt: Text("New To-Do")) {
      Image(systemName: "plus")
        .foregroundStyle(store.accentInkColor)
    } onSubmit: { text in
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { onTitle(trimmed) }
    }
    .buttonStyle(.glassProminent)
    .buttonBorderShape(.circle)
    .tint(store.accentColor)
    .accessibilityLabel("New To-Do")
  }
}

struct WhenPicker: View {
  let title: String
  let onPick: (WatchOp.When) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .font(.headline)
          .lineLimit(4)
          .padding(.bottom, 2)
        choice(.inbox, "Inbox", "tray")
          .handGestureShortcut(.primaryAction)
        choice(.today, "Today", "star")
        choice(.tomorrow, "Tomorrow", "sunrise")
      }
    }
    .navigationTitle("Add to")
  }

  private func choice(_ when: WatchOp.When, _ label: LocalizedStringKey, _ symbol: String) -> some View {
    let store = WatchStore.shared
    let isDefault = when == .inbox
    return Button { onPick(when) } label: {
      Label(label, systemImage: symbol)
        .foregroundStyle(isDefault ? store.accentInkColor : .primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.roundedRectangle(radius: 10))
    .tint(isDefault ? store.accentColor : Color.gray.opacity(0.3))
  }
}
