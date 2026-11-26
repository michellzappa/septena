import SwiftUI

/// Sync status for the Mac window's title bar: a quiet spinner while a sync
/// with the task backend (`TaskSyncEngine`, ADR 0002) runs. The data is
/// already on screen, so no words.
///
/// Renders nothing when idle so it takes up no toolbar space between syncs.
/// It reads `TaskSyncEngine`, not `CKEngine`: CKEngine never starts, so its
/// `isSyncing` was always false (#576).
struct SyncIndicator: View {
  private let sync = TaskSyncEngine.shared

  var body: some View {
    if sync.isSyncing {
      ProgressView()
        .controlSize(.small)
        .transition(.opacity)
    }
  }
}
