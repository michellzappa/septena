import SwiftUI
import EventKit

// Settings screen: choose which Apple Reminders list mirrors into the Septena
// Inbox. Picking a list is the only action here — actual import happens in the
// Inbox itself, where reminders render as task-style rows.

struct RemindersImportView: View {
  @EnvironmentObject var theme: SectionTheme
  @StateObject private var bridge = RemindersBridge.shared

  @State private var access: RemindersBridge.Access = .notDetermined
  @State private var lists: [EKCalendar] = []
  @State private var selectedID: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ScreenTitle(icon: "checklist", iconTint: Theme.inkSecondary,
                    title: "Reminders Source")

        Text("Pick a Reminders list. Its pending items will show in your Inbox; tap to import (originals are removed from Reminders).")
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
          .padding(.horizontal, Theme.hPadding)
          .padding(.bottom, Theme.sectionSpacing)

        switch access {
        case .notDetermined:
          permissionPrompt
        case .denied, .writeOnly:
          deniedPrompt
        case .granted:
          listPicker
        }

        Spacer(minLength: 24)
      }
    }
    .background(Theme.paperBackground)
    .septenaInlineTitle()
    .onAppear { refresh() }
  }

  // MARK: - States

  @ViewBuilder
  private var permissionPrompt: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Septena needs access to read your Reminders.")
        .font(.septenaTaskTitle)
        .foregroundStyle(Theme.inkPrimary)
      Button {
        Task {
          _ = await bridge.requestAccess()
          refresh()
        }
      } label: {
        Text("Grant Access")
          .font(.septenaButton)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
          .background(theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, Theme.hPadding)
  }

  @ViewBuilder
  private var deniedPrompt: some View {
    Text(access == .writeOnly
         ? "Septena has write-only access. Enable Full Access in Settings → Privacy → Reminders."
         : "Reminders access is denied. Enable it in Settings → Privacy → Reminders.")
      .font(.septenaTaskTitle)
      .foregroundStyle(Theme.inkPrimary)
      .padding(.horizontal, Theme.hPadding)
  }

  @ViewBuilder
  private var listPicker: some View {
    VStack(spacing: 0) {
      // "None" row — disable mirroring.
      pickerRow(title: "None", tint: nil, id: nil)
      Hairline().padding(.horizontal, Theme.hPadding)
      ForEach(lists, id: \.calendarIdentifier) { cal in
        pickerRow(title: cal.title,
                  tint: Color(cgColor: cal.cgColor),
                  id: cal.calendarIdentifier)
      }
    }
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
          Circle().stroke(Theme.iconMuted, lineWidth: 1).frame(width: 10, height: 10)
        }
        Text(title)
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkPrimary)
        Spacer()
        if selectedID == id {
          Image(systemName: "checkmark")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.accent)
        }
      }
      .padding(.vertical, 12)
      .padding(.horizontal, Theme.hPadding)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Refresh

  private func refresh() {
    access = bridge.access
    if access == .granted {
      lists = bridge.reminderLists()
      selectedID = bridge.sourceListID
    }
  }
}
