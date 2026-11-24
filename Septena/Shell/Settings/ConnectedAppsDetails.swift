// Connected-apps detail panes shared by both shells (docs/SEPTASK.md):
// Reminders inbox import and calendar visibility. Extracted from
// IntegrationsSettingsPane.swift so Septask's Settings can offer the same
// management UI without compiling the full Integrations surface — the
// bridges themselves (RemindersBridge, CalendarBridge) live in SeptenaCore.

import SwiftUI
import SwiftData
import EventKit
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct RemindersInboxDetail: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var bridge = RemindersBridge.shared
  @State private var access: RemindersBridge.Access = .notDetermined
  @State private var lists: [EKCalendar] = []
  @State private var selectedID: String?

  var body: some View {
    Form {
      Section {
        Text("Choose a Reminders list. Its pending items appear in your Inbox so you can import them (originals are removed from Reminders).")
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
               ? "\(AppDisplayName.current) has write-only access. Enable Full Access in Settings → Privacy → Reminders."
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
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { refresh() }
    }
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

struct CalendarDetail: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.modelContext)    private var modelContext
  @Environment(CKEngine.self)     private var ckEngine
  @Environment(SettingsStore.self) private var store
  @AppStorage(SettingsKey.tasksShowCalendarEvents) private var showCalendarEvents: Bool =
    RegistrySettings.Defaults.tasksShowCalendarEvents
  @State private var bridge = CalendarBridge.shared
  @State private var access: CalendarBridge.Access = .notDetermined
  @State private var calendars: [EKCalendar] = []
  @State private var icalSettings: BackendIcalFeedSettings?
  @State private var icalLoading = false
  @State private var icalBusy = false
  @State private var icalError: String?
  @State private var icalCopied = false
  @State private var confirmRotateIcal = false

  var body: some View {
    Form {
      Section {
        Toggle("Show calendar events", isOn: $showCalendarEvents)
      } footer: {
        Text("Show your calendar events in Today and Upcoming. Hidden calendars stay untouched in Calendar.")
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
               ? "\(AppDisplayName.current) has write-only access. Enable Full Access in Settings → Privacy → Calendars."
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
          .disabled(!showCalendarEvents)
        }
      }

      icalFeedSection
    }
    .formStyle(.grouped)
    .onAppear {
      refresh()
      Task { await loadIcalFeed() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        refresh()
        Task { await loadIcalFeed() }
      }
    }
    .confirmationDialog(
      RegistrySettings.copy("calendar_detail", "rotateTitle"),
      isPresented: $confirmRotateIcal,
      titleVisibility: .visible
    ) {
      Button(RegistrySettings.copy("calendar_detail", "rotate"), role: .destructive) {
        Task { await rotateIcalFeed() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(RegistrySettings.copy("calendar_detail", "rotateMessage"))
    }
  }

  @ViewBuilder
  private var icalFeedSection: some View {
    Section {
      if !TaskBackendClient.hasSession {
        Text(RegistrySettings.copy("calendar_detail", "feedSignIn"))
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        Toggle(RegistrySettings.copy("calendar_detail", "feedToggle"), isOn: Binding(
          get: { icalSettings?.enabled ?? false },
          set: { next in Task { await setIcalEnabled(next) } }
        ))
        .disabled(icalLoading || icalBusy)

        if let settings = icalSettings, settings.enabled {
          Picker(RegistrySettings.copy("calendar_detail", "include"), selection: Binding(
            get: { settings.scope },
            set: { next in Task { await setIcalScope(next) } }
          )) {
            Text(RegistrySettings.copy("calendar_detail", "scopeAll")).tag(BackendIcalScope.all)
            Text(RegistrySettings.copy("calendar_detail", "scopeTimed")).tag(BackendIcalScope.timed)
          }
          .disabled(icalBusy)

          if let webcal = settings.webcalUrl {
            VStack(alignment: .leading, spacing: 6) {
              Text(webcal)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

              HStack(spacing: 12) {
                Button(icalCopied ? "Copied" : RegistrySettings.copy("calendar_detail", "copyUrl")) {
                  copyToPasteboard(webcal)
                  icalCopied = true
                  Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    icalCopied = false
                  }
                }
                .disabled(icalBusy)

                if let url = URL(string: webcal) {
                  Link(RegistrySettings.copy("calendar_detail", "openInCalendar"), destination: url)
                }

                Spacer()

                Button(RegistrySettings.copy("calendar_detail", "rotate"), role: .destructive) {
                  confirmRotateIcal = true
                }
                .disabled(icalBusy)
              }
            }
            .padding(.vertical, 2)
          }
        }

        if let icalError {
          Text(icalError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    } header: {
      Text(RegistrySettings.copy("calendar_detail", "feedHeader"))
    } footer: {
      if TaskBackendClient.hasSession {
        Text(RegistrySettings.copy("calendar_detail", "feedFooter"))
      }
    }
  }

  private func loadIcalFeed() async {
    guard TaskBackendClient.hasSession else {
      icalSettings = nil
      icalError = nil
      return
    }
    icalLoading = true
    defer { icalLoading = false }
    do {
      icalSettings = try await TaskBackendClient.shared.getIcalFeedSettings()
      icalError = nil
    } catch {
      icalError = error.localizedDescription
    }
  }

  private func setIcalEnabled(_ enabled: Bool) async {
    icalBusy = true
    defer { icalBusy = false }
    do {
      if enabled {
        icalSettings = try await TaskBackendClient.shared.updateIcalFeedSettings(enabled: true)
      } else {
        try await TaskBackendClient.shared.disableIcalFeed()
        icalSettings = BackendIcalFeedSettings(enabled: false, scope: .all, url: nil, webcalUrl: nil, createdAt: nil)
      }
      icalError = nil
    } catch {
      icalError = error.localizedDescription
    }
  }

  private func setIcalScope(_ scope: BackendIcalScope) async {
    icalBusy = true
    defer { icalBusy = false }
    do {
      icalSettings = try await TaskBackendClient.shared.updateIcalFeedSettings(scope: scope)
      icalError = nil
    } catch {
      icalError = error.localizedDescription
    }
  }

  private func rotateIcalFeed() async {
    icalBusy = true
    defer { icalBusy = false }
    do {
      icalSettings = try await TaskBackendClient.shared.updateIcalFeedSettings(rotate: true)
      icalCopied = false
      icalError = nil
    } catch {
      icalError = error.localizedDescription
    }
  }

  private func copyToPasteboard(_ value: String) {
    #if os(macOS)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(value, forType: .string)
    #elseif canImport(UIKit)
    UIPasteboard.general.string = value
    #endif
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
