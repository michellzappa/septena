// Connected-apps detail panes shared by both shells (docs/SEPTASK.md):
// Reminders inbox import and calendar visibility. Extracted from
// IntegrationsSettingsPane.swift so Septask's Settings can offer the same
// management UI without compiling the full Integrations surface — the
// bridges themselves (RemindersBridge, CalendarBridge) live in SeptenaCore.

import SwiftUI
import SwiftData
import EventKit

struct RemindersInboxDetail: View {
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

struct CalendarDetail: View {
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
