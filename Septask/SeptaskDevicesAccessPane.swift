import SwiftUI

/// Settings ▸ Account ▸ Devices & Access (`registry/settings.json`
/// `devices_access`, docs/SEPTASK_BACKEND.md §10). Every place the account is
/// signed in: app installs (sessions) and connected apps (MCP connections such
/// as Claude or ChatGPT). Another device can be signed out and a connected app
/// disconnected from here. The Apple Watch row lives here too (iOS only).
struct SeptaskDevicesAccessPane: View {
  private var sync: TaskSyncEngine { .shared }

  @State private var access: BackendAccess?
  @State private var loading = false
  @State private var error: String?
  @State private var pendingDevice: BackendAccess.Device?
  @State private var pendingConnection: BackendAccess.Connection?

  private static let page = RegistrySettings.PageID.devicesAccess
  private static let devicesSection = RegistrySettings.section("devices", page: page)
  private static let connectionsSection = RegistrySettings.section("connections", page: page)

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
        connectionsList
        if let error {
          Section {
            Text(error).font(.caption).foregroundStyle(.red)
            Button("Try Again") { Task { await load() } }
          }
        }
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
      Text("That device stops syncing within the hour. Its tasks stay on it until you sign in there again.")
    }
    .confirmationDialog(
      pendingConnection.map { String(localized: "Disconnect \($0.clientName)?") } ?? "",
      isPresented: Binding(get: { pendingConnection != nil }, set: { if !$0 { pendingConnection = nil } }),
      titleVisibility: .visible,
      presenting: pendingConnection
    ) { connection in
      Button("Disconnect", role: .destructive) { Task { await disconnect(connection) } }
      Button(RegistryPrompts.cancelTitle, role: .cancel) {}
    } message: { connection in
      Text("\(connection.clientName) can no longer read or change your tasks. Connect it again from Connect Claude.")
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

  @ViewBuilder
  private var connectionsList: some View {
    Section {
      if let connections = access?.connections {
        if connections.isEmpty {
          Text("No connected apps").foregroundStyle(.secondary)
        }
        ForEach(connections) { connection in
          connectionRow(connection)
        }
      } else if loading {
        ProgressView()
      }
    } header: {
      Text(Self.connectionsSection?.header ?? "")
    } footer: {
      if let footer = Self.connectionsSection?.footer { Text(footer) }
    }
  }

  private func deviceRow(_ device: BackendAccess.Device) -> some View {
    LabeledContent {
      if device.current {
        Text("Current device").foregroundStyle(.secondary)
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

  private func connectionRow(_ connection: BackendAccess.Connection) -> some View {
    LabeledContent {
      Button("Disconnect", role: .destructive) { pendingConnection = connection }
        .buttonStyle(.borderless)
    } label: {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(connection.clientName)
          Text(String(localized: "Last used \(Self.date(connection.lastUsed).formatted(.relative(presentation: .named)))"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: "link")
      }
    }
    .contextMenu {
      Button("Disconnect", role: .destructive) { pendingConnection = connection }
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

  private func disconnect(_ connection: BackendAccess.Connection) async {
    pendingConnection = nil
    do {
      try await TaskBackendClient.shared.disconnect(connectionID: connection.id)
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
    case "septask-ios": return String(localized: "iPhone or iPad")
    case "septask-mac": return String(localized: "Mac")
    case "septask-watch": return String(localized: "Apple Watch")
    case let name? where name.contains("android"): return String(localized: "Android")
    case let name? where name.contains("web"): return String(localized: "Browser")
    case let name? where !name.isEmpty: return name
    default: return String(localized: "Unknown device")
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
