#if os(iOS)
import SwiftUI
import WatchConnectivity

// Settings ▸ Apple Watch (docs/WATCH.md). iOS can't install a watch app by
// itself: the only sanctioned path is the Watch app's Available Apps list, so
// the Install row opens the Watch app. Once installed, the row shows the link
// state and offers Reconnect (mints and sends a fresh watch session).

struct SeptaskWatchSettingsSection: View {
  private var bridge: WatchBridge { .shared }

  var body: some View {
    if WCSession.isSupported() {
      Section {
        NavigationLink {
          SeptaskWatchSettingsPage()
        } label: {
          LabeledContent {
            Text(statusText).foregroundStyle(.secondary)
          } label: {
            Label(RegistrySettings.copy("access_devices", "deviceWatch"), systemImage: "applewatch")
          }
        }
      }
      .onAppear { bridge.refreshState() }
    }
  }

  private var statusText: String {
    let s = bridge.state
    if !s.paired { return String(localized: "Not paired") }
    if !s.installed { return String(localized: "Not installed") }
    return bridge.lastHandoff == nil ? String(localized: "Not connected") : String(localized: "Connected")
  }
}

struct SeptaskWatchSettingsPage: View {
  @Environment(\.openURL) private var openURL
  private var bridge: WatchBridge { .shared }

  var body: some View {
    let s = bridge.state
    Form {
      Section {
        LabeledContent("Watch", value: s.paired ? String(localized: "Paired") : String(localized: "Not paired"))
        LabeledContent("Septena on Watch", value: s.installed ? String(localized: "Installed") : String(localized: "Not installed"))
        if s.installed {
          LabeledContent("Last connected") {
            if let at = bridge.lastHandoff {
              Text(at.formatted(date: .abbreviated, time: .shortened))
            } else {
              Text("Never")
            }
          }
        }
      } footer: {
        if let error = bridge.lastError {
          Text(error).foregroundStyle(.red)
        }
      }

      if s.paired && !s.installed {
        Section {
          Button {
            openWatchApp()
          } label: {
            Label("Install on Apple Watch", systemImage: "arrow.down.circle")
          }
        } footer: {
          Text("Opens the Watch app. Scroll to Available Apps and tap Install next to Septena. To get it automatically next time, turn on Automatic App Install in Watch ▸ General.")
        }
      }

      if s.installed {
        Section {
          Button {
            bridge.reconnect()
          } label: {
            Label(bridge.minting ? "Connecting…" : "Reconnect Watch", systemImage: "arrow.triangle.2.circlepath")
          }
          .disabled(bridge.minting || !TaskBackendClient.hasSession)
          Button {
            openWatchApp()
          } label: {
            Label("Open Watch App", systemImage: "applewatch")
          }
        } footer: {
          Text("Reconnect sends your watch a fresh sign-in. Use it if the watch says it isn't connected.")
        }
      }
    }
    .navigationTitle(RegistrySettings.copy("access_devices", "deviceWatch"))
    .onAppear { bridge.refreshState() }
  }

  private func openWatchApp() {
    guard let primary = URL(string: "itms-watchs://"), let fallback = URL(string: "itms-watch://") else { return }
    openURL(primary) { accepted in
      if !accepted { openURL(fallback) }
    }
  }
}
#endif
