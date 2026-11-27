import SwiftUI

/// Settings ▸ Account ▸ Devices (`registry/settings.json` `devices_access`,
/// docs/SEPTASK_BACKEND.md §10). Every app install signed in to the account.
/// Another device can be signed out from here. The Apple Watch row lives here
/// too (iOS only). Agents (MCP connections) are a separate list:
/// `SeptaskAgentsSections`, Settings ▸ AI & Agents ▸ Agents.
struct SeptaskDevicesAccessPane: View {
  private var sync: TaskSyncEngine { .shared }

  @State private var access: BackendAccess?
  @State private var loading = false
  @State private var error: String?
  @State private var pendingDevice: BackendAccess.Device?

  private static let page = RegistrySettings.PageID.devicesAccess
  private static let devicesSection = RegistrySettings.section("devices", page: page)

  var body: some View {
    Form {
      if !sync.signedIn {
        Section {
          Text("Sign in to see every device and app that can reach your tasks.")
            .foregroundStyle(.secondary)
          SeptaskSignInButton()
        }
      } else {
        devicesList
        if let error {
          Section {
            Text(error).font(.caption).foregroundStyle(.red)
            Button("Try Again") { Task { await load() } }
          }
        }
        SeptaskSignInApprovalSection()
      }

      #if os(iOS)
      // Apple Watch: install + link state (iOS-only, live WatchConnectivity state).
      SeptaskWatchSettingsSection()
      #endif
    }
    .formStyle(.grouped)
    .navigationTitle(RegistrySettings.pageById[Self.page]?.title ?? "")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .task(id: sync.signedIn) { await load() }
    .refreshable { await load() }
    .confirmationDialog(
      pendingDevice.map { String(localized: "Sign out \(Self.deviceName($0.client))?") } ?? "",
      isPresented: Binding(get: { pendingDevice != nil }, set: { if !$0 { pendingDevice = nil } }),
      titleVisibility: .visible,
      presenting: pendingDevice
    ) { device in
      Button("Sign Out", role: .destructive) { Task { await signOut(device) } }
      Button(RegistryPrompts.cancelTitle, role: .cancel) {}
    } message: { _ in
      Text(RegistrySettings.copy("access_devices", "signOutMessage"))
    }
  }

  // MARK: Sections

  @ViewBuilder
  private var devicesList: some View {
    Section {
      if let devices = access?.devices {
        if devices.isEmpty {
          Text("No devices").foregroundStyle(.secondary)
        }
        ForEach(devices) { device in
          deviceRow(device)
        }
      } else if loading {
        ProgressView()
      }
    } header: {
      Text(Self.devicesSection?.header ?? "")
    } footer: {
      if let footer = Self.devicesSection?.footer { Text(footer) }
    }
  }

  private func deviceRow(_ device: BackendAccess.Device) -> some View {
    LabeledContent {
      if device.current {
        Text(RegistrySettings.copy("access_devices", "currentDevice")).foregroundStyle(.secondary)
      } else {
        Button("Sign Out", role: .destructive) { pendingDevice = device }
          .buttonStyle(.borderless)
      }
    } label: {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(Self.deviceName(device.client))
          Text(Self.lastSeenLine(device))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: Self.deviceSymbol(device.client))
      }
    }
    .contextMenu {
      if !device.current {
        Button("Sign Out", role: .destructive) { pendingDevice = device }
      }
    }
  }

  // MARK: Actions

  private func load() async {
    guard sync.signedIn else {
      access = nil
      error = nil
      return
    }
    loading = true
    defer { loading = false }
    do {
      access = try await TaskBackendClient.shared.access()
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func signOut(_ device: BackendAccess.Device) async {
    pendingDevice = nil
    do {
      try await TaskBackendClient.shared.signOutDevice(sid: device.sid)
    } catch {
      self.error = error.localizedDescription
    }
    await load()
  }

  // MARK: Labels

  private static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

  private static func lastSeenLine(_ device: BackendAccess.Device) -> String {
    let seen = date(device.lastSeen).formatted(.relative(presentation: .named))
    if device.syncing { return String(localized: "Active \(seen)") }
    return String(localized: "Active \(seen) · not syncing")
  }

  /// A device's `X-Septena-Client` name, in words.
  static func deviceName(_ client: String?) -> String {
    switch client {
    case "septask-ios": return RegistrySettings.copy("access_devices", "deviceApplePhone")
    case "septask-mac": return RegistrySettings.copy("access_devices", "deviceMac")
    case "septask-watch": return RegistrySettings.copy("access_devices", "deviceWatch")
    case let name? where name.contains("android"): return RegistrySettings.copy("access_devices", "deviceAndroid")
    case let name? where name.contains("web"): return RegistrySettings.copy("access_devices", "deviceBrowser")
    case let name? where !name.isEmpty: return name
    default: return RegistrySettings.copy("access_devices", "deviceUnknown")
    }
  }

  static func deviceSymbol(_ client: String?) -> String {
    switch client {
    case "septask-ios": return "iphone"
    case "septask-mac": return "laptopcomputer"
    case "septask-watch": return "applewatch"
    case let name? where name.contains("web"): return "globe"
    default: return "desktopcomputer"
    }
  }
}
