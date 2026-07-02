import SwiftUI
import SwiftData
import Combine

/// Septask — the focused task app over Septena's task data (docs/SEPTASK.md).
///
/// Same repo, same SeptenaCore, same private CloudKit records; a different
/// composition root. This target compiles with the `SEPTASK` condition, which
/// flips `RuntimeProfile.current` to `.tasksOnly` so `SeptenaServices.start()`
/// binds only the task/area/project mutators and never touches the life-OS
/// subsystems or third-party provider stores.
///
/// P1 shell: mounts the SAME task surface the full app ships — `ContentView`
/// (sidebar + list split view) over `Shell/Tasks` + `Shell/Sidebar`, included
/// by source, never copied. Full-app-only spots inside those files are
/// `#if !SEPTASK`-gated. Welcome and a dedicated Settings surface are P3.
@main
struct SeptaskApp: App {
  @State private var navigation = NavigationState()
  @State private var theme = SectionTheme()
  @State private var dayClock = DayClock()
  /// iPad nav-bar chrome coordination — SeptenaPage's nav-depth reporter
  /// reads it unconditionally, so the shell must provide one even though
  /// Septask draws no global chrome overlay.
  @State private var iPadChrome = IPadChromeModel()
  /// Celebration layer for task completions (Today cleared → arc flourish),
  /// same wiring as the full app: overlay mounted innermost so it can read
  /// `logCommit` from the environment chain below.
  @State private var logCommit = LogCommitCenter()
  private let localStore = LocalStore.shared
  private let services = SeptenaServices.shared
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ContentView()
        .overlay { LogCommitOverlay() }
        // Keep the tasks accent aligned with the CloudKit-synced section
        // color — inbound batches repaint the cache-backed theme.
        .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
          theme.paintFromCache()
        }
        .environment(navigation)
        .environment(theme)
        .environment(services.taskMutator)
        .environment(services.areasMutator)
        .environment(services.projectsMutator)
        .environment(services.ckEngine)
        .environment(dayClock)
        .environment(logCommit)
        .environment(iPadChrome)
        .modelContainer(localStore.container)
        .task {
          await services.start()
          // Off the critical path, like App.swift: first frame renders from
          // the local mirror; the server pull patches it via notifications.
          Task { await services.absorbRemoteChanges() }
        }
        .onChange(of: scenePhase) { _, phase in
          // Foreground fetch is the reliable refresh path (push is best
          // effort) — mandatory in both apps per docs/SEPTASK.md §5.
          if phase == .active {
            Task { try? await services.ckEngine.fetchChanges() }
          }
        }
    }
  }
}
