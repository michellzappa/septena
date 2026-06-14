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

  var body: some View {
    Group {
      switch bridge.access {
      case .granted:
        if sourceList == nil {
          if showsSetupCTAs { pickListCTA }
        } else if !pairs.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(pairs, id: \.view.id) { pair in
              reminderRow(pair)
            }
          }
          .padding(.horizontal, Theme.hPadding)
          .padding(.top, 8)
          .padding(.bottom, 16)
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
             subtitle: "Mirror items from Apple Reminders into your Inbox.")
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var grantAccessCTA: some View {
    Button { nav.showSettings = true } label: {
      ctaRow(icon: "lock.open",
             title: "Connect Apple Reminders",
             subtitle: "Grant access to mirror reminders into your Inbox.")
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var deniedNote: some View {
    ctaRow(icon: "exclamationmark.triangle",
           title: "Reminders access blocked",
           subtitle: "Enable Septena in System Settings → Privacy → Reminders.")
  }

  @ViewBuilder
  private func ctaRow(icon: String, title: String, subtitle: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .scaledFont(size: 14, weight: .semibold)
        .foregroundStyle(theme.accent)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkPrimary)
        Text(subtitle)
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      Color.gray.opacity(0.08),
      in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
    )
    .padding(.horizontal, Theme.hPadding)
    .padding(.top, 8)
    .padding(.bottom, 16)
    .contentShape(Rectangle())
  }

  // MARK: - Header

  @ViewBuilder
  private var header: some View {
    HStack {
      Text("From Reminders")
        .scaledFont(size: 15, weight: .semibold)
        .foregroundStyle(Theme.inkPrimary)
      Spacer()
      Button {
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
      }
      .buttonStyle(.plain)
      .disabled(bulkImporting || importingID != nil)
    }
    .padding(.bottom, 2)
  }

  // MARK: - Row

  @ViewBuilder
  private func reminderRow(_ pair: (reminder: EKReminder, view: ImportedReminder)) -> some View {
    let isImporting = importingID == pair.view.id
    Button {
      Task { await importOne(pair) }
    } label: {
      HStack(spacing: 10) {
        if isImporting {
          ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
        } else {
          Image(systemName: "arrow.down")
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(Theme.iconMuted)
            .frame(width: 16, height: 16)
        }
        Text(pair.view.title)
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkPrimary)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer()
        if let due = pair.view.dueDate {
          Text(shortDate(due))
            .font(.septenaMeta)
            .foregroundStyle(isOverdue(due) ? Theme.overdueRed : Theme.inkSecondary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(
        Color.gray.opacity(0.08),
        in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
      )
      .contentShape(Rectangle())
      .opacity(isImporting ? 0.5 : 1)
    }
    .buttonStyle(.plain)
    .disabled(isImporting || bulkImporting)
  }

  private func isOverdue(_ d: Date) -> Bool {
    let today = Calendar.current.startOfDay(for: Date())
    return Calendar.current.startOfDay(for: d) <= today
  }

  private func shortDate(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f.string(from: d)
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
    mutator.create(
      title: pair.view.title,
      deadline: pair.view.dueDate,
      notes: pair.view.notes
    )
    try? bridge.delete([pair.reminder])
    pairs.removeAll { $0.view.id == pair.view.id }
    onImported()
  }

  private func importAll() async {
    bulkImporting = true
    defer { bulkImporting = false }
    var succeeded: [EKReminder] = []
    var succeededIDs: Set<String> = []
    for pair in pairs {
      mutator.create(
        title: pair.view.title,
        deadline: pair.view.dueDate,
        notes: pair.view.notes
      )
      succeeded.append(pair.reminder)
      succeededIDs.insert(pair.view.id)
    }
    if !succeeded.isEmpty {
      try? bridge.delete(succeeded)
      pairs.removeAll { succeededIDs.contains($0.view.id) }
      onImported()
    }
  }
}
