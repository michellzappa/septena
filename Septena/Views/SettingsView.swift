import SwiftUI
import EventKit

// Settings — the single unified surface for everything user-configurable.
// One sheet, one store, one entry point (sidebar row + ⌘,).
//
// Sections:
//   • General         — startup view, badge, today toggle, task sort (local)
//   • Appearance      — theme + eInk         (read-only, /api/settings)
//   • Units & Time    — units + timezones    (read-only, /api/settings)
//   • Targets         — macros + health      (read-only, /api/settings)
//   • Integrations    — Reminders / Calendar / HealthKit permissions
//   • Reminders Inbox — source list picker + auto-import log
//   • Sync            — server URL + manual sync
//   • About           — version / links
//
// Server-side fields are read-only for now (editing is a separate concern).
// The Week toolbar gear and SettingsDestinationView no longer exist —
// Settings is an app-level surface, not a Week tile.

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

// MARK: - Store
//
// One Observable holding the cached /api/settings response. Local prefs
// continue to live as @AppStorage at use sites — they're already shared
// through the SettingsKey constants and don't need wrapping.

@MainActor
@Observable
final class SettingsStore {
  var serverSettings: AppSettings? = nil
  var sections: [SeptenaClient.SectionConfig] = []
  var caffeine: CaffeineConfig? = nil
  var cannabis: CannabisConfig? = nil
  var serverLoading: Bool = false

  func refresh(from client: SeptenaClient) async {
    serverLoading = true
    defer { serverLoading = false }
    async let s = try? await client.settings()
    async let secs = try? await client.sections()
    async let caf = try? await client.caffeineConfig()
    async let cnb = try? await client.cannabisConfig()
    let (sv, sc, cf, cn) = await (s, secs, caf, cnb)
    serverSettings = sv
    sections = sc ?? []
    caffeine = cf
    cannabis = cn
  }
}

// MARK: - Sheet root

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selection: Section? = .general
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail

  enum Section: String, CaseIterable, Identifiable {
    case general, integrations, server, sync, about
    var id: String { rawValue }
    var title: String {
      switch self {
      case .general:      return "General"
      case .integrations: return "Integrations"
      case .server:       return "Server"
      case .sync:         return "Sync"
      case .about:        return "About"
      }
    }
    var icon: String {
      switch self {
      case .general:      return "gearshape"
      case .integrations: return "app.connected.to.app.below.fill"
      case .server:       return "server.rack"
      case .sync:         return "arrow.triangle.2.circlepath"
      case .about:        return "info.circle"
      }
    }
    var tint: Color {
      switch self {
      case .general:      return .gray
      case .integrations: return .indigo
      case .server:       return .green
      case .sync:         return .blue
      case .about:        return .purple
      }
    }
  }

  var body: some View {
    #if os(iOS)
    // NavigationStack + NavigationLink(value:) — selection-based push in a
    // sheet-hosted NavigationSplitView is unreliable on iPhone compact
    // (rows highlight but don't navigate). A plain stack with explicit
    // links is the canonical iOS Settings pattern and pushes every time.
    NavigationStack {
      List(Section.allCases) { section in
        NavigationLink(value: section) {
          Label {
            Text(section.title)
          } icon: {
            ColoredGlyph(icon: section.icon, color: section.tint, size: 22)
          }
        }
      }
      .navigationTitle("Settings")
      .navigationDestination(for: Section.self) { section in
        pane(for: section)
          .navigationTitle(section.title)
          .navigationBarTitleDisplayMode(.inline)
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    #else
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
    } detail: {
      NavigationStack {
        let section = selection ?? .general
        pane(for: section)
          .navigationTitle(section.title)
      }
    }
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
    case .general:      GeneralSettingsPane()
    case .integrations: IntegrationsSettingsPane()
    case .server:       ServerSettingsPane()
    case .sync:         SyncSettingsPane()
    case .about:        AboutSettingsPane()
    }
  }
}

// MARK: - General

struct GeneralSettingsPane: View {
  @AppStorage(SettingsKey.badgeShowOverdue) private var badge: Bool = false
  @AppStorage(SettingsKey.startupView) private var startup: String = StartupView.today.rawValue
  @AppStorage(SettingsKey.todayShowCompleted) private var showCompleted: Bool = true
  @AppStorage(SettingsKey.taskSort) private var taskSortRaw: String = TaskSort.dateAdded.rawValue

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
      Section("Task sort") {
        Picker("Sort tasks by", selection: $taskSortRaw) {
          ForEach(TaskSort.allCases) { s in
            Label(s.label, systemImage: s.icon).tag(s.rawValue)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Server (all read-only /api/settings: appearance, units, time, targets)
//
// One pane showing everything the FastAPI server reports. Edited
// elsewhere for now — the iOS app is purely a display surface for
// these. Keeping it in one place mirrors how the data is fetched
// (one endpoint, one cached payload).

struct ServerSettingsPane: View {
  @Environment(SettingsStore.self) private var store

  var body: some View {
    Form {
      if let s = store.serverSettings {
        Section("Appearance") {
          row("Theme", s.theme?.capitalized ?? "—")
          row("eInk mode", (s.eink ?? false) ? "On" : "Off")
        }
        if let u = s.units {
          Section("Units") {
            row("Weight", u.weight)
            row("Distance", u.distance)
          }
        }
        if let t = s.time {
          Section("Time") {
            row("Home timezone", t.homeTimezone)
            if let m = t.travelMode, m != "off" {
              row("Travel mode", m)
              if let tz = t.travelTimezone { row("Travel timezone", tz) }
            }
          }
        }
        if let t = s.targets {
          Section("Macro targets") {
            if let lo = t.proteinMinG, let hi = t.proteinMaxG {
              row("Protein", "\(Int(lo))–\(Int(hi)) g")
            }
            if let lo = t.fatMinG, let hi = t.fatMaxG {
              row("Fat", "\(Int(lo))–\(Int(hi)) g")
            }
            if let lo = t.carbsMinG, let hi = t.carbsMaxG {
              row("Carbs", "\(Int(lo))–\(Int(hi)) g")
            }
            if let lo = t.kcalMin, let hi = t.kcalMax {
              row("Calories", "\(Int(lo))–\(Int(hi)) kcal")
            }
          }
          Section("Health targets") {
            if let z2 = t.z2WeeklyMin {
              row("Z2 weekly", "\(z2) min")
            }
            if let sl = t.sleepTargetH {
              row("Sleep", String(format: "%.1f h", sl))
            }
            if let lo = t.fastingMinH, let hi = t.fastingMaxH {
              row("Fasting", String(format: "%.0f–%.0f h", lo, hi))
            }
            if let lo = t.weightMinKg, let hi = t.weightMaxKg {
              row("Weight", String(format: "%.1f–%.1f kg", lo, hi))
            }
            if let lo = t.fatMinPct, let hi = t.fatMaxPct {
              row("Body fat", String(format: "%.0f–%.0f %%", lo, hi))
            }
          }
        }
        if let order = s.sectionOrder, !order.isEmpty {
          Section("Section order") {
            Text(order.joined(separator: " · "))
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      } else if store.serverLoading {
        Section { ProgressView().frame(maxWidth: .infinity) }
      } else {
        unavailable
      }

      // Sub-panes — list-shaped configs that get pushed deeper rather
      // than crowding the Server overview. Each row hides itself when
      // its endpoint is empty so the surface only shows configured data.
      Section("Catalogs") {
        if !store.sections.isEmpty {
          NavigationLink {
            SectionsPalettePane()
              .navigationTitle("Sections")
              #if os(iOS)
              .navigationBarTitleDisplayMode(.inline)
              #endif
          } label: {
            HStack {
              Label("Sections palette", systemImage: "paintpalette")
              Spacer()
              Text("\(store.sections.count)")
                .foregroundStyle(.secondary)
            }
          }
        }
        if let caf = store.caffeine, !(caf.beans.isEmpty && (caf.methods ?? []).isEmpty) {
          NavigationLink {
            CaffeinePresetsPane()
              .navigationTitle("Caffeine")
              #if os(iOS)
              .navigationBarTitleDisplayMode(.inline)
              #endif
          } label: {
            HStack {
              Label("Caffeine presets", systemImage: "cup.and.saucer")
              Spacer()
              Text("\(caf.beans.count) beans")
                .foregroundStyle(.secondary)
            }
          }
        }
        if let cnb = store.cannabis, !cnb.strains.isEmpty {
          NavigationLink {
            CannabisPresetsPane()
              .navigationTitle("Cannabis")
              #if os(iOS)
              .navigationBarTitleDisplayMode(.inline)
              #endif
          } label: {
            HStack {
              Label("Cannabis presets", systemImage: "leaf")
              Spacer()
              Text("\(cnb.strains.count) strains")
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      readOnlyFooter
    }
    .formStyle(.grouped)
  }
}

// MARK: - Sections palette (read-only)

private struct SectionsPalettePane: View {
  @Environment(SettingsStore.self) private var store

  var body: some View {
    Form {
      Section {
        ForEach(store.sections, id: \.key) { sec in
          HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .fill(parseColor(sec.color))
              .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
              Text(sec.label).foregroundStyle(.primary)
              Text(sec.key)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(sec.color)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
      } footer: {
        Text("The accent palette for every mini-app. Configured server-side.")
      }
    }
    .formStyle(.grouped)
  }

  /// Tolerant parse of "#rrggbb" hex strings. Falls back to gray for
  /// hsl(...) or other formats — the server returns either, but only the
  /// hex form decodes natively. A future pass can add hsl() support.
  private func parseColor(_ s: String) -> Color {
    var hex = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return .gray }
    let r = Double((v >> 16) & 0xFF) / 255
    let g = Double((v >>  8) & 0xFF) / 255
    let b = Double( v        & 0xFF) / 255
    return Color(red: r, green: g, blue: b)
  }
}

// MARK: - Caffeine presets (read-only)

private struct CaffeinePresetsPane: View {
  @Environment(SettingsStore.self) private var store

  var body: some View {
    Form {
      if let caf = store.caffeine {
        if !caf.beans.isEmpty {
          Section("Beans") {
            ForEach(caf.beans) { bean in
              HStack {
                Text(bean.name).foregroundStyle(.primary)
                Spacer()
                Text(bean.id)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        if let methods = caf.methods, !methods.isEmpty {
          Section("Methods") {
            ForEach(methods, id: \.self) { m in
              Text(m)
            }
          }
        }
      } else {
        unavailable
      }
      readOnlyFooter
    }
    .formStyle(.grouped)
  }
}

// MARK: - Cannabis presets (read-only)

private struct CannabisPresetsPane: View {
  @Environment(SettingsStore.self) private var store

  var body: some View {
    Form {
      if let cnb = store.cannabis {
        Section("Strains") {
          ForEach(cnb.strains) { st in
            HStack {
              Text(st.name).foregroundStyle(.primary)
              Spacer()
              Text(st.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
        }
        Section("Dosing") {
          row("Uses per capsule", "\(cnb.usesPerCapsule)")
        }
      } else {
        unavailable
      }
      readOnlyFooter
    }
    .formStyle(.grouped)
  }
}

// MARK: - Integrations
//
// Native iOS access states for the three frameworks Septena reaches
// outside the FastAPI proxy: Reminders + Calendar (EventKit) and Apple
// Health (HealthKit). The Reminders row pushes to a detail screen
// with source-list picker + auto-import controls when access is granted;
// Calendar and Health are state-only rows (no per-integration config yet).

struct IntegrationsSettingsPane: View {
  @State private var remindersBridge = RemindersBridge.shared
  @State private var calendarBridge = CalendarBridge.shared
  @State private var healthBridge = HealthKitBridge.shared

  var body: some View {
    Form {
      Section {
        NavigationLink {
          RemindersInboxDetail()
            .navigationTitle("Reminders")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Reminders",
                   systemImage: "checklist",
                   state: remindersAccessLabel,
                   isGranted: remindersBridge.access == .granted)
        }

        grantButton(
          title: "Calendar",
          systemImage: "calendar",
          state: calendarAccessLabel,
          isGranted: calendarBridge.access == .granted,
          canRequest: calendarBridge.access == .notDetermined
        ) {
          Task { _ = await calendarBridge.requestAccess() }
        }

        grantButton(
          title: "Apple Health",
          systemImage: "heart.text.square",
          state: healthAccessLabel,
          isGranted: healthBridge.access == .granted,
          canRequest: healthBridge.access == .notDetermined && healthBridge.isAvailable
        ) {
          Task { _ = await healthBridge.requestAccess() }
        }
      } footer: {
        Text("Grant access here, or manage permissions in iOS Settings → Privacy.")
      }
    }
    .formStyle(.grouped)
  }

  private func stateRow(title: String,
                        systemImage: String,
                        state: String,
                        isGranted: Bool) -> some View {
    HStack {
      Label(title, systemImage: systemImage)
        .foregroundStyle(.primary)
      Spacer()
      Text(state)
        .font(.subheadline)
        .foregroundStyle(isGranted ? Color.green : .secondary)
    }
  }

  @ViewBuilder
  private func grantButton(title: String,
                           systemImage: String,
                           state: String,
                           isGranted: Bool,
                           canRequest: Bool,
                           onTap: @escaping () -> Void) -> some View {
    if canRequest {
      Button(action: onTap) {
        stateRow(title: title, systemImage: systemImage, state: state, isGranted: isGranted)
      }
      .buttonStyle(.plain)
    } else {
      stateRow(title: title, systemImage: systemImage, state: state, isGranted: isGranted)
    }
  }

  private var remindersAccessLabel: String {
    switch remindersBridge.access {
    case .granted:       return "Granted"
    case .writeOnly:     return "Write-only"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }

  private var calendarAccessLabel: String {
    switch calendarBridge.access {
    case .granted:       return "Granted"
    case .writeOnly:     return "Write-only"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }

  private var healthAccessLabel: String {
    guard healthBridge.isAvailable else { return "Not available" }
    switch healthBridge.access {
    case .granted:       return "Granted"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }
}

// MARK: - Reminders → Inbox detail
//
// Reached from Integrations → Reminders. Permission grant + source list
// + auto-import all live here, since this is where the user actually
// configures the Reminders → Septena Inbox bridge.

private struct RemindersInboxDetail: View {
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
  @Environment(SettingsStore.self) private var store
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
    Task {
      await theme.refresh(from: ClientProvider.shared.client)
      await store.refresh(from: ClientProvider.shared.client)
    }
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

// MARK: - Shared pane helpers

private func row(_ label: String, _ value: String) -> some View {
  HStack {
    Text(label)
    Spacer()
    Text(value)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.trailing)
  }
}

@ViewBuilder
private var unavailable: some View {
  Section {
    ContentUnavailableView("Couldn't load settings",
                           systemImage: "gear",
                           description: Text("Check the backend connection."))
  }
}

@ViewBuilder
private var readOnlyFooter: some View {
  Section {
    EmptyView()
  } footer: {
    Text("These values are configured server-side. Editing is not available in the app yet.")
  }
}
