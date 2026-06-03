import SwiftUI

struct NextWatchView: View {
  @State private var conn = WatchConnectivity.shared
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(conn.bucket.isEmpty ? "Next" : conn.bucket.capitalized)
        .navigationBarTitleDisplayMode(.inline)
    }
    .task { conn.fetchNext() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { conn.fetchNext() }
    }
  }

  @ViewBuilder
  private var content: some View {
    if conn.isLoading && conn.items.isEmpty {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let err = conn.errorMessage {
      VStack(spacing: 6) {
        Image(systemName: "iphone.slash")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text(err)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding()
    } else if conn.items.isEmpty {
      VStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
          .font(.title2)
          .foregroundStyle(.green)
        Text("All done")
          .foregroundStyle(.secondary)
      }
    } else {
      List(conn.items) { item in
        NextItemRow(item: item, done: conn.completedIDs.contains(item.id)) {
          conn.complete(item)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
      }
      .listStyle(.plain)
      .environment(\.defaultMinListRowHeight, 0)
      .animation(.default, value: conn.items)
    }
  }
}

struct NextItemRow: View {
  let item: NextItem
  let done: Bool
  let onComplete: () -> Void

  private var isSuggestion: Bool { item.kind == "suggestion" }

  var body: some View {
    // Suggestions are read-only nudges (no logging UI on the watch); the rest
    // are tappable to complete.
    if isSuggestion {
      rowBody
    } else {
      Button(action: onComplete) { rowBody }
        .buttonStyle(.plain)
    }
  }

  private var rowBody: some View {
    HStack(spacing: 9) {
      Image(systemName: done ? "checkmark.circle.fill" : kindIcon)
        .font(.body)
        .foregroundStyle(iconColor)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 1) {
        Text(item.title)
          .font(.body)
          .lineLimit(1)
          .strikethrough(done)
          .foregroundStyle(done ? .secondary : .primary)
        if let sub = item.subtitle, !sub.isEmpty {
          Text(sub)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      // Overdue shown as a compact icon (not text) to free up label space.
      if item.overdue && !done {
        Spacer(minLength: 0)
        Image(systemName: "exclamationmark.circle.fill")
          .font(.caption2)
          .foregroundStyle(.red)
      }
    }
    .padding(.vertical, 1)
  }

  private var iconColor: Color {
    if done { return .green }
    if isSuggestion { return .orange }
    return item.overdue ? .red : .secondary
  }

  private var kindIcon: String {
    switch item.kind {
    case "suggestion": return "lightbulb"
    case "task":       return "circle"
    case "habit":      return "repeat.circle"
    case "supplement": return "pill"
    case "chore":      return "house"
    default:           return "circle"
    }
  }
}
