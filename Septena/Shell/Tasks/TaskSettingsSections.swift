import SwiftUI
import SwiftData

// The task settings rows, shared by both shells: Septena mounts them inside
// Settings ▸ Sections ▸ Tasks (`TasksDetailContent` in TasksPlugin) and
// Septask inside its dedicated Settings sheet — extracted per docs/SEPTASK.md
// so the toggles can't drift between the apps. Full-app-only rows (the
// drawer/tab "Open in" choice and the Next-feed toggle) are `#if !SEPTASK`-
// gated: they configure surfaces Septask doesn't ship and ride SettingsStore
// types Septask doesn't compile.
struct TaskSettingsSections: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  #if !SEPTASK
  @Environment(SettingsStore.self) private var store
  #endif

  // Shared App Group, not per-app defaults: both apps badge the same overdue
  // tasks, so two independent opt-ins showed two dock dots for one set of work
  // (see `BadgeManager`). One key, written by whichever app you happen to be in.
  @AppStorage(SettingsKey.badgeShowOverdue, store: SeptenaAppGroup.defaults)
  private var taskBadge: Bool = false
  @AppStorage(SettingsKey.todayShowCompleted) private var todayShowCompleted: Bool = true
  @AppStorage(SettingsKey.todayGroupByList) private var todayGroupByList: Bool = true
  #if !SEPTASK
  @AppStorage(SettingsKey.tasksOpenIn)        private var tasksOpenInRaw: String = TasksOpenMode.drawer.rawValue
  #endif
  @AppStorage(SettingsKey.tasksShowCalendarEvents) private var showCalendarEvents: Bool = true
  @AppStorage(SettingsKey.tasksShowAging) private var showAging: Bool = true
  @AppStorage(SettingsKey.tasksFilingSuggestions) private var filingSuggestions: Bool = true
  @AppStorage(SettingsKey.tasksTitleLines) private var titleLines: Int = 2

  #if !SEPTASK
  private var tasksSection: SectionConfig? {
    store.sections.first { $0.key == "tasks" }
  }

  /// `SectionConfig.showInToday` — same mirror the section identity row and
  /// Settings → Next use, so this can't become a second source of truth.
  private var showInNextBinding: Binding<Bool> {
    Binding(
      get: { tasksSection?.showInToday ?? true },
      set: { value in
        SettingsMirror.setSectionShowInToday("tasks",
                                             showInToday: value,
                                             context: modelContext,
                                             engine: ckEngine)
        store.sections = store.sections.map { config in
          config.key == "tasks"
            ? SectionConfig(key: config.key, label: config.label, color: config.color,
                            isEnabled: config.isEnabled, showInToday: value,
                            showInSpotlight: config.showInSpotlight,
                            hasOnboarded: config.hasOnboarded)
            : config
        }
      }
    )
  }
  #endif

  var body: some View {
    #if !SEPTASK
    Section("Open in") {
      Picker("Tasks open in", selection: $tasksOpenInRaw) {
        ForEach(TasksOpenMode.allCases) { mode in
          Text(mode.label).tag(mode.rawValue)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    }
    #endif
    // Septask hoists the badge toggle into its root Notifications pane —
    // badge IS the notification story there; here it stays with the tasks knobs.
    #if !SEPTASK
    Section("Badge") {
      Toggle("Show overdue indicator on app icon", isOn: $taskBadge)
    }
    #endif
    Section {
      Toggle("Show completed tasks in Today", isOn: $todayShowCompleted)
      Toggle(isOn: $showAging) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Show aging on Today")
          Text("Tint the checkbox as a task carries over day after day.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      // Same switch as View ▸ Group Today by List; `announcing` is what keeps
      // Septask's AppKit list in step when it's flipped from here.
      Toggle(isOn: TaskViewOptions.announcing($todayGroupByList)) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Group by area and project")
          Text("Off shows one flat list under Inbox, in the same order, with each task's list as a subtitle.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Today")
    } footer: {
      Text("Aging starts the day after a task lands on Today and deepens over a week — a quiet signal that you keep deferring it. Resets when you move it off Today or check it off. A flat Today list keeps the same area and project order, under a single divider, with each task's list shown as a subtitle instead of a heading.")
    }
    #if !SEPTASK
    Section {
      Toggle(isOn: showInNextBinding) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Show in Next")
          Text("Include today's open tasks on the Next list.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    } footer: {
      Text("Hides tasks from Next only — the Tasks tab and data stay put. The same switch lives under Settings → Next → Sections in Next.")
    }
    #endif
    #if os(iOS)
    Section {
      Picker("Title lines", selection: $titleLines) {
        Text("One").tag(1)
        Text("Two").tag(2)
        Text("Three").tag(3)
      }
    } header: {
      Text("Rows")
    } footer: {
      Text("How far a long task title wraps before it truncates. Taller rows fit fewer tasks on screen.")
    }
    #endif
    Section {
      Toggle(isOn: $filingSuggestions) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Suggest filing destinations")
          Text("Learn on-device where you usually file similar tasks.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Inbox")
    } footer: {
      Text("Shows a one-tap chip on inbox rows and a suggested list while you type. The model trains locally on your history and never leaves your device.")
    }
    Section {
      Toggle("Show calendar events", isOn: $showCalendarEvents)
    } header: {
      Text("Calendar")
    } footer: {
      #if SEPTASK
      Text("Weave your calendar's events into Today and Upcoming.")
      #else
      Text("Weave your calendar's events into Today and Upcoming. Grant access and choose which calendars to show in Related Settings below.")
      #endif
    }
    #if !SEPTASK
    Section {
      Text("Areas and projects are managed in the Tasks tab.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    #endif
  }
}
