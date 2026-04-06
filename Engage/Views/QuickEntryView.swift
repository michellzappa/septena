import SwiftUI

// ─── Quick Entry View ─────────────────────────────────────────────────────────

struct QuickEntryView: View {
  @EnvironmentObject var client: AtaskClient
  @Environment(\.dismiss) private var dismiss

  @State private var title = ""
  @State private var notes = ""
  @State private var dueDate: Date?
  @State private var priority = 0
  @State private var selectedProjectId: String?
  @State private var showingWhenSheet = false
  @State private var showingMoveSheet = false
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  @State private var projects: [Project] = []
  @State private var areas: [Area] = []

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("What needs to be done?", text: $title)
            .font(.title3)
        }

        Section("Notes") {
          TextField("Add notes…", text: $notes, axis: .vertical)
            .lineLimit(2...6)
        }

        Section {
          // When — opens WhenSheet
          Button {
            showingWhenSheet = true
          } label: {
            HStack {
              Label("When", systemImage: "calendar")
              Spacer()
              if let due = dueDate {
                Text(EngageDateFormatter.relative(due))
                  .foregroundStyle(.secondary)
              } else {
                Text("Add Date")
                  .foregroundStyle(.secondary)
              }
              Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          }
          .buttonStyle(.plain)

          Divider()

          // Move — opens MoveToSheet
          Button {
            showingMoveSheet = true
          } label: {
            HStack {
              Label("Move to", systemImage: "folder")
              Spacer()
              if let projectId = selectedProjectId {
                Text("Project")
                  .foregroundStyle(.secondary)
              } else {
                Text("Inbox")
                  .foregroundStyle(.secondary)
              }
              Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          }
          .buttonStyle(.plain)
        }

        Section("Priority") {
          Picker("Priority", selection: $priority) {
            Text("None").tag(0)
            Text("Low").tag(1)
            Text("Medium").tag(2)
            Text("High").tag(3)
          }
          .pickerStyle(.segmented)
        }

        if let error = errorMessage {
          Section {
            Text(error)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("New Task")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            submit()
          }
          .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
        }
      }
      .sheet(isPresented: $showingWhenSheet) {
        WhenSheet(dueDate: $dueDate)
      }
      .sheet(isPresented: $showingMoveSheet) {
        MoveToSheet(selectedProjectId: $selectedProjectId, areas: areas, projects: projects)
      }
      .task {
        do {
          async let p = client.projectsList()
          async let a = client.areasList()
          projects = try await p
          areas = try await a
        } catch {}
      }
    }
    .presentationDetents([.medium, .large])
    .interactiveDismissDisabled(isSubmitting)
  }

  private func submit() {
    guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    isSubmitting = true
    errorMessage = nil

    Task {
      do {
        var parsedDue = dueDate
        if parsedDue == nil {
          parsedDue = EngageDateParser.parse(title)
        }
        let repeatRule = EngageDateParser.parseRepeatRule(title)

        try await client.taskCreate(
          title: title.trimmingCharacters(in: .whitespaces),
          notes: notes.isEmpty ? nil : notes,
          origin: .human,
          owner: "human",
          project: selectedProjectId,
          due: parsedDue,
          priority: priority,
          repeatRule: repeatRule
        )
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        isSubmitting = false
      }
    }
  }
}

// ─── When Sheet ────────────────────────────────────────────────────────────────

struct WhenSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var dueDate: Date?
  @State private var customDate = Date()

  private let calendar = Calendar.current

  var body: some View {
    NavigationStack {
      List {
        Section {
          Button("Today") {
            dueDate = calendar.startOfDay(for: Date())
            dismiss()
          }
          Button("Tomorrow") {
            dueDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
            dismiss()
          }
          Button("This Evening") {
            var d = Date()
            d.set(hour: 18, minute: 0, second: 0)
            if d < Date() { d = calendar.date(byAdding: .day, value: 1, to: d)! }
            dueDate = d
            dismiss()
          }
          Button("Next Week") {
            dueDate = calendar.date(byAdding: .weekOfYear, value: 1, to: calendar.startOfDay(for: Date()))
            dismiss()
          }
        }

        Section("Upcoming") {
          ForEach(nextWeekdays, id: \.self) { date in
            Button(dateLabel(date)) {
              dueDate = date
              dismiss()
            }
          }
        }

        Section("Custom") {
          DatePicker("Pick a date", selection: $customDate, displayedComponents: [.date])
            .onChange(of: customDate) { _, newValue in
              dueDate = newValue
              dismiss()
            }
        }

        Section {
          Button("Someday / Maybe", role: .none) {
            dueDate = nil
            dismiss()
          }
          Button("Clear Date", role: .destructive) {
            dueDate = nil
            dismiss()
          }
        }
      }
      .navigationTitle("When")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private var nextWeekdays: [Date] {
    let today = calendar.startOfDay(for: Date())
    let nextMonday = nextDate(weekday: 2, after: today)
    return (0..<5).compactMap { calendar.date(byAdding: .day, value: $0, to: nextMonday) }
  }

  private func nextDate(weekday: Int, after date: Date) -> Date {
    var days = weekday - calendar.component(.weekday, from: date)
    if days <= 0 { days += 7 }
    return calendar.date(byAdding: .day, value: days, to: date)!
  }

  private func dateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMM d"
    return formatter.string(from: date)
  }
}

extension Date {
  mutating func set(hour: Int, minute: Int, second: Int) {
    var components = Calendar.current.dateComponents([.year, .month, .day], from: self)
    components.hour = hour
    components.minute = minute
    components.second = second
    if let d = Calendar.current.date(from: components) { self = d }
  }
}

// ─── Move To Sheet ─────────────────────────────────────────────────────────────

struct MoveToSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var selectedProjectId: String?
  let areas: [Area]
  let projects: [Project]
  @State private var searchText = ""

  var body: some View {
    NavigationStack {
      List {
        Button {
          selectedProjectId = nil
          dismiss()
        } label: {
          HStack {
            Image(systemName: "tray")
            Text("Inbox")
            Spacer()
            if selectedProjectId == nil {
              Image(systemName: "checkmark")
                .foregroundStyle(.blue)
            }
          }
        }
        .foregroundStyle(.primary)

        let topLevelProjects = projects.filter { $0.area == nil }
        if !topLevelProjects.isEmpty && matchesSearch(topLevelProjects.first) {
          Section("Projects") {
            ForEach(topLevelProjects) { project in
              projectRow(project)
            }
          }
        }

        ForEach(areas) { area in
          let areaProjects = projects.filter { $0.area == area.id }
          if !areaProjects.isEmpty && matchesSearch(areaProjects.first) {
            Section(area.name) {
              ForEach(areaProjects) { project in
                projectRow(project)
              }
            }
          }
        }
      }
      .searchable(text: $searchText, prompt: "Search projects")
      .navigationTitle("Move to")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func matchesSearch(_ project: Project?) -> Bool {
    searchText.isEmpty || (project?.name.localizedCaseInsensitiveContains(searchText) ?? false)
  }

  @ViewBuilder
  private func projectRow(_ project: Project) -> some View {
    Button {
      selectedProjectId = project.id
      dismiss()
    } label: {
      HStack {
        Text(project.name)
        Spacer()
        if selectedProjectId == project.id {
          Image(systemName: "checkmark")
            .foregroundStyle(.blue)
        }
      }
    }
    .foregroundStyle(.primary)
    .opacity(matchesSearch(project) ? 1 : 0.5)
  }
}


extension LogAction {
  var icon: String {
    switch self {
    case .created: return "plus.circle"
    case .commented: return "bubble.left"
    case .reassigned: return "arrow.triangle.swap"
    case .prioritized: return "exclamationmark.circle"
    case .completed: return "checkmark.circle"
    case .cancelled: return "xmark.circle"
    case .blocked: return "hand.raised"
    case .unblocked: return "hand.raised.fill"
    case .staleFlagged: return "flag"
    case .updated: return "pencil"
    }
  }

  var color: Color {
    switch self {
    case .completed: return .green
    case .cancelled, .blocked: return .red
    case .created, .updated: return .blue
    default: return .secondary
    }
  }
}
