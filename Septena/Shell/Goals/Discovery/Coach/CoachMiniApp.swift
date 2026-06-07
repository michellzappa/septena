import SwiftData
import SwiftUI

// The single Discovery tile for coaches. Tapping it opens a picker over
// CoachDomain — so "1 or many coaches" stays a config decision in
// CoachDomain, not N tiles cluttering the Discovery shelf.
//
// Read-only by design (v1): like Examined Week, it produces no DraftGoals,
// so `onFinish` is always called with `[]`. The `onFinish([DraftGoal])`
// seam is the sanctioned future bridge — a coach could one day hand a
// suggestion back as a draft the user confirms through the normal goal
// flow, without ever writing data itself.

enum CoachMiniApp: DiscoveryMiniApp {
  static let id = "coach"
  static let title = "Coaches"
  static let blurb = "Talk through your week with a focused, on-device coach."
  static let systemImage = "bubble.left.and.text.bubble.right"
  static let accent = Color.teal

  static func makeView(onFinish: @escaping ([DraftGoal]) -> Void) -> AnyView {
    AnyView(CoachPickerView(onFinish: onFinish))
  }
}

struct CoachPickerView: View {
  let onFinish: ([DraftGoal]) -> Void

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(CoachDomain.allCases) { domain in
            NavigationLink {
              CoachChatView(domain: domain, onFinish: onFinish)
            } label: {
              Label {
                VStack(alignment: .leading, spacing: 2) {
                  Text(domain.title)
                    .font(.body.weight(.medium))
                  Text(domain.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              } icon: {
                Image(systemName: domain.systemImage)
                  .foregroundStyle(domain.accent)
              }
            }
          }
        } footer: {
          Label("Conversations run on device and aren't saved.",
                systemImage: "lock.fill")
            .font(.caption2)
        }
      }
      .navigationTitle("Coaches")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { onFinish([]) }
        }
      }
    }
  }
}
