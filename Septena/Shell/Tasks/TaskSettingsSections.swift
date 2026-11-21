import SwiftUI
import SwiftData

// The one Tasks settings page, shared by both apps: Septena shows it as the
// top-level Settings ▸ Tasks pane and Septask as its Settings ▸ Tasks pane.
// One component so the task controls can't drift between the apps
// (docs/SEPTASK.md). Each app passes its own navigation value for the few
// rows that link to another page (Calendar access, Reminders, Claude, Things).
//
// `#if SEPTASK` branches cover only what differs by app:
//   • Septena: the home-tile "Open in" choice, plus a link to Sections ▸ Tasks
//     for the section's color, Next, and Spotlight switches (those stay with
//     the other sections, so they are not repeated here).
//   • Septask: the Tasks accent swatch inline, because Septask has no
//     Sections page.

/// Rows on the Tasks settings page that open another settings page. Each app
/// maps these to its own navigation value.
enum TaskSettingsLink: Hashable {
  /// Septena only: Settings ▸ Sections ▸ Tasks (color, Next, Spotlight).
  case section
  case reminders
  case calendar
  case things
  case claudeAI
}

struct TaskSettingsPane<Destination: Hashable>: View {
  /// The navigation value each app pushes for a linked page.
  let destination: (TaskSettingsLink) -> Destination

  // Shared App Group, not per-app defaults: both apps badge the same overdue
  // tasks, so two independent opt-ins showed two dock dots for one set of work
  // (see `BadgeManager`). One key, written by whichever app you happen to be in.
  @AppStorage(SettingsKey.badgeShowOverdue, store: SeptenaAppGroup.defaults)
  private var taskBadge: Bool = RegistrySettings.Defaults.badgeShowOverdue
  @AppStorage(SettingsKey.todayShowCompleted) private var todayShowCompleted: Bool = RegistrySettings.Defaults.todayShowCompleted
  @AppStorage(SettingsKey.todayGroupByList) private var todayGroupByList: Bool = RegistrySettings.Defaults.todayGroupByList
  #if !SEPTASK
  @AppStorage(SettingsKey.tasksOpenIn) private var tasksOpenInRaw: String = TasksOpenMode.drawer.rawValue
  #endif
  @AppStorage(SettingsKey.tasksShowCalendarEvents) private var showCalendarEvents: Bool = RegistrySettings.Defaults.tasksShowCalendarEvents
  @AppStorage(SettingsKey.tasksShowAging) private var showAging: Bool = RegistrySettings.Defaults.tasksShowAging
  @AppStorage(SettingsKey.tasksFilingSuggestions) private var filingSuggestions: Bool = RegistrySettings.Defaults.tasksFilingSuggestions
  @AppStorage(SettingsKey.tasksTitleLines) private var titleLines: Int = RegistrySettings.Defaults.tasksTitleLines

  #if SEPTASK
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SectionTheme.self) private var theme
  @AppStorage(SettingsKey.loggingAnimationsEnabled) private var completionAnimations = RegistrySettings.Defaults.loggingAnimationsEnabled
  #endif

  var body: some View {
    Form {
      todaySection
      #if os(iOS)
      rowsSection
      #endif
      addingSection
      calendarSection
      remindersSection
      badgeSection
      aiSection
      importSection
      #if !SEPTASK
      homeTileSection
      #endif
      appearanceSection
    }
    .formStyle(.grouped)
  }

  // MARK: Lists & Today

  private var todaySection: some View {
    Section {
      // Announced for the same reason as the grouping toggle below: Septask's
      // AppKit Today reads the key from UserDefaults and must rebuild.
      Toggle("Show completed tasks", isOn: TaskViewOptions.announcing($todayShowCompleted))
      Toggle(isOn: TaskViewOptions.announcing($showAging)) {
        rowLabel("Fade untouched tasks",
                 detail: "Tasks untouched for 14 days fade out and move to Faded.")
      }
      // Same switch as View ▸ Group Today by List; `announcing` is what keeps
      // Septask's AppKit list in step when it's flipped from here.
      Toggle(isOn: TaskViewOptions.announcing($todayGroupByList)) {
        rowLabel("Group by area and project",
                 detail: "Off shows one flat list, with each task's list as a subtitle.")
      }
    } header: {
      Text("Today")
    } footer: {
      Text("Undated, non-repeating tasks fade over 14 days without a touch and move to Faded until a weekly sweep lets you keep them or let them go. Touching a task restores full strength.")
    }
  }

  #if os(iOS)
  private var rowsSection: some View {
    Section {
      Picker("Title lines", selection: $titleLines) {
        Text("One").tag(1)
        Text("Two").tag(2)
        Text("Three").tag(3)
      }
    } header: {
      Text("Task rows")
    } footer: {
      Text("How far a long title wraps before it is cut off. Taller rows fit fewer tasks on screen.")
    }
  }
  #endif

  // MARK: Adding tasks

  private var addingSection: some View {
    Section {
      Toggle(isOn: $filingSuggestions) {
        rowLabel("Suggest where to file",
                 detail: "Learn where you usually file similar tasks.")
      }
    } header: {
      Text("Adding tasks")
    } footer: {
      Text("Shows a one-tap list chip on Inbox rows and while you type. The model learns on this device and your tasks never leave it.")
    }
  }

  // MARK: Connected sources

  private var calendarSection: some View {
    Section {
      Toggle("Show calendar events", isOn: $showCalendarEvents)
      NavigationLink(value: destination(.calendar)) {
        Label("Calendar access", systemImage: "calendar")
      }
    } header: {
      Text("Calendar")
    } footer: {
      Text("Shows your calendar's events in Today and Upcoming. Choose which calendars under Calendar access.")
    }
  }

  private var remindersSection: some View {
    Section {
      NavigationLink(value: destination(.reminders)) {
        Label("Reminders inbox", systemImage: "checklist")
      }
    } header: {
      Text("Reminders")
    } footer: {
      Text("Bring a Reminders list into your Inbox.")
    }
  }

  // MARK: Badge

  private var badgeSection: some View {
    Section {
      Toggle("Show overdue indicator on app icon", isOn: $taskBadge)
    } header: {
      Text("Badge")
    } footer: {
      Text("Marks the app icon while any task is overdue. Each device opts in on its own.")
    }
  }

  // MARK: Claude & AI

  private var aiSection: some View {
    Section {
      NavigationLink(value: destination(.claudeAI)) {
        Label("AI and Claude", systemImage: "brain.head.profile")
      }
    } header: {
      Text("Claude and AI")
    } footer: {
      Text("Choose how AI and Claude can create and organize tasks.")
    }
  }

  // MARK: Import

  private var importSection: some View {
    Section {
      NavigationLink(value: destination(.things)) {
        Label("Import from Things", systemImage: "square.and.arrow.down")
      }
    } header: {
      Text("Import")
    } footer: {
      Text("Move a Things database into Tasks once. Things is not changed.")
    }
  }

  // MARK: Home tile (Septena only)

  #if !SEPTASK
  private var homeTileSection: some View {
    Section {
      Picker("Tasks open in", selection: $tasksOpenInRaw) {
        ForEach(TasksOpenMode.allCases) { mode in
          Text(mode.label).tag(mode.rawValue)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } header: {
      Text("Home tile opens in")
    } footer: {
      Text("Where a tap on the Tasks tile on Home takes you.")
    }
  }
  #endif

  // MARK: Appearance

  @ViewBuilder
  private var appearanceSection: some View {
    #if SEPTASK
    Section {
      HStack {
        Text("Accent")
        Spacer()
        PaletteSwatchButton(selectedHex: theme.token(for: "tasks")) { hex in
          SettingsMirror.setSectionColor("tasks", hex: hex,
                                         context: modelContext, engine: ckEngine)
          theme.setColor(hex, for: "tasks")
        }
      }
    } header: {
      Text("Appearance")
    } footer: {
      Text("Sets the accent color used across Septena.")
    }

    // Text size and completion motion sit here, inline, instead of on a
    // separate Home page (docs/SETTINGS_FLATTEN_SPEC.md).
    TextSizeSliderSection()

    Section {
      Toggle(isOn: $completionAnimations) {
        Label("Completion animations", systemImage: "party.popper")
      }
    } footer: {
      Text("The flourish when you clear Today or check off a task. Off keeps the confirming haptic but skips the motion. Reduce Motion always overrides this.")
    }
    #else
    Section {
      NavigationLink(value: destination(.section)) {
        Label("Color, Next, and Spotlight", systemImage: "paintpalette")
      }
    } header: {
      Text("Appearance")
    } footer: {
      Text("Tasks shares these switches with the other sections. Areas and projects are managed in the Tasks tab.")
    }
    #endif
  }

  private func rowLabel(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title)
      Text(detail)
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}
