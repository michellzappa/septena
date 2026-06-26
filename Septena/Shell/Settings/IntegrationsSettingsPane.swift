import SwiftUI
import SwiftData
import EventKit
import CloudKit
import CoreLocation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

struct IntegrationsSettingsPane: View {
  var body: some View {
    Form {
      ConnectedAppsSettingsSections()
    }
    .formStyle(.grouped)
  }
}

struct ConnectedAppsSettingsSections: View {
  @State private var remindersBridge = RemindersBridge.shared
  @State private var calendarBridge = CalendarBridge.shared
  @State private var healthBridge = HealthKitBridge.shared
  @State private var ouraProvider = OuraProvider.shared
  @State private var withingsProvider = WithingsProvider.shared
  @State private var githubProvider = GitHubProvider.shared
  @State private var readwiseProvider = ReadwiseProvider.shared
  @State private var photosBridge = PhotosBridge.shared

  var body: some View {
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

      NavigationLink {
        ThingsImportView()
      } label: {
        stateRow(title: "Things",
                 systemImage: "square.and.arrow.down",
                 state: "One-time import",
                 isGranted: true)
      }

      NavigationLink {
        CalendarDetail()
          .navigationTitle("Calendar")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
      } label: {
        stateRow(title: "Calendar",
                 systemImage: "calendar",
                 state: calendarAccessLabel,
                 isGranted: calendarBridge.access == .granted)
      }

      NavigationLink {
        AppleHealthDetail()
          .navigationTitle("Apple Health")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
      } label: {
        stateRow(title: "Apple Health",
                 systemImage: "heart.text.square",
                 state: healthAccessLabel,
                 isGranted: healthBridge.access == .granted)
      }

      // Photos — used to attach thumbnails to nutrition (meal) entries.
      // Access is requested lazily by the picker too, but surfacing it
      // here gives denied users a fix path (and a way to grant up front).
      NavigationLink {
        PhotosDetail()
          .navigationTitle("Photos")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
      } label: {
        stateRow(title: "Photos",
                 systemImage: "photo",
                 state: photosAccessLabel,
                 isGranted: photosBridge.access == .granted)
      }

      // Siri & Shortcuts — Apple system integration; grouped here with
      // the other Apple ones rather than as a top-level Settings row.
      NavigationLink {
        SiriShortcutsSettingsPane()
          .navigationTitle("Siri & Shortcuts")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
      } label: {
        Label("Siri & Shortcuts", systemImage: "mic")
          .foregroundStyle(.primary)
      }

    } header: {
      Text("Apple")
    } footer: {
      Text("Grant access here, or manage permissions in iOS Settings → Privacy.")
    }

    Section {
      // Oura — direct iOS client (Personal Access Token). Replaces the
      // old FastAPI proxy at /api/health/oura.
      NavigationLink {
        OuraIntegrationDetail()
          .navigationTitle("Oura")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
      } label: {
        stateRow(title: "Oura",
                 systemImage: "circle.circle",
                 state: ouraProvider.hasToken ? "Connected" : "Grant",
                 isGranted: ouraProvider.hasToken)
      }

      // Withings — direct iOS client (OAuth2). Replaces the old
      // FastAPI proxy at /api/health/withings.
      NavigationLink {
        WithingsIntegrationDetail()
          .navigationTitle("Withings")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
      } label: {
        stateRow(title: "Withings",
                 systemImage: "scalemass",
                 state: withingsProvider.hasTokens ? "Connected" : "Connect",
                 isGranted: withingsProvider.hasTokens)
      }

      // GitHub — read-only contribution calendar via the GraphQL API.
      // Static token (Keychain); syncs across the user's devices via iCloud
      // Keychain, never to CloudKit or a Septena server.
      NavigationLink {
        GitHubIntegrationDetail()
          .navigationTitle("GitHub")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
      } label: {
        stateRow(title: "GitHub",
                 systemImage: "chevron.left.forwardslash.chevron.right",
                 state: githubProvider.hasToken ? "Connected" : "Connect",
                 isGranted: githubProvider.hasToken)
      }

      NavigationLink {
        ReadwiseConnectView()
          .navigationTitle("Readwise")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
      } label: {
        stateRow(title: "Readwise",
                 systemImage: "highlighter",
                 state: readwiseProvider.hasToken ? "Connected" : "Connect",
                 isGranted: readwiseProvider.hasToken)
      }

    } header: {
      Text("Services")
    } footer: {
      Text("Service tokens live in your Keychain and are never sent to any Septena server. Oura, GitHub, and Readwise sync across your devices via iCloud Keychain (end-to-end encrypted); Withings stays on this device.")
    }
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

  private var photosAccessLabel: String {
    switch photosBridge.access {
    case .granted:       return "Granted"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }
}

// MARK: - Apple Health Detail

/// Full-screen integration settings for Apple Health. Shown after tapping the
/// Apple Health row in Integrations. Handles the initial grant request and
/// per-section write toggles — each toggle syncs through CloudKit so the
/// user's preference follows them across devices.
struct AppleHealthDetail: View {
  @Environment(\.modelContext)    private var modelContext
  @Environment(CKEngine.self)     private var ckEngine
  @Environment(SettingsStore.self) private var store
  @State private var healthBridge = HealthKitBridge.shared

  private var rows: [(label: String, icon: String, kind: HealthKitBridge.WritableKind)] {
    [
      ("Mood",                  "face.smiling",                          .mood),
      ("Nutrition & Hydration", "fork.knife",                            .nutrition),
    ]
  }

  /// True when at least one writable category was denied in the permission
  /// sheet — drives the "some categories are off" advisory.
  private var anyDenied: Bool {
    rows.contains { healthBridge.shareStatus($0.kind) == .denied }
  }

  var body: some View {
    Form {
      // ── Connection ─────────────────────────────────────────────────────
      Section {
        if !healthBridge.isAvailable {
          Label("Apple Health is not available on this device.",
                systemImage: "heart.slash")
            .foregroundStyle(.secondary)
        } else if healthBridge.hasRequestedWrite {
          Label("Connected", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          Button {
            Task { _ = await healthBridge.requestAccess() }
          } label: {
            Label("Connect Apple Health", systemImage: "heart.text.square")
          }
        }
      } footer: {
        Text("Septena writes your logged data to Apple Health so it appears alongside data from your other apps and devices.")
      }

      // ── Write Toggles (shown once the user has been through the sheet) ───
      if healthBridge.isAvailable && healthBridge.hasRequestedWrite {
        Section {
          ForEach(rows, id: \.kind) { row in
            toggleRow(row.label, row.icon, row.kind)
          }
        } header: {
          Text("Write to Health")
        } footer: {
          if anyDenied {
            Text("Some categories are turned off in Apple Health. To allow them, open Health → Profile → Apps → Septena. New entries are sent going forward — existing ones aren't back-filled.")
          } else {
            Text("New entries you log in Septena will be sent to Apple Health. Existing entries are not back-filled.")
          }
        }
      }
    }
    .navigationTitle("Apple Health")
    // Re-request on every visit so any write types added since the user's
    // last authorization are picked up immediately. HealthKit only shows a
    // sheet for types not yet resolved — no-ops if everything is already
    // decided. Always refresh status afterward so denials render correctly.
    .task {
      if healthBridge.isAvailable {
        _ = await healthBridge.requestAccess()
        healthBridge.refreshShareStatuses()
      }
    }
  }

  /// One row in the write-toggles section. Enabled when the category is
  /// authorized; when denied, the toggle is disabled and a caption explains
  /// that Apple Health is blocking it (so the failure is never silent).
  @ViewBuilder
  private func toggleRow(_ title: String, _ icon: String,
                         _ kind: HealthKitBridge.WritableKind) -> some View {
    let status = healthBridge.shareStatus(kind)
    if status != .unavailable {
      Toggle(isOn: syncBinding(kind)) {
        VStack(alignment: .leading, spacing: 2) {
          Label(title, systemImage: icon)
          if status == .denied {
            Text("Turned off in Apple Health")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .disabled(status != .authorized)
    }
  }

  private func keyPath(for kind: HealthKitBridge.WritableKind) -> WritableKeyPath<HKSyncSettings, Bool> {
    switch kind {
    case .mood:      return \.mood
    case .nutrition: return \.nutrition
    }
  }

  /// Binding that reads/writes one field of `HKSyncSettings` through the
  /// CloudKit-backed `AppSettings`. Falls back to `true` (all-on default)
  /// when no settings are stored yet.
  private func syncBinding(_ kind: HealthKitBridge.WritableKind) -> Binding<Bool> {
    let keyPath = keyPath(for: kind)
    return Binding {
      store.serverSettings?.hkSync?[keyPath: keyPath] ?? true
    } set: { newValue in
      var s = store.serverSettings ?? AppSettings(sectionOrder: nil, targets: nil,
                                                  units: nil, time: nil, theme: nil,
                                                  eink: nil, nutrition: nil, hkSync: nil)
      var hk = s.hkSync ?? HKSyncSettings()
      hk[keyPath: keyPath] = newValue
      s.hkSync = hk
      store.serverSettings = s
      HealthKitBridge.shared.syncSettings = hk
      SettingsMirror.upsert(settings: s, context: modelContext, engine: ckEngine)
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
            .scaledFont(size: 13, weight: .semibold)
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

// MARK: - Calendar detail
//
// Reached from Integrations → Calendar. Lists every event calendar EventKit
// exposes and lets the user toggle visibility per source. Hidden calendars
// drop out of CalendarBridge's fetch helpers, so both the day timeline and
// the Next page stop showing those events.

private struct CalendarDetail: View {
  @Environment(\.modelContext)    private var modelContext
  @Environment(CKEngine.self)     private var ckEngine
  @Environment(SettingsStore.self) private var store
  @State private var bridge = CalendarBridge.shared
  @State private var access: CalendarBridge.Access = .notDetermined
  @State private var calendars: [EKCalendar] = []

  var body: some View {
    Form {
      Section {
        Text("Pick which calendars contribute events to your day timeline and Next page. Hidden calendars stay untouched in iOS Calendar.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      switch access {
      case .notDetermined:
        Section {
          Button("Grant Access to Calendar") {
            Task {
              _ = await bridge.requestAccess()
              refresh()
            }
          }
        }
      case .denied, .writeOnly:
        Section {
          Text(access == .writeOnly
               ? "Septena has write-only access. Enable Full Access in Settings → Privacy → Calendars."
               : "Calendar access is denied. Enable it in Settings → Privacy → Calendars.")
            .font(.callout)
        }
      case .granted:
        if calendars.isEmpty {
          Section {
            Text("No calendars found.")
              .foregroundStyle(.secondary)
          }
        } else {
          Section("Calendars") {
            ForEach(calendars, id: \.calendarIdentifier) { cal in
              calendarRow(cal)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
  }

  private func calendarRow(_ cal: EKCalendar) -> some View {
    Toggle(isOn: Binding(
      get: { !bridge.isHidden(cal) },
      set: { store.setCalendarHidden(!$0, title: cal.title,
                                     context: modelContext, engine: ckEngine) }
    )) {
      HStack(spacing: 10) {
        Circle()
          .fill(Color(cgColor: cal.cgColor))
          .frame(width: 10, height: 10)
        VStack(alignment: .leading, spacing: 2) {
          Text(cal.title)
            .foregroundStyle(.primary)
          if let source = cal.source?.title, !source.isEmpty {
            Text(source)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func refresh() {
    access = bridge.access
    if access == .granted {
      calendars = bridge.allCalendars()
    }
  }
}

// MARK: - Photos Detail
//
// Photo access is used to attach thumbnails to nutrition (meal) entries.
// When access is denied, meal thumbnails silently fall back to a
// placeholder — this screen explains why and points to iOS Settings.
private struct PhotosDetail: View {
  @State private var bridge = PhotosBridge.shared
  @State private var access: PhotosBridge.Access = .notDetermined

  var body: some View {
    Form {
      Section {
        Text("Septena attaches photos to your meal entries and shows their thumbnails in your nutrition log. Photos stay on your device.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      switch access {
      case .notDetermined:
        Section {
          Button("Grant Access to Photos") {
            Task {
              _ = await bridge.requestAccess()
              refresh()
            }
          }
        }
      case .denied:
        Section {
          Text("Photo access is denied. Enable it in Settings → Privacy → Photos. Meal thumbnails won't show until then.")
            .font(.callout)
        }
      case .granted:
        Section {
          Label("Connected", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
  }

  private func refresh() {
    access = bridge.access
  }
}

// Oura → Personal Access Token entry. The user pastes a token from
// cloud.ouraring.com/personal-access-tokens; OuraProvider stores it in
// Keychain. Test button does a 1-day fetchHistory round-trip so the
// user gets immediate confirmation the token works.
private struct OuraIntegrationDetail: View {
  @State private var provider = OuraProvider.shared
  @State private var draft: String = ""
  @State private var testing = false
  @State private var lastResult: String? = nil

  var body: some View {
    Form {
      Section {
        SecureField("Personal Access Token", text: $draft)
          #if os(iOS)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          #endif
        HStack {
          Button("Save") {
            provider.setToken(draft)
            draft = ""
            lastResult = nil
            // Kick off a full one-year backfill so the user's history
            // lands in SwiftData + CloudKit immediately, not after the
            // next dashboard visit.
            Task { await runBackfill() }
          }
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Spacer()
          if provider.hasToken {
            Button("Remove", role: .destructive) {
              provider.clearToken()
              lastResult = nil
            }
          }
        }
      } header: {
        Text("Token")
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text("Create a Personal Access Token at cloud.ouraring.com/personal-access-tokens, then paste it here. The token is kept in your Keychain, syncs to your other devices via iCloud Keychain, and is never sent to any Septena server.")
          Link("Open Oura tokens page",
               destination: URL(string: "https://cloud.ouraring.com/personal-access-tokens")!)
            .font(.callout)
        }
      }

      Section {
        HStack {
          Label("Status", systemImage: "circle.circle")
          Spacer()
          Text(provider.hasToken ? "Connected" : "Not configured")
            .foregroundStyle(provider.hasToken ? .green : .secondary)
        }
        Button {
          Task { await runTest() }
        } label: {
          HStack {
            Label("Test connection", systemImage: "checkmark.seal")
            Spacer()
            if testing { ProgressView().controlSize(.small) }
          }
        }
        .disabled(!provider.hasToken || testing)
        if let lastResult {
          Text(lastResult)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func runTest() async {
    testing = true
    defer { testing = false }
    do {
      let rows = try await provider.fetchHistory(days: 7)
      let withScore = rows.compactMap(\.sleepScore).count
      lastResult = "OK — \(rows.count) days fetched, \(withScore) with a sleep score."
    } catch {
      lastResult = "Failed: \(error.localizedDescription)"
    }
  }

  private func runBackfill() async {
    testing = true
    defer { testing = false }
    lastResult = "Backfilling last 365 days…"
    do {
      let rows = try await provider.fetchHistory(days: 365)
      let withScore = rows.compactMap(\.sleepScore).count
      lastResult = "Backfill complete — \(rows.count) nights, \(withScore) with a sleep score. Syncing to iCloud."
    } catch {
      lastResult = "Backfill failed: \(error.localizedDescription)"
    }
  }
}

// GitHub → personal access token entry. The user pastes a token with the
// `read:user` scope from github.com/settings/tokens; GitHubProvider stores
// it in Keychain (never CloudKit, never a Septena server). Test button does
// a contributions round-trip so the user gets immediate confirmation.
private struct GitHubIntegrationDetail: View {
  @State private var provider = GitHubProvider.shared
  @State private var draft: String = ""
  @State private var testing = false
  @State private var lastResult: String? = nil

  var body: some View {
    Form {
      Section {
        SecureField("Access Token", text: $draft)
          #if os(iOS)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          #endif
        HStack {
          Button("Save") {
            provider.setToken(draft)
            draft = ""
            lastResult = nil
            // Immediately validate so the user sees the token works (and
            // warms the dashboard cache via the destination's own fetch).
            Task { await runTest() }
          }
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Spacer()
          if provider.hasToken {
            Button("Remove", role: .destructive) {
              provider.clearToken()
              lastResult = nil
            }
          }
        }
      } header: {
        Text("Token")
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text("Create a personal access token with the read:user scope at github.com/settings/tokens, then paste it here. The token is kept in your Keychain, syncs to your other devices via iCloud Keychain, and is never sent to any Septena server.")
          Link("Open GitHub tokens page",
               destination: URL(string: "https://github.com/settings/tokens")!)
            .font(.callout)
        }
      }

      Section {
        HStack {
          Label("Status", systemImage: "chevron.left.forwardslash.chevron.right")
          Spacer()
          Text(provider.hasToken ? "Connected" : "Not configured")
            .foregroundStyle(provider.hasToken ? .green : .secondary)
        }
        Button {
          Task { await runTest() }
        } label: {
          HStack {
            Label("Test connection", systemImage: "checkmark.seal")
            Spacer()
            if testing { ProgressView().controlSize(.small) }
          }
        }
        .disabled(!provider.hasToken || testing)
        if let lastResult {
          Text(lastResult)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func runTest() async {
    testing = true
    defer { testing = false }
    do {
      let c = try await provider.fetchContributions(days: 365)
      lastResult = "OK — \(c.total) contributions for @\(c.login) in the last year."
    } catch {
      lastResult = "Failed: \(error.localizedDescription)"
    }
  }
}

// MARK: - Claude Gateway Detail

/// Connect / status / disconnect for the Septena MCP gateway. "Connect"
/// mints a CloudKit Web Services token and pushes it to mcp.septena.app;
/// the app then re-mints on foreground so Claude keeps working without
/// the user re-authorizing every ~8h. The gateway holds only the rotating
/// token, never the user's data.
struct ClaudeGatewayDetail: View {
  @State private var provider = ClaudeGatewayProvider.shared
  @State private var urlCopied = false

  /// The exact custom-connector address Claude expects (the JSON-RPC MCP
  /// transport endpoint). NOT the bare domain — Claude needs the `/mcp` path.
  private static let connectorURL = "https://mcp.septena.app/mcp"

  var body: some View {
    Form {
      Section {
        if provider.isEnabled {
          Button("Disconnect", role: .destructive) {
            provider.disconnect()
          }
        } else {
          Button("Connect Claude") {
            Task { await provider.connect() }
          }
        }
      } footer: {
        Text("Connecting lets Claude (at claude.ai or in the Claude app) read and write your Septena data via the MCP connector. Your data stays in iCloud — the gateway only relays a short-lived access token, which this app refreshes automatically. Use the address below to add the connector in Claude.")
      }

      Section {
        Button {
          SkillCopy.copy(Self.connectorURL)
          withAnimation { urlCopied = true }
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { urlCopied = false }
          }
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "link").font(.body).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
              Text("Connector address")
              Text(Self.connectorURL)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: urlCopied ? "checkmark.circle.fill" : "doc.on.doc")
              .foregroundStyle(urlCopied ? .green : .secondary)
          }
        }
        .buttonStyle(.plain)
      } header: {
        Text("Add to Claude")
      } footer: {
        Text("In Claude — claude.ai → Settings → Connectors, or the Claude app — add a custom connector and paste this address. You'll be asked to sign in with your Apple ID once to authorize access to your private iCloud data.")
      }

      if provider.isEnabled {
        Section {
          HStack {
            Label("Status", systemImage: "antenna.radiowaves.left.and.right")
            Spacer()
            Text(provider.needsReauth ? "Reconnect needed" : (provider.lastError == nil ? "Connected" : "Needs attention"))
              .foregroundStyle(provider.needsReauth || provider.lastError != nil ? .orange : .green)
          }
          if let last = provider.lastRefreshAt {
            ClaudeConnectionTimer(lastRefreshAt: last, dueAt: provider.nudgeFireDate)
          } else {
            HStack {
              Label("Last authenticated", systemImage: "clock.arrow.circlepath")
              Spacer()
              Text("Never").foregroundStyle(.secondary)
            }
          }
          Button {
            Task { await provider.refreshNow() }
          } label: {
            HStack {
              Label("Reauthenticate", systemImage: "lock.rotation")
              Spacer()
              if provider.isRefreshing { ProgressView().controlSize(.small) }
            }
          }
          .disabled(provider.isRefreshing)
          if let err = provider.lastError {
            Text(err)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("Connection")
        }
      }

      Section {
        explainerRow(icon: "link",
                     title: "A small relay",
                     text: "Claude talks to Septena through a connector at mcp.septena.app. Add it in Claude (claude.ai or the Claude app) using that address.")
        explainerRow(icon: "lock.icloud",
                     title: "Your data stays private",
                     text: "Reads and writes go straight to your own private iCloud database. The relay never stores your data — it only passes a short-lived access token through.")
        explainerRow(icon: "text.bubble",
                     title: "Ask in plain language",
                     text: "Claude can read and log your tasks, habits, supplements, meals, training and more, just by you asking.")
        explainerRow(icon: "arrow.triangle.2.circlepath",
                     title: "Syncs everywhere",
                     text: "Anything Claude logs shows up across all your devices automatically.")
      } header: {
        Text("How it works")
      } footer: {
        Text("Good to know: Apple only issues short-lived keys for private iCloud data — a few hours, with no server-side renewal. So Septena refreshes the connection automatically when you open the app, and the “Keep Claude connected” reminder nudges you before it lapses. If it does lapse, Claude simply asks you to open Septena to refresh — you won't need to reconnect from claude.ai, and it resumes on its own. Refreshing happens on iPhone and Mac only, not the watch.")
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private func explainerRow(icon: String, title: String, text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(width: 24, alignment: .center)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.medium))
        Text(text).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }
}

// Live "time since last connected" + countdown to the auto-refresh horizon.
// `TimelineView` ticks the labels without any manual timer; it stops when the
// pane is offscreen. The "due" line keys off `nudgeFireDate` (lastRefreshAt +
// ~7h) — the same horizon that flips `needsReauth` and arms the reconnect
// nudge — so the number the user sees here matches what the app acts on.
private struct ClaudeConnectionTimer: View {
  let lastRefreshAt: Date
  let dueAt: Date?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { ctx in
      let now = ctx.date
      HStack(alignment: .firstTextBaseline) {
        Label("Connected", systemImage: "clock.arrow.circlepath")
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text("\(Self.compact(now.timeIntervalSince(lastRefreshAt))) ago")
            .foregroundStyle(.secondary)
            .monospacedDigit()
          dueLine(now: now)
        }
      }
    }
  }

  @ViewBuilder
  private func dueLine(now: Date) -> some View {
    if let dueAt {
      let remaining = dueAt.timeIntervalSince(now)
      if remaining > 0 {
        Text("auto-refresh in \(Self.compact(remaining))")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else {
        Text("refresh recommended")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  /// "2h 14m", "46m 03s", "12s" — drops to finer units as the value shrinks so
  /// the trailing digits visibly tick.
  static func compact(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return String(format: "%dm %02ds", m, s) }
    return "\(s)s"
  }
}

// Withings → OAuth2 connect / backfill / disconnect. "Connect" opens
// ASWebAuthenticationSession against account.withings.com; the returned
// code is exchanged for access + refresh tokens stored in Keychain.
// Backfill pulls the last 365 days into SwiftData + CloudKit so other
// devices pick them up via CKSyncEngine.
private struct WithingsIntegrationDetail: View {
  @State private var provider = WithingsProvider.shared
  @State private var working = false
  @State private var lastResult: String? = nil

  var body: some View {
    Form {
      if !provider.isConfigured {
        Section {
          Text("Withings app credentials are not configured.")
            .foregroundStyle(.secondary)
        } footer: {
          Text("Register a Withings dev app at developer.withings.com (Public Health Data API), then add your client_id and client_secret to Config/Secrets.xcconfig (copy it from Config/Secrets.example.xcconfig) and rebuild. The redirect URI should be septena://withings/callback.")
        }
      }

      Section {
        HStack {
          Label("Status", systemImage: "scalemass")
          Spacer()
          Text(provider.hasTokens ? "Connected" : "Not connected")
            .foregroundStyle(provider.hasTokens ? .green : .secondary)
        }

        if provider.hasTokens {
          Button {
            Task { await runBackfill() }
          } label: {
            HStack {
              Label("Backfill last 365 days", systemImage: "arrow.clockwise")
              Spacer()
              if working { ProgressView().controlSize(.small) }
            }
          }
          .disabled(working)
          Button("Disconnect", role: .destructive) {
            provider.disconnect()
            lastResult = nil
          }
          .disabled(working)
        } else {
          Button {
            Task { await runConnect() }
          } label: {
            HStack {
              Label("Connect Withings", systemImage: "link")
              Spacer()
              if working { ProgressView().controlSize(.small) }
            }
          }
          .disabled(!provider.isConfigured || working)
        }

        if let lastResult {
          Text(lastResult)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } footer: {
        Text("Tokens live in this device's Keychain and never leave it. Weigh-ins sync to your other devices via iCloud.")
      }
    }
    .formStyle(.grouped)
  }

  private func runConnect() async {
    working = true
    defer { working = false }
    lastResult = "Opening Withings sign-in…"
    do {
      try await provider.connect()
      lastResult = "Connected. Backfilling last 365 days…"
      let rows = try await provider.fetchHistory(days: 365)
      lastResult = "Connected — \(rows.count) days fetched. Syncing to iCloud."
    } catch {
      lastResult = "Failed: \(error.localizedDescription)"
    }
  }

  private func runBackfill() async {
    working = true
    defer { working = false }
    lastResult = "Backfilling last 365 days…"
    do {
      let rows = try await provider.fetchHistory(days: 365)
      lastResult = "Backfill complete — \(rows.count) days, syncing to iCloud."
    } catch {
      lastResult = "Backfill failed: \(error.localizedDescription)"
    }
  }
}

// MARK: - About
