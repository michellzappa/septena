import SwiftUI

/// Sync status for the dashboard toolbar.
///
/// Two distinct states, because they mean different things to the reader:
///
/// - **Bootstrap** (first launch on this device against an existing account):
///   the whole account is coming down and the app looks empty in the meantime.
///   That deserves words and a moving count, not a bare spinner — otherwise a
///   long first sync is indistinguishable from a hang.
/// - **Routine sync**: a fetch or send is in flight. A quiet spinner is enough;
///   the data is already on screen.
///
/// Renders nothing when idle so it takes up no toolbar space between syncs.
struct SyncIndicator: View {
  @Environment(CKEngine.self) private var ckEngine

  var body: some View {
    if ckEngine.isBootstrapping {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(ckEngine.bootstrapStatusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .transition(.opacity)
    } else if ckEngine.isSyncing {
      ProgressView()
        .controlSize(.small)
        .transition(.opacity)
    }
  }
}
