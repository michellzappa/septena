import SwiftUI

// ─── Quick Entry View ─────────────────────────────────────────────────────────

struct QuickEntryView: View {
  @EnvironmentObject var client: ConvexClient
  @EnvironmentObject var nav: NavigationState
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

        Section("When") {
          WhenPickerRow(dueDate: $dueDate, showingSheet: $showingWhenSheet)
        }

        Section("Move") {
          MoveToRow(
            selectedProjectId: $selectedProjectId,
            showingSheet: $showingMoveSheet
          )
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
        // Parse natural language date from title if not manually set
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

  private let calendar = Calendar.current

  var body: some View {
    NavigationStack {
      List {
        Section {
          Button("Today") {
            dueDate = calendar.startOfDay(for: Date())
            dismiss()
          }
          Button("This Evening") {
            var components = calendar.dateComponents([.year, .month, .day], from: Date())
            components.hour = 18
            components.minute = 0
            dueDate = calendar.date(from: components)
            dismiss()
          }
          Button("Tomorrow") {
            dueDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
            dismiss()
          }
          Button("Next Week") {
            dueDate = calendar.date(byAdding: .weekOfYear, value: 1, to: calendar.startOfDay(for: Date()))
            dismiss()
          }
        }

        Section("Upcoming") {
          ForEach(nextWeekDates, id: \.self) { date in
            Button(dateLabel(date)) {
              dueDate = date
              dismiss()
            }
          }
        }

        Section("Custom") {
          DatePicker(
            "Pick a date",
            selection: Binding(
              get: { dueDate ?? Date() },
              set: { dueDate = $0; dismiss() }
            ),
            displayedComponents: [.date]
          )
        }

        Section {
          Button("Someday / Someday Maybe", role: .none) {
            // Someday is represented as no date but a special tag — for now just clear
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

  private var nextWeekDates: [Date] {
    let today = calendar.startOfDay(for: Date())
    let monday = todayWithWeekday(.monday, after: today)
    return (0..<5).compactMap { calendar.date(byAdding: .weekOfYear, value: 0, to: monday).map { calendar.date(byAdding: .day, value: $0, to: $0)! } }
  }

  private func todayWithWeekday(_ weekday: Int, after date: Date) -> Date {
    let current = calendar.component(.weekday, from: date)
    var daysToAdd = weekday - current
    if daysToAdd <= 0 { daysToAdd += 7 }
    return calendar.date(byAdding: .day, value: daysToAdd, to: date)!
  }

  private func dateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMM d"
    return formatter.string(from: date)
  }
}

// ─── Move To Sheet ─────────────────────────────────────────────────────────────

struct MoveToSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var selectedProjectId: String?
  let areas: [Area]
  let projects: [Project]

  @State private var searchText = ""

  var filteredProjects: [Project] {
    if searchText.isEmpty { return projects }
    return projects.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
  }

  var body: some View {
    NavigationStack {
      List {
        // Inbox option
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

        // Projects with no area
        let topLevelProjects = filteredProjects.filter { $0.area == nil }
        if !topLevelProjects.isEmpty {
          Section("Projects") {
            ForEach(topLevelProjects) { project in
              projectRow(project)
            }
          }
        }

        // Projects grouped by area
        ForEach(areas) { area in
          let areaProjects = filteredProjects.filter { $0.area == area.id }
          if !areaProjects.isEmpty {
            Section(area.name) {
              ForEach(areaProjects) { project in
                projectRow(project)
              }
            }
          }
        }
      }
      .searchable(text: $searchText, prompt: "Search projects")
      .navigationTitle("Move To")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
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
  }
}

// ─── When Picker Row ─────────────────────────────────────────────────────────

struct WhenPickerRow: View {
  @Binding var dueDate: Date?
  @Binding var showingSheet: Bool

  var body: some View {
    Button {
      showingSheet = true
    } label: {
      HStack {
        Image(systemName: "calendar")
          .foregroundStyle(.blue)
        if let due = dueDate {
          Text(EngageDateFormatter.relative(due))
            .foregroundStyle(.primary)
        } else {
          Text("Add Date")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }
}

// ─── Move To Row ─────────────────────────────────────────────────────────────

struct MoveToRow: View {
  @Binding var selectedProjectId: String?
  @Binding var showingSheet: Bool

  var body: some View {
    Button {
      showingSheet = true
    } label: {
      HStack {
        Image(systemName: "folder")
          .foregroundStyle(.orange)
        if let projectId = selectedProjectId {
          Text("Project selected")
            .foregroundStyle(.secondary)
        } else {
          Text("Inbox")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }
}

// ─── Agent Panel View ─────────────────────────────────────────────────────────

struct AgentPanelView: View {
  @EnvironmentObject var client: ConvexClient
  @Environment(\.dismiss) private var dismiss
  @State private var memories: [AgentMemoryEntry] = []
  @State private var logEntries: [CollaborationLogEntry] = []
  @State private var isLoading = false

  private let agentId = "agent"

  var body: some View {
    NavigationStack {
      List {
        Section("Recent Thinking") {
          if memories.isEmpty && !isLoading {
            Text("No agent activity yet")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
          ForEach(memories) { entry in
            VStack(alignment: .leading, spacing: 4) {
              Text(entry.content)
                .font(.callout)
              Text(EngageDateFormatter.relative(entry.updatedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
          }
        }

        Section("Activity") {
          if logEntries.isEmpty && !isLoading {
            Text("No activity yet")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
          ForEach(logEntries) { entry in
            HStack {
              Image(systemName: entry.action.icon)
                .foregroundStyle(entry.action.color)
              VStack(alignment: .leading) {
                Text(entry.actor == "human" ? "Human" : "Agent")
                  .font(.caption)
                  .fontWeight(.medium)
                if let content = entry.content {
                  Text(content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Text(EngageDateFormatter.relative(entry.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Agent")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await load() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(isLoading)
        }
      }
      .task { await load() }
    }
  }

  private func load() async {
    isLoading = true
    do {
      memories = try await client.agentMemory(agentId: agentId)
      logEntries = try await client.collaborationLog(limit: 30)
    } catch {}
    isLoading = false
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
    }
  }

  var color: Color {
    switch self {
    case .completed: return .green
    case .cancelled, .blocked: return .red
    case .created: return .blue
    default: return .secondary
    }
  }
}
