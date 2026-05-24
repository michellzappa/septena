import SwiftUI

/// Tiny progress spinner shown in the dashboard toolbar while CKEngine has
/// an in-flight fetch or send. Renders nothing when idle so it doesn't
/// take up space in the toolbar between syncs.
struct SyncIndicator: View {
  @Environment(CKEngine.self) private var ckEngine

  var body: some View {
    if ckEngine.isSyncing {
      ProgressView()
        .controlSize(.small)
        .transition(.opacity)
    }
  }
}
