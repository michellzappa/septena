import SwiftUI
import WatchKit

// Today: the root, where the app opens (docs/WATCH.md §3). The Inbox section
// first, then the rest of Today, in the phone's order. The circle completes;
// the row opens the task. Swipe right to complete, left for Tomorrow /
// Remove from Today.

enum WatchRoute: Hashable {
  case task(WatchTask, onToday: Bool)
  case lists
  case upcoming
  case anytime
  case status
}

struct TodayView: View {
  @Bindable private var store = WatchStore.shared
  @State private var path: [WatchRoute] = []
  @State private var captured: String?
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack(path: $path) {
      content
        .navigationTitle("Today")
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            NavigationLink(value: WatchRoute.lists) {
              Image(systemName: "list.bullet")
            }
            .accessibilityLabel("Lists")
          }
          ToolbarItem(placement: .topBarTrailing) {
            CaptureButton { captured = $0 }
          }
        }
        .navigationDestination(for: WatchRoute.self) { route in
          switch route {
          case .task(let task, let onToday): TaskDetailView(task: task, onToday: onToday)
          case .upcoming: UpcomingView()
          case .anytime: AnytimeView()
          case .lists: ListsView()
          case .status: StatusView()
          }
        }
    }
    .undoToast()
    .sheet(item: Binding(get: { captured.map(CapturedTitle.init) }, set: { captured = $0?.title })) { item in
      WhenPicker(title: item.title) { when in
        store.create(title: item.title, when: when)
        captured = nil
      }
    }
    .task { await store.refreshNow(.today) }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { store.refresh(.today) }
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
      store.refresh(.today)
    }
  }

  @ViewBuilder
  private var content: some View {
    let rows = store.todayRows
    if rows.isEmpty, store.connection == .notConnected, !store.sampleMode {
      NotConnectedView()
    } else if rows.isEmpty, store.today == nil {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if rows.isEmpty {
      AllClearView()
    } else {
      let inbox = rows.filter(\.isInbox)
      let rest = rows.filter { !$0.isInbox }
      List {
        if !inbox.isEmpty {
          Section {
            ForEach(inbox) { row($0) }
          } header: {
            SectionHeader(title: String(localized: "Inbox"), count: inbox.count)
          }
        }
        if !rest.isEmpty {
          Section {
            ForEach(rest) { row($0) }
          } header: {
            if !inbox.isEmpty {
              SectionHeader(title: String(localized: "Today"), count: rest.count)
            }
          }
        }
        Section {
          SyncFooter()
        }
        .listRowBackground(Color.clear)
      }
    }
  }

  private func row(_ task: WatchTask) -> some View {
    TaskRowView(task: task, today: store.todayDay,
                onComplete: { store.complete(task) },
                onOpen: { path.append(.task(task, onToday: true)) })
      .swipeActions(edge: .leading, allowsFullSwipe: true) {
        Button { store.complete(task) } label: { Label("Complete", systemImage: "checkmark") }
          .tint(.green)
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        Button { store.tomorrow(task) } label: { Label("Tomorrow", systemImage: "sunrise") }
          .tint(.orange)
        Button { store.removeFromToday(task) } label: { Label("Remove from Today", systemImage: "calendar.badge.minus") }
          .tint(.gray)
      }
  }
}

private struct CapturedTitle: Identifiable {
  let title: String
  var id: String { title }
}

struct SectionHeader: View {
  let title: String
  var count: Int? = nil

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(title)
      if let count { Text("\(count)").foregroundStyle(.secondary) }
    }
    .accessibilityElement(children: .combine)
  }
}

/// "Updated 10:42", plus "Offline" or the queue when either applies.
struct SyncFooter: View {
  private var store: WatchStore { .shared }

  var body: some View {
    VStack(spacing: 2) {
      if store.offline {
        Label("Offline", systemImage: "wifi.slash")
      } else if store.isRefreshing {
        Text("Syncing…")
      }
      if !store.queue.isEmpty {
        Text("\(store.queue.count) change(s) waiting")
      }
      if let at = store.lastSyncedAt, !store.isRefreshing {
        Text("Updated \(at.formatted(date: .omitted, time: .shortened))")
      }
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity)
  }
}

struct AllClearView: View {
  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        Image(systemName: "checkmark.circle")
          .font(.system(size: 36, weight: .light))
          .foregroundStyle(.green)
        Text("All clear")
          .font(.headline)
        Text("Nothing left for today.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        SyncFooter().padding(.top, 6)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 12)
    }
  }
}

struct NotConnectedView: View {
  /// When this binary was built, so a tester can tell an update landed.
  static var build: String {
    guard let url = Bundle.main.executableURL,
          let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    else { return "" }
    return "Built \(date.formatted(date: .abbreviated, time: .shortened))"
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 10) {
        Image(systemName: "iphone.and.arrow.forward")
          .font(.system(size: 30, weight: .light))
          .foregroundStyle(.secondary)
        Text("Open Septena on your iPhone to connect your watch.")
          .font(.footnote)
          .multilineTextAlignment(.center)
        Button("Try Again") {
          WatchPhoneLink.shared.requestSession(force: true)
          WatchStore.shared.refresh(.today)
        }
        if let asked = WatchPhoneLink.shared.lastAsked {
          Text(asked).font(.footnote).foregroundStyle(.secondary)
        }
        Text(Self.build).font(.footnote).foregroundStyle(.tertiary)
        #if DEBUG
        Button("Use Sample Data") { WatchStore.shared.sampleMode = true }
          .font(.footnote)
        #endif
      }
      .padding(.horizontal, 4)
    }
  }
}
