import SwiftUI

struct QuickEntryView: View {
  @EnvironmentObject var client: SeptenaClient
  @EnvironmentObject var theme: SectionTheme
  @Environment(\.dismiss) private var dismiss

  @State private var title = ""
  @State private var notes = ""
  /// The When-picker target: `scheduled` (or nil + isSomeday for the Someday bucket).
  @State private var scheduledDate: Date?
  @State private var isSomeday = false
  @State private var selectedProjectId: String?
  @State private var selectedAreaId: String?
  @State private var showingWhenSheet = false
  @State private var showingMoveSheet = false
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  @State private var projects: [Project] = []
  @State private var areas: [Area] = []
  @FocusState private var titleFocused: Bool

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ScreenTitle(icon: "plus", iconTint: theme.accent, title: "New Task")

          // Title + notes — same card chrome as InlineEditTaskRow
          VStack(alignment: .leading, spacing: 6) {
            TextField("What needs to be done?", text: $title)
              .font(.septenaTaskTitle)
              .foregroundStyle(Theme.inkPrimary)
              .focused($titleFocused)
              .submitLabel(.next)
            TextField("Notes", text: $notes, axis: .vertical)
              .font(.septenaNotes)
              .foregroundStyle(Theme.inkSecondary)
              .lineLimit(2...6)
          }
          .padding(14)
          .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
          .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
              .stroke(Theme.border, lineWidth: 1)
          )
          .padding(.horizontal, 8)

          // Picker chips
          HStack(spacing: 8) {
            Button { showingWhenSheet = true } label: {
              chip(icon: "calendar",
                   text: whenChipLabel,
                   tint: (scheduledDate == nil && !isSomeday) ? Theme.inkSecondary : Theme.inkPrimary)
            }
            .buttonStyle(.plain)

            Button { showingMoveSheet = true } label: {
              chip(icon: targetIcon, text: targetLabel,
                   tint: (selectedProjectId ?? selectedAreaId) == nil
                         ? Theme.inkSecondary : Theme.inkPrimary)
            }
            .buttonStyle(.plain)
            Spacer()
          }
          .padding(.horizontal, Theme.hPadding)
          .padding(.top, 14)

          if let error = errorMessage {
            Text(error)
              .font(.septenaMeta)
              .foregroundStyle(Theme.overdueRed)
              .padding(.horizontal, Theme.hPadding)
              .padding(.top, 12)
          }

          Spacer(minLength: 40)
        }
      }
      .background(Theme.paperBackground)
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.tint(theme.accent)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") { submit() }
            .font(.septenaButton)
            .tint(theme.accent)
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
        }
      }
      .sheet(isPresented: $showingWhenSheet) {
        WhenPickerSheet(
          onPick: { date in scheduledDate = date; isSomeday = false },
          onSomeday: { scheduledDate = nil; isSomeday = true }
        )
        .presentationDetents([.medium])
      }
      .sheet(isPresented: $showingMoveSheet) {
        MovePickerSheet(areas: areas, projects: projects) { areaId, projectId in
          selectedAreaId = areaId
          selectedProjectId = projectId
        }
        .presentationDetents([.medium, .large])
      }
      .task {
        do {
          async let p = client.projects()
          async let a = client.areas()
          projects = try await p
          areas = try await a
        } catch {}
        titleFocused = true
      }
    }
    .presentationDetents([.medium, .large])
    .interactiveDismissDisabled(isSubmitting)
  }

  private var targetIcon: String {
    if selectedProjectId != nil { return "number" }
    if selectedAreaId != nil { return "folder" }
    return "tray"
  }

  @ViewBuilder
  private func chip(icon: String, text: String, tint: Color) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon).font(.system(size: 11))
      Text(text).font(.septenaMeta)
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Theme.mutedSurface, in: Capsule())
  }

  private var whenChipLabel: String {
    if isSomeday { return "Someday" }
    if let d = scheduledDate { return dateLabel(d) }
    return "When"
  }

  private var targetLabel: String {
    if let pid = selectedProjectId, let p = projects.first(where: { $0.id == pid }) {
      return p.title
    }
    if let aid = selectedAreaId, let a = areas.first(where: { $0.id == aid }) {
      return a.title
    }
    return "Inbox"
  }

  private func dateLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    let f = DateFormatter()
    f.dateFormat = "EEE, MMM d"
    return f.string(from: d)
  }

  private func submit() {
    guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    Haptics.tick()
    isSubmitting = true
    errorMessage = nil
    Task {
      do {
        // Quick entry's "When" sets `scheduled` (reference rule). Natural-language
        // dates parsed from the title go to scheduled too. Deadlines are added
        // later from the task detail. Someday is a status, not a date.
        var scheduled = scheduledDate
        if scheduled == nil && !isSomeday { scheduled = EngageDateParser.parse(title) }
        _ = try await client.create(
          title: title.trimmingCharacters(in: .whitespaces),
          area: selectedAreaId,
          project: selectedProjectId,
          scheduled: isSomeday ? nil : scheduled,
          due: nil,
          today: false,
          notes: notes.isEmpty ? nil : notes,
          status: isSomeday ? .someday : .open
        )
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        isSubmitting = false
      }
    }
  }
}
