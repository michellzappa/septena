import SwiftUI
import EventKit

// Things-3-style Settings: a sheet with a section list on the left and a
// detail pane on the right. Sections: General, Reminders Inbox, Sync, About.
//
// Presentation: `.sheet(isPresented:)` from ContentView, bound to
// `nav.showSettings`. Inside, NavigationSplitView collapses cleanly to a
// push stack on iPhone compact — same code path for iOS and macOS.

// MARK: - Default keys

enum SettingsKey {
  static let badgeShowOverdue = "septena.badge.showOverdue"
  static let startupView      = "septena.startup.view"
  static let todayShowCompleted = "septena.today.showCompleted"
  static let syncLastSucceeded = "septena.sync.lastSucceededAt"
  /// Global sort applied to task lists inside a project or area. Stored as
  /// the raw value of `TaskSort`. Lives in UserDefaults rather than per-list
  /// state — there's no per-project manual order in this app, so one global
  /// choice is the whole sort surface.
  static let taskSort         = "septena.task.sort"
}

/// Sort modes for tasks within a project or area detail view. Areas and
/// projects in the sidebar have manual drag-reorder, but tasks inside them
/// do not — so these two derived orderings are the entire sort surface.
enum TaskSort: String, CaseIterable, Identifiable {
  case dateAdded
  case alphabetical
  case dueDate
  var id: String { rawValue }
  var label: String {
    switch self {
    case .dateAdded:    return "Sort by Date Added"
    case .alphabetical: return "Sort by Name"
    case .dueDate:      return "Sort by Due Date"
    }
  }
  var icon: String {
    switch self {
    case .dateAdded:    return "clock"
    case .alphabetical: return "textformat"
    case .dueDate:      return "calendar"
    }
  }
}

enum StartupView: String, CaseIterable, Identifiable {
  case today, inbox, upcoming, next
  var id: String { rawValue }
  var label: String {
    switch self {
    case .today: return "Today"
    case .inbox: return "Inbox"
    case .upcoming: return "Upcoming"
    case .next: return "Next"
    }
  }
  var route: Route {
    switch self {
    case .today: return .filter(.today)
    case .inbox: return .filter(.inbox)
    case .upcoming: return .filter(.upcoming)
    case .next: return .next
    }
  }
}

// MARK: - Sheet root

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selection: Section? = .general
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail

  enum Section: String, CaseIterable, Identifiable {
    case general, remindersInbox, sync, about
    var id: String { rawValue }
    var title: String {
      switch self {
      case .general: return "General"
      case .remindersInbox: return "Reminders Inbox"
      case .sync: return "Sync"
      case .about: return "About"
      }
    }
    var icon: String {
      switch self {
      case .general: return "gearshape"
      case .remindersInbox: return "checklist"
      case .sync: return "arrow.triangle.2.circlepath"
      case .about: return "info.circle"
      }
    }
    var tint: Color {
      switch self {
      case .general: return .gray
      case .remindersInbox: return .orange
      case .sync: return .blue
      case .about: return .purple
      }
    }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility,
                        preferredCompactColumn: $preferredCompactColumn) {
      List(Section.allCases, selection: $selection) { section in
        Label {
          Text(section.title)
        } icon: {
          ColoredGlyph(icon: section.icon, color: section.tint, size: 22)
        }
        .tag(section)
      }
      .navigationTitle("Settings")
      #if os(iOS)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      #endif
    } detail: {
      NavigationStack {
        let section = selection ?? .general
        pane(for: section)
          .navigationTitle(section.title)
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
      }
    }
    #if os(macOS)
    .frame(minWidth: 720, minHeight: 460)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
      }
    }
    #endif
  }

  @ViewBuilder
  private func pane(for section: Section) -> some View {
    switch section {
    case .general:        GeneralSettingsPane()
    case .remindersInbox: RemindersInboxSettingsPane()
    case .sync:           SyncSettingsPane()
    case .about:          AboutSettingsPane()
    }
  }
}

// MARK: - General

struct GeneralSettingsPane: View {
  @AppStorage(SettingsKey.badgeShowOverdue) private var badge: Bool = false
  @AppStorage(SettingsKey.startupView) private var startup: String = StartupView.today.rawValue
  @AppStorage(SettingsKey.todayShowCompleted) private var showCompleted: Bool = true

  var body: some View {
    Form {
      Section("Badge") {
        Toggle("Show overdue count on app icon", isOn: $badge)
      }
      Section("Open on launch") {
        Picker("Open on launch", selection: $startup) {
          ForEach(StartupView.allCases) { v in
            Text(v.label).tag(v.rawValue)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
      Section("Today") {
        Toggle("Show completed tasks in Today", isOn: $showCompleted)
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Reminders Inbox

struct RemindersInboxSettingsPane: View {
  @State private var bridge = RemindersBridge.shared
  @State private var access: RemindersBridge.Access = .notDetermined
  @State private var lists: [EKCalendar] = []
  @State private var selectedID: String?

  var body: some View {
    Form {
      Section {
        Text("Pick a Reminders list. Its pending items show in your Inbox; tap to import (originals are removed from Reminders).")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      switch access {
      case .notDetermined:
        Section {
          Button("Grant Access to Reminders") {
            Task {
              _ = await bridge.requestAccess()
              refresh()
            }
          }
        }
      case .denied, .writeOnly:
        Section {
          Text(access == .writeOnly
               ? "Septena has write-only access. Enable Full Access in Settings → Privacy → Reminders."
               : "Reminders access is denied. Enable it in Settings → Privacy → Reminders.")
            .font(.callout)
        }
      case .granted:
        Section("Source list") {
          pickerRow(title: "None", tint: nil, id: nil)
          ForEach(lists, id: \.calendarIdentifier) { cal in
            pickerRow(title: cal.title,
                      tint: Color(cgColor: cal.cgColor),
                      id: cal.calendarIdentifier)
          }
        }

        Section {
          Toggle("Auto-import new reminders", isOn: Binding(
            get: { bridge.autoImport },
            set: { bridge.autoImport = $0 }
          ))
          .disabled(bridge.sourceListID == nil)
        } footer: {
          Text("When on, pending items in the source list import automatically and are removed from Reminders. Runs on app launch and whenever Reminders changes.")
        }

        if !bridge.recentImports.isEmpty {
          Section("Recent auto-imports") {
            ForEach(bridge.recentImports.prefix(10)) { entry in
              autoImportRow(entry)
            }
            Button("Clear log", role: .destructive) {
              bridge.recentImports = []
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
  }

  @ViewBuilder
  private func autoImportRow(_ entry: AutoImportLogEntry) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(entry.succeeded ? Color.green : Color.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .foregroundStyle(.primary)
          .lineLimit(2)
        HStack(spacing: 6) {
          Text(relativeDate(entry.importedAt))
            .font(.caption)
            .foregroundStyle(.secondary)
          if let err = entry.error {
            Text("· \(err)")
              .font(.caption)
              .foregroundStyle(.orange)
              .lineLimit(1)
          }
        }
      }
      Spacer()
    }
  }

  private func relativeDate(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
  }

  @ViewBuilder
  private func pickerRow(title: String, tint: Color?, id: String?) -> some View {
    Button {
      bridge.sourceListID = id
      selectedID = id
    } label: {
      HStack(spacing: 10) {
        if let tint {
          Circle().fill(tint).frame(width: 10, height: 10)
        } else {
          Circle().stroke(.secondary, lineWidth: 1).frame(width: 10, height: 10)
        }
        Text(title).foregroundStyle(.primary)
        Spacer()
        if selectedID == id {
          Image(systemName: "checkmark")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tint)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func refresh() {
    access = bridge.access
    if access == .granted {
      lists = bridge.reminderLists()
      selectedID = bridge.sourceListID
    }
  }
}

// MARK: - Sync

struct SyncSettingsPane: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext

  @State private var serverURL: String = ""
  @State private var isChecking = false
  @State private var connectionStatus: String = ""
  @State private var isSyncing = false

  @AppStorage(SettingsKey.syncLastSucceeded) private var lastSyncedAt: Double = 0

  var body: some View {
    Form {
      Section {
        HStack {
          Image(systemName: client.isOffline ? "wifi.slash" : "checkmark.circle.fill")
            .foregroundStyle(client.isOffline ? Color.red : Color.green)
          Text(client.isOffline ? "Offline" : "Connected")
            .foregroundStyle(.primary)
          Spacer()
          if lastSyncedAt > 0 {
            Text("Last sync: \(lastSyncedDescription)")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }

      Section("Server URL") {
        TextField("http://100.74.150.55:7000", text: $serverURL)
          #if os(iOS)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
          .autocorrectionDisabled()
          #endif
        Button {
          Task { await testConnection() }
        } label: {
          HStack {
            if isChecking { ProgressView().controlSize(.small) }
            Text("Test Connection")
          }
        }
        .disabled(isChecking || serverURL.isEmpty)
        if !connectionStatus.isEmpty {
          Text(connectionStatus)
            .font(.callout)
            .foregroundStyle(connectionStatus.hasPrefix("✅") ? .green : .red)
        }
        Button("Save") { save() }
          .disabled(serverURL.isEmpty || serverURL == nav.serverURL)
      }

      Section {
        Button {
          Task { await syncNow() }
        } label: {
          HStack {
            if isSyncing { ProgressView().controlSize(.small) }
            Text("Sync Now")
          }
        }
        .disabled(isSyncing)
      } footer: {
        Text("No auth — Septena is reachable on the tailnet.")
      }
    }
    .formStyle(.grouped)
    .onAppear { serverURL = nav.serverURL }
  }

  private var lastSyncedDescription: String {
    let date = Date(timeIntervalSince1970: lastSyncedAt)
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
  }

  private func testConnection() async {
    isChecking = true
    connectionStatus = "Testing…"
    defer { isChecking = false }
    guard let url = URL(string: serverURL) else {
      connectionStatus = "❌ Invalid URL"; return
    }
    do {
      let testClient = SeptenaClient(baseURL: url)
      let result = try await testClient.ping()
      connectionStatus = "✅ \(result)"
    } catch {
      connectionStatus = "❌ \(error.localizedDescription)"
    }
  }

  private func save() {
    guard let url = URL(string: serverURL) else { return }
    nav.serverURL = serverURL
    ClientProvider.shared.update(baseURL: url)
    Task { await theme.refresh(from: ClientProvider.shared.client) }
  }

  private func syncNow() async {
    isSyncing = true
    defer { isSyncing = false }
    let syncer = Syncer(client: client, context: modelContext)
    await syncer.pullAll()
  }
}

// MARK: - About

struct AboutSettingsPane: View {
  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
  }
  private var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
  }

  var body: some View {
    Form {
      Section {
        VStack(alignment: .center, spacing: 8) {
          ColoredGlyph(icon: "circle.grid.cross.fill", color: .blue, size: 56)
            .opacity(0.0) // placeholder slot; brand glyph below
          Text("Septena")
            .font(.title2.bold())
          Text("Version \(version) (\(build))")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .listRowBackground(Color.clear)
      }
      Section("Links") {
        Link("Source", destination: URL(string: "https://github.com/")!)
        Link("Feedback", destination: URL(string: "mailto:mz@envisioning.com")!)
        Link("License", destination: URL(string: "https://opensource.org/licenses/MIT")!)
      }
    }
    .formStyle(.grouped)
  }
}
