import SwiftData
import SwiftUI

// The Weekly Sweep sheet (`docs/TASK_FADE_SPEC.md` §5, ADR 0006).
//
// Shared by both shells: SwiftUI presents it with `.sheet`; Septask's AppKit
// task list hosts it in an `NSHostingController` sheet. Shows ONLY the faded
// tasks for this sweep, one tap ("Keep") per item, and one bottom button
// ("Let the rest go") that cancels the remaining rows with `dropReason = "faded"`
// in ONE undo entry. Closing or ignoring drops nothing — doing nothing is safe.

struct TaskFadeSweepSheet: View {
  /// Tasks to review (faded since the last sweep, or the current Faded pile
  /// when opened directly from Faded).
  let initialTasks: [SeptenaTask]
  let areas: [Area]
  let projects: [Project]
  /// Called when the sheet closes (whether swept or dismissed untouched).
  let onClose: () -> Void

  @Environment(TaskMutator.self) private var mutator
  @State private var remaining: [SeptenaTask]
  @State private var keptCount: Int = 0

  init(tasks: [SeptenaTask],
       areas: [Area],
       projects: [Project],
       onClose: @escaping () -> Void) {
    self.initialTasks = tasks
    self.areas = areas
    self.projects = projects
    self.onClose = onClose
    _remaining = State(initialValue: tasks)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if remaining.isEmpty {
          allKeptView
        } else {
          taskList
        }
        Divider()
        footer
      }
      .navigationTitle(String(localized: "Review Faded Tasks", comment: "Sweep sheet title"))
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(String(localized: "Not now", comment: "Sweep sheet dismiss without dropping")) {
            onClose()
          }
        }
      }
    }
    #if os(macOS)
    .frame(minWidth: 440, idealWidth: 480, minHeight: 360, idealHeight: 460)
    #endif
  }

  private var taskList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        Text(String(localized: "Choose Keep for anything you still need. The rest move to your Logbook as let go, never deleted.",
                    comment: "Sweep sheet intro"))
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
          .padding(.horizontal, 16)
          .padding(.vertical, 12)

        ForEach(remaining) { task in
          sweepRow(task)
          Divider().padding(.leading, 16)
        }
      }
    }
  }

  private func sweepRow(_ task: SeptenaTask) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(task.title)
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkPrimary)
          .lineLimit(2)
        Text(reasonLine(for: task))
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Button(String(localized: "Keep", comment: "Sweep sheet row action")) {
        keep(task)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var allKeptView: some View {
    VStack(spacing: 10) {
      Spacer()
      Image(systemName: "checkmark.circle")
        .scaledFont(size: 32)
        .foregroundStyle(Theme.inkSecondary)
      Text(keptCount > 0
           ? String(localized: "You kept everything.", comment: "Sweep sheet empty after keeping all")
           : String(localized: "Nothing to review.", comment: "Sweep sheet empty"))
        .font(.septenaLabel)
        .foregroundStyle(Theme.inkPrimary)
      if keptCount > 0 {
        Text(String(localized: "Kept tasks are back in their lists.",
                    comment: "Sweep sheet empty detail"))
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  private var footer: some View {
    HStack {
      if !remaining.isEmpty {
        Text(remaining.count == 1
             ? String(localized: "1 task remaining", comment: "Sweep footer count")
             : String(localized: "\(remaining.count) tasks remaining", comment: "Sweep footer count"))
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
      }
      Spacer()
      if remaining.isEmpty {
        Button(String(localized: "Done", comment: "Sweep sheet done button")) {
          TaskFade.markSweepCompleted(at: DayClock.appNow)
          onClose()
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button(String(localized: "Let the rest go", comment: "Sweep sheet primary drop button")) {
          letTheRestGo()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private func keep(_ task: SeptenaTask) {
    Haptics.tick()
    let snapshot = TaskUndo.FadedSnapshot(task)
    mutator.keepFaded(ids: [task.id])
    TaskUndo.recordKeepFaded(before: [snapshot], mutator: mutator)
    a11yAnimate(.easeOut(duration: 0.2)) {
      remaining.removeAll { $0.id == task.id }
      keptCount += 1
    }
  }

  private func letTheRestGo() {
    Haptics.tick()
    let snapshots = remaining.map(TaskUndo.FadedSnapshot.init)
    let ids = remaining.map(\.id)
    mutator.dropFaded(ids: ids)
    TaskUndo.recordSweepDrop(before: snapshots, mutator: mutator)
    TaskFade.markSweepCompleted(at: DayClock.appNow)
    onClose()
  }

  private func reasonLine(for task: SeptenaTask) -> String {
    let listName: String? = {
      if let pid = task.project, let p = projects.first(where: { $0.id == pid }) { return p.title }
      if let aid = task.area, let a = areas.first(where: { $0.id == aid }) { return a.title }
      return nil
    }()
    return TaskFade.sweepReason(
      touchedAt: task.touchedAt,
      createdAt: task.createdAt,
      created: task.created,
      listName: listName,
      scheduled: task.scheduled,
      now: DayClock.appNow
    )
  }
}
