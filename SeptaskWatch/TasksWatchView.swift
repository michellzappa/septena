import SwiftUI
import WatchKit

struct TasksWatchView: View {
  @Bindable private var store = TasksWatchStore.shared
  @State private var capturing = false
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
              Text("Today")
                .foregroundStyle(.white)
              Text("\(store.tasks.count)")
                .foregroundStyle(.white.opacity(0.58))
            }
            .font(.headline)
            .fontWeight(.semibold)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button { capturing = true } label: {
              Image(systemName: "plus")
            }
          }
        }
        .background(Color.black.ignoresSafeArea())
    }
    .sheet(isPresented: $capturing) {
      NavigationStack {
        AddInboxTaskView(store: store) { capturing = false }
      }
    }
    .task { store.fetchToday() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        store.fetchToday(silent: !store.tasks.isEmpty)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
      store.fetchToday()
    }
    .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
      if scenePhase == .active {
        store.fetchToday(silent: !store.tasks.isEmpty)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if store.isLoading && store.tasks.isEmpty {
      VStack(spacing: 10) {
        ProgressView()
        Text(store.loadingMessage ?? "Loading…")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(store.loadingMessage ?? "Loading Today")
    } else if let err = store.errorMessage {
      VStack(spacing: 10) {
        Image(systemName: "iphone.slash")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text(err)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button("Try Again") { store.fetchToday() }
          .font(.caption.weight(.semibold))
      }
      .padding()
    } else if store.tasks.isEmpty {
      VStack(spacing: 8) {
        Image(systemName: "checkmark.circle")
          .font(.title)
          .foregroundStyle(.secondary)
        Text("All done")
          .font(.headline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List {
        ForEach(store.tasks) { task in
          TaskWatchRow(
            task: task,
            done: store.completedIDs.contains(task.id),
            onComplete: { store.complete(task) },
            onOffToday: { store.offTodayTask(task) },
            onCancel: { store.cancelTask(task) })
            .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
            .watchSkyRow()
        }
      }
      .listStyle(.plain)
      .watchSkyList()
      .environment(\.defaultMinListRowHeight, 0)
    }
  }
}

private struct TaskWatchRow: View {
  let task: TasksWatchTaskWire
  let done: Bool
  let onComplete: () -> Void
  var onOffToday: (() -> Void)? = nil
  var onCancel: (() -> Void)? = nil

  @State private var showActions = false
  @State private var isPressing = false

  var body: some View {
    rowBody
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .watchGlassRow(extraHighlight: highlightOpacity)
      .scaleEffect(isPressing ? 0.98 : 1)
      .animation(.easeOut(duration: 0.14), value: isPressing)
      .animation(.easeOut(duration: 0.14), value: done)
      .onTapGesture { onComplete() }
      .onLongPressGesture(minimumDuration: 0.4, pressing: { pressing in
        isPressing = pressing
      }, perform: {
        WKInterfaceDevice.current().play(.click)
        showActions = true
      })
      .sheet(isPresented: $showActions) {
        TaskActionDrawer(
          onComplete: onComplete,
          onRemoveFromToday: onOffToday,
          onCancel: onCancel)
      }
  }

  private var highlightOpacity: Double {
    if isPressing { return 0.20 }
    if done { return 0.13 }
    return 0
  }

  private var rowBody: some View {
    HStack(spacing: 9) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle")
        .font(.body)
        .foregroundStyle(done ? .green : .primary)
        .frame(width: 18)

      Text(task.title)
        .font(.body)
        .lineLimit(2)
        .strikethrough(done)
        .foregroundStyle(done ? .secondary : .primary)

      if task.isOverdue && !done {
        Spacer(minLength: 0)
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 10)
  }
}

private struct TaskActionDrawer: View {
  let onComplete: () -> Void
  var onRemoveFromToday: (() -> Void)? = nil
  var onCancel: (() -> Void)? = nil
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Button { onComplete(); dismiss() } label: {
            Label("Complete", systemImage: "checkmark.circle")
          }
          if let onRemoveFromToday {
            Button { onRemoveFromToday(); dismiss() } label: {
              Label("Remove from Today", systemImage: "calendar.badge.minus")
            }
          }
          if let onCancel {
            Button(role: .destructive) { onCancel(); dismiss() } label: {
              Label("Cancel task", systemImage: "xmark.circle")
            }
          }
        }
      }
      .navigationTitle("Task")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

private struct AddInboxTaskView: View {
  let store: TasksWatchStore
  let onDone: () -> Void
  @State private var text = ""
  @FocusState private var focused: Bool

  private var trimmed: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    List {
      TextField("Task", text: $text)
        .focused($focused)
        .onSubmit(commit)
      Button(action: commit) {
        Label("Add to Inbox", systemImage: "tray.and.arrow.down")
      }
      .disabled(trimmed.isEmpty)
    }
    .navigationTitle("New To-Do")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      DispatchQueue.main.async { focused = true }
    }
  }

  private func commit() {
    guard !trimmed.isEmpty else { return }
    store.addInboxTask(title: trimmed)
    onDone()
  }
}

private extension View {
  func watchSkyRow() -> some View {
    listRowBackground(Color.clear)
  }

  func watchGlassRow(extraHighlight: Double = 0) -> some View {
    background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.white.opacity(0.12 + extraHighlight))
    )
  }

  func watchSkyList() -> some View {
    scrollContentBackground(.hidden)
  }
}
