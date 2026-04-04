import SwiftUI

struct TodayView: View {
  @EnvironmentObject var client: ConvexClient
  @State private var tasks: [EngageTask] = []
  @State private var isLoading = false

  private let today = Calendar.current.startOfDay(for: Date())

  var body: some View {
    Group {
      if isLoading && tasks.isEmpty {
        ProgressView()
      } else if todayTasks.isEmpty {
        ContentUnavailableView(
          "Nothing due today",
          systemImage: "sun.max",
          description: Text("Enjoy your day")
        )
      } else {
        List(todayTasks) { task in
          TaskRowView(task: task)
        }
        .listStyle(.plain)
        .refreshable {
          await load()
        }
      }
    }
    .navigationTitle("Today")
    .task { await load() }
  }

  private var todayTasks: [EngageTask] {
    tasks.filter { task in
      guard task.status == .open else { return false }
      let calendar = Calendar.current
      if let due = task.due, calendar.isDate(due, inSameDayAs: today) { return true }
      if let start = task.start, calendar.isDate(start, inSameDayAs: today) { return true }
      return false
    }
    .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
  }

  private func load() async {
    isLoading = true
    do {
      tasks = try await client.tasksList(status: .open)
    } catch {
      // non-fatal
    }
    isLoading = false
  }
}

struct UpcomingView: View {
  @EnvironmentObject var client: ConvexClient
  @State private var tasks: [EngageTask] = []
  @State private var isLoading = false

  private let calendar = Calendar.current
  private let today = Calendar.current.startOfDay(for: Date())

  var body: some View {
    Group {
      if isLoading && tasks.isEmpty {
        ProgressView()
      } else {
        List {
          ForEach(0..<7, id: \.self) { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            let dayTasks = tasksForDay(date)
            if !dayTasks.isEmpty || offset < 3 {
              Section {
                ForEach(dayTasks) { task in
                  TaskRowView(task: task)
                }
              } header: {
                HStack {
                  Text(dayLabel(date))
                    .font(.headline)
                  if calendar.isDateInToday(date) {
                    Text("Today")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Text(EngageDateFormatter.relative(date))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
              }
            }
          }
        }
        .listStyle(.plain)
        .refreshable {
          await load()
        }
      }
    }
    .navigationTitle("Upcoming")
    .task { await load() }
  }

  private func tasksForDay(_ date: Date) -> [EngageTask] {
    tasks.filter { task in
      guard task.status == .open else { return false }
      let due = task.due ?? task.start
      guard let d = due else { return false }
      return calendar.isDate(d, inSameDayAs: date)
    }
  }

  private func dayLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE"
    return formatter.string(from: date)
  }

  private func load() async {
    isLoading = true
    do {
      tasks = try await client.tasksList(status: .open)
    } catch {
      // non-fatal
    }
    isLoading = false
  }
}

struct AnytimeView: View {
  @EnvironmentObject var client: ConvexClient
  @State private var tasks: [EngageTask] = []
  @State private var isLoading = false

  var body: some View {
    Group {
      if isLoading && tasks.isEmpty {
        ProgressView()
      } else if anytimeTasks.isEmpty {
        ContentUnavailableView("Anytime is clear", systemImage: "circle", description: Text("All tasks are scheduled"))
      } else {
        List(anytimeTasks) { task in
          TaskRowView(task: task)
        }
        .listStyle(.plain)
        .refreshable { await load() }
      }
    }
    .navigationTitle("Anytime")
    .task { await load() }
  }

  private var anytimeTasks: [EngageTask] {
    tasks.filter { $0.status == .open && $0.due == nil && $0.start == nil }
  }

  private func load() async {
    isLoading = true
    do {
      tasks = try await client.tasksList(status: .open)
    } catch {}
    isLoading = false
  }
}

struct SomedayView: View {
  @EnvironmentObject var client: ConvexClient
  @State private var tasks: [EngageTask] = []
  @State private var isLoading = false

  var body: some View {
    Group {
      if isLoading && tasks.isEmpty {
        ProgressView()
      } else if tasks.isEmpty {
        ContentUnavailableView("Someday maybe", systemImage: "moon", description: Text("No someday tasks"))
      } else {
        List(tasks) { task in
          TaskRowView(task: task)
        }
        .listStyle(.plain)
        .refreshable { await load() }
      }
    }
    .navigationTitle("Someday")
    .task { await load() }
  }

  private func load() async {
    isLoading = true
    tasks = []
    isLoading = false
  }
}

struct LogbookView: View {
  @EnvironmentObject var client: ConvexClient
  @State private var logEntries: [CollaborationLogEntry] = []
  @State private var isLoading = false

  var body: some View {
    Group {
      if isLoading {
        ProgressView()
      } else if logEntries.isEmpty {
        ContentUnavailableView("No history", systemImage: "book.closed")
      } else {
        List {
          ForEach(groupedEntries, id: \.0) { date, entries in
            Section(EngageDateFormatter.relative(date)) {
              ForEach(entries) { entry in
                HStack {
                  Image(systemName: entry.action.icon)
                    .foregroundStyle(entry.action.color)
                  VStack(alignment: .leading) {
                    Text(entry.actor == "human" ? "Human" : "Agent")
                      .font(.subheadline)
                    if let content = entry.content, !content.hasPrefix("{") {
                      Text(content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                  }
                  Spacer()
                }
              }
            }
          }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
      }
    }
    .navigationTitle("Logbook")
    .task { await load() }
  }

  private var groupedEntries: [(Date, [CollaborationLogEntry])] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: logEntries) { entry in
      calendar.startOfDay(for: entry.createdAt)
    }
    return grouped.sorted { $0.key > $1.key }
  }

  private func load() async {
    isLoading = true
    do {
      logEntries = try await client.collaborationLog(limit: 100)
    } catch {}
    isLoading = false
  }
}

struct ReviewView: View {
  @EnvironmentObject var client: ConvexClient
  @State private var tasks: [EngageTask] = []
  @State private var isLoading = false

  private let staleDays = 5

  var body: some View {
    Group {
      if isLoading && tasks.isEmpty {
        ProgressView()
      } else {
        List {
          if !staleTasks.isEmpty {
            Section("Stale (no activity in \(staleDays)+ days)") {
              ForEach(staleTasks) { task in
                TaskRowView(task: task)
              }
            }
          }
          if !overdueTasks.isEmpty {
            Section("Overdue") {
              ForEach(overdueTasks) { task in
                TaskRowView(task: task)
              }
            }
          }
          if !blockedTasks.isEmpty {
            Section("Blocked") {
              ForEach(blockedTasks) { task in
                TaskRowView(task: task)
              }
            }
          }
          if staleTasks.isEmpty && overdueTasks.isEmpty && blockedTasks.isEmpty {
            ContentUnavailableView("All clear", systemImage: "checkmark.circle", description: Text("No tasks need attention"))
          }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
      }
    }
    .navigationTitle("Review")
    .task { await load() }
  }

  private var staleTasks: [EngageTask] {
    let cutoff = Calendar.current.date(byAdding: .day, value: -staleDays, to: Date())!
    return tasks.filter { $0.status == .open && $0.completedAt == nil && $0.due == nil }
  }

  private var overdueTasks: [EngageTask] {
    tasks.filter { $0.status == .open && $0.due != nil && $0.due! < Date() }
  }

  private var blockedTasks: [EngageTask] {
    tasks.filter { $0.status == .open && $0.agentStatus == .blocked }
  }

  private func load() async {
    isLoading = true
    do {
      tasks = try await client.tasksList()
    } catch {}
    isLoading = false
  }
}
