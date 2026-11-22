import SwiftUI

// Lists: matches the Phone/Mac sidebar — Today, Review (when non-empty),
// Upcoming, Repeating, Anytime, Logbook, standalone projects, areas with
// their projects, Starred (when non-empty), and Sync at the bottom.

struct ListsView: View {
  @Environment(\.dismiss) private var dismiss
  private var store: WatchStore { .shared }

  var body: some View {
    let counts = store.structure?.counts
    let areas = store.structure?.areas ?? []
    let projects = store.structure?.projects ?? []
    let standaloneProjects = projects.filter { $0.area == nil }

    List {
      Section {
        Button { dismiss() } label: {
          ListCountRow(title: String(localized: "Today"), symbol: "sun.max.fill", count: counts?.today ?? store.todayRows.count)
        }
        if let rev = counts?.review, rev > 0 {
          NavigationLink(value: WatchRoute.review) {
            ListCountRow(title: String(localized: "Review"), symbol: "eye", count: rev)
          }
        }
        NavigationLink(value: WatchRoute.upcoming) {
          ListCountRow(title: String(localized: "Upcoming"), symbol: "calendar", count: counts?.upcoming ?? 0)
        }
        NavigationLink(value: WatchRoute.repeating) {
          ListCountRow(title: String(localized: "Repeating"), symbol: "arrow.clockwise", count: counts?.repeating ?? 0)
        }
        NavigationLink(value: WatchRoute.anytime) {
          ListCountRow(title: String(localized: "Anytime"), symbol: "rectangle.stack.fill", count: counts?.anytime ?? 0)
        }
        NavigationLink(value: WatchRoute.logbook) {
          ListCountRow(title: String(localized: "Logbook"), symbol: "checkmark", count: 0)
        }
      }

      if store.structure == nil, store.connection == .connected {
        Section {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
          .listRowBackground(Color.clear)
        }
      }

      if !standaloneProjects.isEmpty {
        Section("Projects") {
          ForEach(standaloneProjects) { project in
            NavigationLink(value: WatchRoute.project(project)) {
              ListCountRow(title: project.title, symbol: "number", count: project.count)
            }
          }
        }
      }

      ForEach(areas) { area in
        let areaProjects = projects.filter { $0.area == area.id }
        Section {
          NavigationLink(value: WatchRoute.area(area)) {
            ListCountRow(title: area.title, emoji: area.emoji, symbol: "folder", count: area.count)
          }
          ForEach(areaProjects) { project in
            NavigationLink(value: WatchRoute.project(project)) {
              ListCountRow(title: project.title, symbol: "number", count: project.count)
            }
          }
        }
      }

      if let starred = counts?.starred, starred > 0 {
        Section {
          NavigationLink(value: WatchRoute.starred) {
            ListCountRow(title: String(localized: "Starred"), symbol: "star.fill", count: starred)
          }
        }
      }

      Section {
        NavigationLink(value: WatchRoute.status) {
          Label("Sync", systemImage: store.connection == .connected ? "checkmark.icloud" : "exclamationmark.icloud")
        }
      }
    }
    .navigationTitle("Lists")
    .task { await store.refreshStructure() }
  }
}

private struct ListCountRow: View {
  let title: String
  var emoji: String? = nil
  let symbol: String
  let count: Int

  var body: some View {
    HStack(spacing: 8) {
      if let emoji, !emoji.isEmpty {
        Text(emoji)
          .frame(width: 20, alignment: .center)
      } else {
        Image(systemName: symbol)
          .foregroundStyle(.secondary)
          .frame(width: 20, alignment: .center)
      }
      Text(title)
        .lineLimit(1)
      Spacer(minLength: 4)
      if count > 0 {
        Text("\(count)")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct UpcomingView: View {
  @State private var open: WatchTask?
  private var store: WatchStore { .shared }

  var body: some View {
    let rows = store.upcomingRows
    let today = store.todayDay
    let groups = Dictionary(grouping: rows) { $0.scheduled ?? $0.deadline ?? "" }
    let days = groups.keys.sorted()
    Group {
      if rows.isEmpty, store.upcoming != nil {
        EmptyList(symbol: "calendar", text: String(localized: "Nothing scheduled."))
      } else if rows.isEmpty {
        ProgressView()
      } else {
        List {
          ForEach(days, id: \.self) { day in
            Section {
              ForEach(groups[day] ?? []) { task in
                LaterRow(task: task, today: today) { open = task }
              }
            } header: {
              Text(Self.title(day, today: today))
            }
          }
        }
      }
    }
    .navigationTitle("Upcoming")
    .navigationDestination(item: $open) { TaskDetailView(task: $0, onToday: false) }
    .task { await store.refreshNow(.upcoming) }
  }

  static func title(_ ymd: String, today: String) -> String {
    guard let date = WatchDay.date(from: ymd), let now = WatchDay.date(from: today) else { return ymd }
    let days = Calendar.current.dateComponents([.day], from: now, to: date).day ?? 0
    if days == 1 { return String(localized: "Tomorrow") }
    if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
    return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
  }
}

struct AnytimeView: View {
  @State private var open: WatchTask?
  private var store: WatchStore { .shared }

  var body: some View {
    let rows = store.anytimeRows
    Group {
      if rows.isEmpty, store.anytime != nil {
        EmptyList(symbol: "square.stack", text: String(localized: "No undated tasks."))
      } else if rows.isEmpty {
        ProgressView()
      } else {
        List {
          ForEach(rows) { task in
            LaterRow(task: task, today: store.todayDay) { open = task }
          }
        }
      }
    }
    .navigationTitle("Anytime")
    .navigationDestination(item: $open) { TaskDetailView(task: $0, onToday: false) }
    .task { await store.refreshNow(.anytime) }
  }
}

struct RepeatingView: View {
  @State private var open: WatchTask?
  private var store: WatchStore { .shared }

  var body: some View {
    let rows = store.repeatingRows
    ZStack {
      if rows.isEmpty, store.repeating != nil {
        EmptyList(symbol: "arrow.clockwise", text: String(localized: "No repeating tasks."))
      } else if rows.isEmpty {
        ProgressView()
      } else {
        List {
          ForEach(rows) { task in
            LaterRow(task: task, today: store.todayDay) { open = task }
          }
        }
      }
    }
    .navigationTitle("Repeating")
    .navigationDestination(item: $open) { TaskDetailView(task: $0, onToday: false) }
    .task { await store.refreshNow(.repeating) }
  }
}

struct SmartView: View {
  let title: String
  let view: WatchTaskList.View
  let symbol: String
  let emptyText: String

  @State private var open: WatchTask?
  private var store: WatchStore { .shared }

  private var rows: [WatchTask] {
    switch view {
    case .review: return store.reviewRows
    case .starred: return store.starredRows
    default: return []
    }
  }

  private var loaded: Bool {
    switch view {
    case .review: return store.review != nil
    case .starred: return store.starred != nil
    default: return true
    }
  }

  var body: some View {
    ZStack {
      if rows.isEmpty, loaded {
        EmptyList(symbol: symbol, text: emptyText)
      } else if rows.isEmpty {
        ProgressView()
      } else {
        List {
          ForEach(rows) { task in
            LaterRow(task: task, today: store.todayDay) { open = task }
          }
        }
      }
    }
    .navigationTitle(title)
    .navigationDestination(item: $open) { TaskDetailView(task: $0, onToday: false) }
    .task { await store.refreshNow(view) }
  }
}

struct LogbookView: View {
  private var store: WatchStore { .shared }

  var body: some View {
    let rows = store.logbookRows
    ZStack {
      if rows.isEmpty, store.logbook != nil {
        EmptyList(symbol: "checkmark", text: String(localized: "Logbook is empty."))
      } else if rows.isEmpty {
        ProgressView()
      } else {
        List {
          ForEach(rows) { task in
            VStack(alignment: .leading, spacing: 2) {
              Text(task.title)
                .font(.body)
                .lineLimit(3)
                .foregroundStyle(.secondary)
              if let container = task.container {
                Text(container)
                  .font(.footnote)
                  .foregroundStyle(.tertiary)
              }
            }
            .padding(.vertical, 2)
          }
        }
      }
    }
    .navigationTitle("Logbook")
    .task { await store.refreshNow(.completed) }
  }
}

struct ContainerTasksView: View {
  let title: String
  let areaID: String?
  let projectID: String?

  @State private var open: WatchTask?
  private var store: WatchStore { .shared }

  private var key: String {
    projectID.map { "project:\($0)" } ?? areaID.map { "area:\($0)" } ?? ""
  }

  var body: some View {
    let rows = store.containerRows(key: key)
    let loaded = store.containers[key] != nil
    ZStack {
      if rows.isEmpty, loaded {
        EmptyList(symbol: projectID != nil ? "number" : "folder", text: String(localized: "No open tasks."))
      } else if rows.isEmpty {
        ProgressView()
      } else {
        List {
          ForEach(rows) { task in
            LaterRow(task: task, today: store.todayDay) { open = task }
          }
        }
      }
    }
    .navigationTitle(title)
    .navigationDestination(item: $open) { TaskDetailView(task: $0, onToday: false) }
    .task { await store.refreshContainer(area: areaID, project: projectID) }
  }
}

/// A row outside Today: same look, swipe left to bring it to Today.
private struct LaterRow: View {
  let task: WatchTask
  let today: String
  let onOpen: () -> Void
  private var store: WatchStore { .shared }

  var body: some View {
    TaskRowView(task: task, today: today, onComplete: { store.complete(task) }, onOpen: onOpen)
      .swipeActions(edge: .leading, allowsFullSwipe: true) {
        Button { store.complete(task) } label: { Label("Complete", systemImage: "checkmark") }
          .tint(.green)
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        Button { store.moveToToday(task) } label: { Label("Today", systemImage: "star") }
          .tint(.yellow)
      }
  }
}

private struct EmptyList: View {
  let symbol: String
  let text: String

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
      Text(text).font(.footnote).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Connection, last sync, waiting changes, the last error — everything
/// needed to tell what's wrong on the wrist without Xcode.
struct StatusView: View {
  @Bindable private var store = WatchStore.shared

  var body: some View {
    List {
      Section {
        LabeledContent("iPhone link", value: store.connection == .connected
          ? String(localized: "Connected") : String(localized: "Not connected"))
        if let at = store.lastSyncedAt {
          LabeledContent("Updated", value: at.formatted(date: .omitted, time: .shortened))
        }
        LabeledContent("Waiting", value: "\(store.queue.count)")
        if store.offline { Label("Offline", systemImage: "wifi.slash").foregroundStyle(.orange) }
        if let error = store.lastError {
          Text(error).font(.footnote).foregroundStyle(.red)
        }
      }
      Section {
        Button {
          Task { await store.refreshNow(.today) }
        } label: {
          Label(store.isRefreshing ? "Syncing…" : "Sync Now", systemImage: "arrow.clockwise")
        }
        .disabled(store.isRefreshing)
        if store.connection == .notConnected {
          Button {
            WatchPhoneLink.shared.requestSession(force: true)
          } label: {
            Label("Connect to iPhone", systemImage: "iphone")
          }
        }
      }
      #if DEBUG
      Section("Debug") {
        Toggle("Sample data", isOn: $store.sampleMode)
      }
      #endif
      Section {
        Text(Self.version).font(.footnote).foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Sync")
  }

  private static var version: String {
    let info = Bundle.main.infoDictionary
    let v = info?["CFBundleShortVersionString"] as? String ?? "?"
    let b = info?["CFBundleVersion"] as? String ?? "?"
    return "Septena \(v) (\(b))"
  }
}
