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
        NextItemRow(item: item) { conn.complete(item) }
      }
      .listStyle(.carousel)
    }
  }
}

struct NextItemRow: View {
  let item: NextItem
  let onComplete: () -> Void

  var body: some View {
    Button(action: onComplete) {
      HStack(spacing: 10) {
        Image(systemName: kindIcon)
          .foregroundStyle(item.overdue ? .red : .secondary)
          .frame(width: 18)

        VStack(alignment: .leading, spacing: 2) {
          Text(item.title)
            .font(.body)
            .lineLimit(2)
          if let sub = item.subtitle {
            Text(sub)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }

        if let trail = item.trailing {
          Spacer(minLength: 0)
          Text(trail)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .buttonStyle(.plain)
  }

  private var kindIcon: String {
    switch item.kind {
    case "habit":      return "repeat.circle"
    case "supplement": return "pill"
    case "chore":      return "house"
    default:           return "circle"
    }
  }
}
