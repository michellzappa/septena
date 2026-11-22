import SwiftUI
import EventKit

// Mounted at the top of the Inbox. Mirrors pending items from the user's
// nominated Reminders list as task-style rows. Tapping a row imports just that
// item; "Import All" imports the lot. Every successful import deletes the
// original reminder so dedupe is automatic.

struct RemindersInboxSection: View {
  @Environment(TaskMutator.self) private var mutator
  @Environment(SectionTheme.self) private var theme
  @Environment(NavigationState.self) private var nav
  @Environment(DayClock.self) private var clock
  /// Parent calls this after a successful import so the inbox below refreshes.
  let onImported: () -> Void
  /// Whether to surface the setup CTAs (grant access / pick a list / denied
  /// note). On the Today screen we pass `false` so only *actual pending
  /// imports* appear in the triage zone — an unconfigured user sees nothing,
  /// not a permanent setup prompt. Defaults to `true` for the dedicated inbox.
  var showsSetupCTAs: Bool = true

  /// Plain `let` — RemindersBridge is a shared @Observable singleton, and
  /// SwiftUI's observation macros track property accesses on the instance
  /// directly. Wrapping in `@State` here would imply the view owns the
  /// instance's lifecycle, which it doesn't.
  private let bridge = RemindersBridge.shared

  // Derived from the bridge so the very first render reflects the persisted
  // source-list selection. Previously these were @State initialised to nil,
  // which made the section flash the 'Pick a Reminders list' CTA on every
  // Inbox open until .task ran reload() one frame later.
  private var sourceListID: String? { bridge.sourceListID }
  private var sourceList: EKCalendar? { bridge.sourceList() }

  @State private var pairs: [(reminder: EKReminder, view: ImportedReminder)] = []
  @State private var importingID: String?
  @State private var bulkImporting = false

  /// Matches `TaskRow`: honor Settings ▸ Tasks ▸ Rows ▸ "Title lines" on iOS.
  @AppStorage(SettingsKey.tasksTitleLines) private var titleLinesSetting: Int = 2

  private var titleLineLimit: Int {
    #if os(iOS)
    return min(3, max(1, titleLinesSetting))
    #else
    return 2
    #endif
  }

  private var todayAnchor: Date {
    Calendar.current.startOfDay(for: SeptenaDate.parse(clock.today) ?? clock.now)
  }

  var body: some View {
    // A VStack, not a Group: a modifier on a Group attaches to each child, so
    // when every branch renders nothing (no pending reminders) the `.task` and
    // `.onReceive` below never ran, and the section could never load (see
    // CLAUDE.md, "Never hang .task / .onAppear / .onReceive off a Group").
    VStack(alignment: .leading, spacing: 0) {
      switch bridge.access {
      case .granted:
        if sourceList == nil {
          if showsSetupCTAs { pickListCTA }
        } else if !pairs.isEmpty {
          VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(pairs.enumerated()), id: \.element.view.id) { idx, pair in
              reminderRow(pair)
                .taskCardChrome(TaskCardPosition(index: idx, count: pairs.count))
            }
          }
        }
        // If sourceList is set but pairs is empty, render nothing — list
        // is nominated and just has no pending reminders. Don't clutter.
      case .notDetermined:
        if showsSetupCTAs { grantAccessCTA }
      case .denied, .writeOnly:
        if showsSetupCTAs { deniedNote }
      }
    }
    // `.task(id:)` fires on first appear AND whenever the source list ID
    // changes, so picking a different list in Settings auto-refreshes the
    // section without needing a remount.
    .task(id: bridge.sourceListID) { await reload() }
    .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
      Task { await reload() }
    }
  }

  // MARK: - CTAs surfaced when the section can't show anything yet

  @ViewBuilder
  private var pickListCTA: some View {
    Button { nav.showSettings = true } label: {
      ctaRow(icon: "checklist",
             title: "Pick a Reminders list",
             subtitle: "Move reminders from a list into your Inbox.")
    }
    .buttonStyle(.plain)
    .taskCardChrome(.solo)
  }

  @ViewBuilder
  private var grantAccessCTA: some View {
    Button { nav.showSettings = true } label: {
      ctaRow(icon: "lock.open",
             title: "Connect Apple Reminders",
             subtitle: "Allow access to move reminders into your Inbox.")
    }
    .buttonStyle(.plain)
    .taskCardChrome(.solo)
  }

  @ViewBuilder
  private var deniedNote: some View {
    ctaRow(icon: "exclamationmark.triangle",
           title: "Reminders access blocked",
           subtitle: "Enable \(AppDisplayName.current) in System Settings → Privacy → Reminders.")
      .taskCardChrome(.solo)
  }

  @ViewBuilder
  private func ctaRow(icon: String, title: String, subtitle: String) -> some View {
    HStack(alignment: .top, spacing: Theme.iconTextGap) {
      Image(systemName: icon)
        .scaledFont(size: 16)
        .foregroundStyle(theme.accent)
        .frame(width: Theme.checkboxTap, alignment: .center)
        .offset(x: -Theme.checkboxLeadingNudge)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkPrimary)
        Text(subtitle)
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, TaskCardMetrics.contentInset)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
  }

  // MARK: - Header

  @ViewBuilder
  private var header: some View {
    #if os(macOS)
    let headerTopPadding: CGFloat = 24
    #else
    let headerTopPadding: CGFloat = 18
    #endif
    HStack(spacing: Theme.iconTextGap) {
      Image(systemName: "checklist")
        .scaledFont(size: 16)
        .foregroundStyle(Theme.iconMuted)
        .frame(width: Theme.checkboxTap, alignment: .center)
        .offset(x: -Theme.checkboxLeadingNudge)
      Text("From Reminders")
        .sectionGroupHeaderTitleStyle()
      Spacer()
      // Bulk import only earns a button when there is more than one item waiting.
      if pairs.count > 1 {
        Button {
          Haptics.tick()
          Task { await importAll() }
        } label: {
          HStack(spacing: 4) {
            if bulkImporting {
              ProgressView().scaleEffect(0.6)
            } else {
              Image(systemName: "arrow.down")
                .scaledFont(size: 11, weight: .semibold)
            }
            Text(bulkImporting ? "Importing…" : "Import All")
              .scaledFont(size: 13, weight: .semibold)
          }
          .foregroundStyle(Color.accentColor)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .inlineHover(capsule: true)
        .disabled(bulkImporting || importingID != nil)
      }
    }
    .padding(.leading, TaskCardMetrics.headerLeading)
    .padding(.trailing, TaskCardMetrics.margin)
    .padding(.top, headerTopPadding)
    .padding(.bottom, 8)
  }

  // MARK: - Row

  @ViewBuilder
  private func reminderRow(_ pair: (reminder: EKReminder, view: ImportedReminder)) -> some View {
    let isImporting = importingID == pair.view.id
    let hasNotes = !(pair.view.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    Button {
      Haptics.tick()
      Task { await importOne(pair) }
    } label: {
      CheckableRow(
        title: pair.view.title,
        showsNotesGlyph: hasNotes,
        titleBandHeight: Theme.checkboxTap,
        titleLineLimit: titleLineLimit,
        leading: {
          importGlyph(isImporting: isImporting)
        },
        trailing: {
          reminderTrailing(dueDate: pair.view.dueDate, hasNotes: hasNotes)
        }
      )
      .contentShape(Rectangle())
      .opacity(isImporting ? 0.5 : 1)
    }
    .buttonStyle(.plain)
    .disabled(isImporting || bulkImporting)
    .accessibilityLabel(String(localized: "Import “\(pair.view.title)” from Reminders",
                               comment: "Reminder row import accessibility label"))
  }

  /// Sits in the checkbox slot (`Theme.checkboxTap`, nudged to the shared
  /// leading grid): importing a reminder takes the place of checking a task.
  @ViewBuilder
  private func importGlyph(isImporting: Bool) -> some View {
    Group {
      if isImporting {
        ProgressView()
          #if os(macOS)
          .controlSize(.small)
          .scaleEffect(0.65)
          #else
          .scaleEffect(0.7)
          #endif
      } else {
        Image(systemName: "arrow.down")
          #if os(macOS)
          .scaledFont(size: 12, weight: .semibold)
          #else
          .scaledFont(size: 14, weight: .semibold)
          #endif
          .foregroundStyle(Theme.checkboxStroke)
      }
    }
    .frame(width: Theme.checkboxTap, height: Theme.checkboxTap)
    .offset(x: -Theme.checkboxLeadingNudge)
  }

  /// Same deadline + notes treatment as `TaskRow.trailing`.
  @ViewBuilder
  private func reminderTrailing(dueDate: Date?, hasNotes: Bool) -> some View {
    if let due = dueDate {
      let cal = Calendar.current
      let dueDay = cal.startOfDay(for: due)
      if dueDay <= todayAnchor {
        Text(cal.isDateInToday(due) ? "Today" : TaskRow.shortDate(due))
          .font(.septenaMeta.weight(.semibold))
          .foregroundStyle(Theme.overdueRed)
      } else {
        HStack(spacing: 4) {
          Image(systemName: "flag.fill").scaledFont(size: 12)
          Text(TaskRow.shortDate(due)).font(.septenaMeta)
        }
        .foregroundStyle(Theme.inkSecondary)
      }
    }
    if hasNotes {
      TaskNotesGlyph.view
    }
  }

  // MARK: - Load / import

  private func reload() async {
    SeptenaLog.info("Reminders reload: access=\(bridge.access) sourceID=\(sourceListID ?? "nil") sourceList=\(sourceList?.title ?? "nil")")
    guard bridge.access == .granted, let cal = sourceList else {
      pairs = []
      return
    }
    let fetched = await bridge.pendingReminders(in: cal)
    SeptenaLog.info("Reminders reload: fetched \(fetched.count) pending from '\(cal.title)'")
    pairs = fetched.map { ($0, ImportedReminder($0)) }
  }

  private func importOne(_ pair: (reminder: EKReminder, view: ImportedReminder)) async {
    importingID = pair.view.id
    defer { importingID = nil }
    let created = mutator.create(
      title: pair.view.title,
      deadline: pair.view.dueDate,
      notes: pair.view.notes
    )
    try? bridge.delete([pair.reminder])
    pairs.removeAll { $0.view.id == pair.view.id }
    TaskNotices.completeStep(.importTasks)
    TaskUndo.recordCreate(
      name: String(localized: "Import Reminder", comment: "Undo action"),
      ids: [created.id], mutator: mutator,
      rebuild: { [mutator] in
        [mutator.create(title: pair.view.title,
                        deadline: pair.view.dueDate,
                        notes: pair.view.notes).id]
      })
    onImported()
  }

  private func importAll() async {
    bulkImporting = true
    defer { bulkImporting = false }
    let batch = pairs
    var createdIDs: [String] = []
    var succeeded: [EKReminder] = []
    var succeededIDs: Set<String> = []
    for pair in batch {
      let created = mutator.create(
        title: pair.view.title,
        deadline: pair.view.dueDate,
        notes: pair.view.notes
      )
      createdIDs.append(created.id)
      succeeded.append(pair.reminder)
      succeededIDs.insert(pair.view.id)
    }
    if !succeeded.isEmpty {
      try? bridge.delete(succeeded)
      pairs.removeAll { succeededIDs.contains($0.view.id) }
      TaskNotices.completeStep(.importTasks)
      TaskUndo.recordCreate(
        name: String(localized: "Import Reminders", comment: "Undo action"),
        ids: createdIDs, mutator: mutator,
        rebuild: { [mutator] in
          batch.map { pair in
            mutator.create(title: pair.view.title,
                           deadline: pair.view.dueDate,
                           notes: pair.view.notes).id
          }
        })
      onImported()
    }
  }
}
