import SwiftUI

// MARK: - Checkbox

struct ThingsCheckbox: View {
  @EnvironmentObject var theme: SectionTheme
  /// Optional override — used by non-task items (habits/supplements/chores)
  /// to wear their section accent. `nil` means "use the Tasks section accent".
  var tint: Color? = nil
  let isDone: Bool
  let onToggle: () -> Void

  /// Square with a small corner radius — matches Things' checkbox shape.
  private static let size: CGFloat = 18
  private static let cornerRadius: CGFloat = 4

  var body: some View {
    let fill = tint ?? theme.accent
    Button(action: onToggle) {
      ZStack {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
          .stroke(fill.opacity(0.5), lineWidth: 1.5)
          .frame(width: Self.size, height: Self.size)
        if isDone {
          RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(fill)
            .frame(width: Self.size, height: Self.size)
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
        }
      }
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Screen title

struct ScreenTitle: View {
  let icon: String
  let iconTint: Color
  let title: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .regular))
        .foregroundStyle(iconTint)
      Text(title)
        .font(.septenaScreenTitle)
        .foregroundStyle(Theme.inkPrimary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Theme.hPadding)
    .padding(.top, 12)
    .padding(.bottom, 18)
  }
}

// MARK: - Magic Plus floating button

struct MagicPlusButton: View {
  @EnvironmentObject var theme: SectionTheme
  let action: () -> Void
  @State private var pressed = false

  var body: some View {
    Button(action: { Haptics.tap(); action() }) {
      if #available(iOS 26, *) {
        Image(systemName: "plus")
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(theme.accent)
          .frame(width: 56, height: 56)
          .glassEffect(.regular.interactive(), in: .circle)
      } else {
        Image(systemName: "plus")
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 56, height: 56)
          .background(theme.accent)
          .clipShape(Circle())
          .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
      }
    }
    .buttonStyle(.plain)
    .scaleEffect(pressed ? 0.9 : 1)
    .animation(.easeOut(duration: 0.15), value: pressed)
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in pressed = true }
        .onEnded { _ in pressed = false }
    )
  }
}

// MARK: - Inline new task row

struct InlineNewTaskRow: View {
  @Binding var title: String
  @Binding var notes: String
  var defaultWhen: String = "Today"
  var defaultWhenIcon: String = "star.fill"
  var defaultWhenTint: Color = Theme.inkSecondary
  var onCommit: () -> Void
  var onCancel: () -> Void
  @FocusState private var focused: Field?

  enum Field { case title, notes }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        // Square placeholder (non-interactive — the task doesn't exist yet).
        // Same shape & size as ThingsCheckbox so the row aligns with neighbors.
        RoundedRectangle(cornerRadius: 4)
          .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
          .frame(width: 18, height: 18)
          .padding(.top, 2)

        VStack(alignment: .leading, spacing: 6) {
          TextField("New To-Do", text: $title)
            .font(.septenaTaskTitle)
            .focused($focused, equals: .title)
            .submitLabel(.next)
            .onSubmit {
              if title.trimmingCharacters(in: .whitespaces).isEmpty {
                onCancel()
              } else {
                onCommit()
              }
            }
          TextField("Notes", text: $notes, axis: .vertical)
            .font(.septenaNotes)
            .foregroundStyle(.secondary)
            .focused($focused, equals: .notes)
            .lineLimit(1...4)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.vertical, 12)

      HStack(spacing: 6) {
        Image(systemName: defaultWhenIcon)
          .font(.system(size: 14))
          .foregroundStyle(defaultWhenTint)
        Text(defaultWhen)
          .font(.septenaTaskTitle)
          .foregroundStyle(.primary)
        Spacer()
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.bottom, 14)
    }
    // Same full-bleed treatment as the open-edit card: matches the closed row
    // position exactly, separated from neighbors by background contrast + a
    // subtle shadow. No outer inset, no border.
    .background(Theme.cardSurface)
    .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 0)
    // Absorb in-card taps so the parent's "tap empty area to dismiss" gesture
    // doesn't fire when tapping the card's own padding.
    .contentShape(Rectangle())
    .onTapGesture { /* swallow */ }
    .onAppear { focused = .title }
  }
}

// MARK: - Inline edit task row

struct InlineEditTaskRow: View {
  @EnvironmentObject var theme: SectionTheme
  let task: EngageTask
  @Binding var title: String
  @Binding var notes: String
  let isDone: Bool
  /// Labels resolved from current data (project title or area title) so the
  /// chip reads "Septena" instead of the raw id.
  var projectTitle: String? = nil
  var areaTitle: String? = nil
  var onToggleDone: () -> Void
  var onCommit: () -> Void
  var onCancel: () -> Void
  var onSchedule: (() -> Void)? = nil
  var onDeadline: (() -> Void)? = nil
  var onMove: (() -> Void)? = nil
  var onRepeat: (() -> Void)? = nil
  @FocusState private var focused: Field?

  enum Field { case title, notes }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        // Same component & dimensions as the closed row — keeps the checkbox
        // and title in the same screen position when the card opens.
        ThingsCheckbox(isDone: isDone, onToggle: onToggleDone)
          .padding(.top, 2)

        VStack(alignment: .leading, spacing: 6) {
          TextField("Title", text: $title)
            .font(.septenaTaskTitle)
            .focused($focused, equals: .title)
            .submitLabel(.next)
            .onSubmit { focused = .notes }
          TextField("Notes", text: $notes, axis: .vertical)
            .font(.septenaNotes)
            .foregroundStyle(.secondary)
            .focused($focused, equals: .notes)
            .lineLimit(1...6)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.vertical, 12)

      // Bottom row, Things-style: When pill on the left (with state-colored
      // icon + text, no capsule background), icon-only action buttons on the
      // right (repeat / move / deadline). Tap each to open its picker.
      HStack(spacing: 0) {
        whenPill
        Spacer()
        actionIcons
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.bottom, 14)
    }
    // Full-bleed background so the open card aligns exactly with the closed
    // row — no horizontal shift on focus. A subtle shadow above/below
    // separates the card from neighboring rows.
    .background(Theme.cardSurface)
    .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 0)
    // Absorb taps inside the card so the parent's "tap empty area to dismiss"
    // gesture doesn't fire when tapping the card's own padding/background.
    .contentShape(Rectangle())
    .onTapGesture { /* swallow */ }
    .onAppear { focused = .title }
    // Keyboard dismissed (via scroll-down or tap-outside) → commit. Without
    // this, blur leaves the card open with no field focused.
    .onChange(of: focused) { _, new in
      if new == nil {
        if title.trimmingCharacters(in: .whitespaces).isEmpty {
          onCancel()
        } else {
          onCommit()
        }
      }
    }
  }

  // MARK: - Action pills (tappable; sans-serif, slightly larger than meta chips)

  // MARK: - When pill (Things-style: state-colored icon + text, no capsule bg)

  @ViewBuilder
  private var whenPill: some View {
    let parsed = task.scheduled.flatMap(SeptenaDate.parse)
    Button(action: { Haptics.pick(); onSchedule?() }) {
      HStack(spacing: 8) {
        Image(systemName: whenIcon(for: parsed))
          .font(.system(size: 16))
          .foregroundStyle(whenIconTint(for: parsed))
        Text(whenLabel(for: parsed))
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(whenTextTint(for: parsed))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func whenIcon(for d: Date?) -> String {
    guard let d else { return "calendar" }
    let cal = Calendar.current
    if cal.isDateInToday(d)    { return "star.fill" }
    if cal.isDateInTomorrow(d) { return "sunrise.fill" }
    return "calendar"
  }

  private func whenIconTint(for d: Date?) -> Color {
    guard let d else { return Theme.inkSecondary.opacity(0.6) }
    return Calendar.current.isDateInToday(d) ? .yellow : Theme.inkSecondary
  }

  private func whenTextTint(for d: Date?) -> Color {
    d == nil ? Theme.inkSecondary.opacity(0.7) : Theme.inkPrimary
  }

  private func whenLabel(for d: Date?) -> String {
    guard let d else { return "When" }
    return dateLabel(d)
  }

  // MARK: - Right-side action icons (icon-only, no capsule background)

  @ViewBuilder
  private var actionIcons: some View {
    HStack(spacing: 22) {
      // Repeat — colored when set, muted when unset
      actionIcon(
        systemName: "arrow.triangle.2.circlepath",
        tint: task.recurrence == nil ? Theme.inkSecondary.opacity(0.6) : Theme.inkPrimary,
        action: { onRepeat?() }
      )
      // Move — icon reflects target (project / area / inbox)
      actionIcon(
        systemName: moveIcon,
        tint: (projectTitle != nil || areaTitle != nil) ? Theme.inkPrimary : Theme.inkSecondary.opacity(0.6),
        action: { onMove?() }
      )
      // Deadline — red when overdue/today, muted otherwise
      actionIcon(
        systemName: "flag",
        tint: deadlineIconTint,
        action: { onDeadline?() }
      )
    }
  }

  private var moveIcon: String {
    if projectTitle != nil { return "number" }
    if areaTitle != nil    { return "folder" }
    return "tray"
  }

  private var deadlineIconTint: Color {
    guard let d = task.due.flatMap(SeptenaDate.parse) else {
      return Theme.inkSecondary.opacity(0.6)
    }
    return dueTint(d)
  }

  @ViewBuilder
  private func actionIcon(systemName: String, tint: Color, action: @escaping () -> Void) -> some View {
    Button(action: { Haptics.pick(); action() }) {
      Image(systemName: systemName)
        .font(.system(size: 18, weight: .regular))
        .foregroundStyle(tint)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func dateLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f.string(from: d)
  }

  private func dueTint(_ d: Date) -> Color {
    let today = Calendar.current.startOfDay(for: Date())
    return Calendar.current.startOfDay(for: d) <= today ? Theme.overdueRed : Theme.inkSecondary
  }

}

// MARK: - When picker sheet

/// "When" — schedule a task for a date, defer to Someday, or clear the
/// scheduled date. Matches Things' When sheet shape. `due` has a separate
/// picker (DeadlinePickerSheet) because deadlines are concrete dates only.
struct WhenPickerSheet: View {
  @EnvironmentObject var theme: SectionTheme
  let onPick: (Date?) -> Void
  let onSomeday: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var customDate = Date()
  @State private var showingCustom = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if showingCustom {
          DatePicker("Date", selection: $customDate, displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .padding(.horizontal, Theme.hPadding)
          Spacer()
          Button {
            onPick(Calendar.current.startOfDay(for: customDate))
            dismiss()
          } label: {
            Text("Set Date")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(theme.accent)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)
          .padding(.horizontal, Theme.hPadding)
          .padding(.bottom, 20)
        } else {
          option(icon: "star.fill", tint: theme.accent, title: "Today") {
            onPick(Calendar.current.startOfDay(for: Date())); dismiss()
          }
          Hairline()
          option(icon: "sunrise.fill", tint: Theme.inkSecondary, title: "Tomorrow") {
            let d = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
            onPick(d); dismiss()
          }
          Hairline()
          option(icon: "calendar", tint: Theme.inkSecondary, title: "Upcoming…") {
            showingCustom = true
          }
          Hairline()
          option(icon: "archivebox.fill", tint: Theme.inkSecondary, title: "Someday") {
            onSomeday(); dismiss()
          }
          Hairline()
          option(icon: "xmark.circle", tint: .secondary, title: "No Date") {
            onPick(nil); dismiss()
          }
          Spacer()
        }
      }
      .navigationTitle("When")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  @ViewBuilder
  private func option(icon: String, tint: Color, title: String, action: @escaping () -> Void) -> some View {
    Button(action: { Haptics.pick(); action() }) {
      HStack(spacing: 14) {
        Image(systemName: icon)
          .font(.system(size: 18))
          .foregroundStyle(tint)
          .frame(width: 24)
        Text(title)
          .font(.septenaSidebarRow)
          .foregroundStyle(.primary)
        Spacer()
      }
      .padding(.horizontal, Theme.hPadding)
      .frame(height: Theme.sidebarRowHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Deadline picker sheet

/// "Deadline" — set a hard due date, or clear it. Deliberately *just* a
/// date picker (no Today/Tomorrow shortcuts) because deadlines are
/// concrete dates, not loose intentions. Matches Things' Deadline sheet.
struct DeadlinePickerSheet: View {
  @EnvironmentObject var theme: SectionTheme
  let initialDate: Date?
  let onPick: (Date?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var date: Date

  init(initialDate: Date? = nil, onPick: @escaping (Date?) -> Void) {
    self.initialDate = initialDate
    self.onPick = onPick
    _date = State(initialValue: initialDate ?? Calendar.current.startOfDay(for: Date()))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        DatePicker("Deadline", selection: $date, displayedComponents: [.date])
          .datePickerStyle(.graphical)
          .padding(.horizontal, Theme.hPadding)

        Spacer()

        VStack(spacing: 10) {
          Button {
            onPick(Calendar.current.startOfDay(for: date))
            dismiss()
          } label: {
            Text(initialDate == nil ? "Set Deadline" : "Update Deadline")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(theme.accent)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)

          if initialDate != nil {
            Button {
              Haptics.warning()
              onPick(nil)
              dismiss()
            } label: {
              Text("No Deadline")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.overdueRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.bottom, 20)
      }
      .navigationTitle("Deadline")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }
}

// MARK: - Recurrence picker sheet

/// "Repeat" — set or clear a recurrence rule. v1: daily / weekly / monthly,
/// interval stepper, and fixed-vs-after-completion toggle. Things' canonical
/// picker has more (weekday selection, ends-rules) — to be added when needed.
struct RecurrencePickerSheet: View {
  @EnvironmentObject var theme: SectionTheme
  let initial: Recurrence?
  let onPick: (Recurrence?) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var unit: Recurrence.Unit
  @State private var interval: Int
  @State private var afterCompletion: Bool

  init(initial: Recurrence?, onPick: @escaping (Recurrence?) -> Void) {
    self.initial = initial
    self.onPick = onPick
    _unit = State(initialValue: initial?.unit ?? .day)
    _interval = State(initialValue: initial?.interval ?? 1)
    _afterCompletion = State(initialValue: initial?.afterCompletion ?? true)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // Unit segmented
        Picker("Unit", selection: $unit) {
          Text("Day").tag(Recurrence.Unit.day)
          Text("Week").tag(Recurrence.Unit.week)
          Text("Month").tag(Recurrence.Unit.month)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 16)

        // Interval stepper
        HStack {
          Text("Every")
            .font(.septenaSidebarRow)
            .foregroundStyle(Theme.inkPrimary)
          Spacer()
          Stepper(value: $interval, in: 1...99) {
            Text("\(interval) \(unitNoun(plural: interval != 1))")
              .font(.septenaSidebarRow)
              .foregroundStyle(Theme.inkSecondary)
          }
          .labelsHidden()
          Text("\(interval) \(unitNoun(plural: interval != 1))")
            .font(.septenaSidebarRow)
            .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 18)

        // Fixed vs after-completion toggle
        Toggle(isOn: $afterCompletion) {
          VStack(alignment: .leading, spacing: 2) {
            Text("After completion")
              .font(.septenaSidebarRow)
              .foregroundStyle(Theme.inkPrimary)
            Text(afterCompletion
                 ? "Next instance \(interval) \(unitNoun(plural: interval != 1)) after you mark this done."
                 : "Next instance \(interval) \(unitNoun(plural: interval != 1)) after the previous scheduled date.")
              .font(.caption)
              .foregroundStyle(Theme.inkSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .tint(theme.accent)
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 18)

        Spacer()

        VStack(spacing: 10) {
          Button {
            onPick(Recurrence(unit: unit, interval: interval, afterCompletion: afterCompletion))
            dismiss()
          } label: {
            Text(initial == nil ? "Set Repeat" : "Update Repeat")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(theme.accent)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)

          if initial != nil {
            Button {
              Haptics.warning()
              onPick(nil)
              dismiss()
            } label: {
              Text("Don't Repeat")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.overdueRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.bottom, 20)
      }
      .navigationTitle("Repeat")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private func unitNoun(plural: Bool) -> String {
    switch unit {
    case .day:   return plural ? "days" : "day"
    case .week:  return plural ? "weeks" : "week"
    case .month: return plural ? "months" : "month"
    }
  }
}

// MARK: - Move picker sheet

struct MovePickerSheet: View {
  let areas: [Area]
  let projects: [Project]
  let onPick: (_ areaId: String?, _ projectId: String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          optionRow(icon: "tray.fill", tint: Theme.inkSecondary, title: "Inbox (no area/project)") {
            onPick(nil, nil); dismiss()
          }
          Hairline()

          let topProjects = filteredTopProjects
          if !topProjects.isEmpty {
            sectionHeader("Projects")
            ForEach(topProjects) { p in
              optionRow(icon: "circle", tint: .secondary, title: p.title) {
                onPick(nil, p.id); dismiss()
              }
              Hairline()
            }
          }

          ForEach(areas) { area in
            sectionHeader(area.title.uppercased())
            optionRow(icon: "hexagon.fill", tint: .orange, title: "(area only)") {
              onPick(area.id, nil); dismiss()
            }
            Hairline()
            ForEach(projectsIn(area.id)) { p in
              optionRow(icon: "circle", tint: .secondary, title: p.title, indent: true) {
                onPick(area.id, p.id); dismiss()
              }
              Hairline()
            }
          }
        }
      }
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
      .navigationTitle("Move To")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private var filteredTopProjects: [Project] {
    let q = query.lowercased()
    return projects
      .filter { $0.area == nil && $0.status == .active }
      .filter { q.isEmpty || $0.title.lowercased().contains(q) }
  }

  private func projectsIn(_ areaId: String) -> [Project] {
    let q = query.lowercased()
    return projects
      .filter { $0.area == areaId && $0.status == .active }
      .filter { q.isEmpty || $0.title.lowercased().contains(q) }
  }

  @ViewBuilder
  private func sectionHeader(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12, weight: .bold))
      .tracking(0.8)
      .foregroundStyle(.secondary)
      .padding(.horizontal, Theme.hPadding)
      .padding(.top, 16)
      .padding(.bottom, 6)
  }

  @ViewBuilder
  private func optionRow(icon: String, tint: Color, title: String, indent: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: { Haptics.pick(); action() }) {
      HStack(spacing: 14) {
        Image(systemName: icon)
          .font(.system(size: 16))
          .foregroundStyle(tint)
          .frame(width: 24)
        Text(title)
          .font(.septenaSidebarRow)
          .foregroundStyle(.primary)
        Spacer()
      }
      .padding(.leading, indent ? Theme.hPadding + 20 : Theme.hPadding)
      .padding(.trailing, Theme.hPadding)
      .frame(height: Theme.rowHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Paper-themed action sheet
//
// iOS Menu pops with system materials (translucent gray) and can't be
// re-themed. For action lists ("Mark Someday / Cancel / Delete") we want
// the same warm-paper surface as the rest of the app, so we present a
// custom bottom sheet of action rows instead of a Menu.

struct ActionSheet: View {
  struct Action: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var role: ButtonRole? = nil          // .destructive renders red
    let perform: () -> Void
  }

  let title: String?
  let actions: [Action]
  @EnvironmentObject var theme: SectionTheme
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      if let title {
        Text(title)
          .font(.septenaSectionTitle)
          .foregroundStyle(Theme.inkPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Theme.hPadding)
          .padding(.top, 18)
          .padding(.bottom, 8)
        Hairline()
      }

      ForEach(actions) { action in
        Button {
          action.perform()
          dismiss()
        } label: {
          HStack(spacing: 14) {
            Image(systemName: action.icon)
              .font(.system(size: 16))
              .foregroundStyle(action.role == .destructive ? Theme.overdueRed : Theme.inkSecondary)
              .frame(width: 22)
            Text(action.title)
              .font(.septenaSidebarRow)
              .foregroundStyle(action.role == .destructive ? Theme.overdueRed : Theme.inkPrimary)
            Spacer()
          }
          .padding(.horizontal, Theme.hPadding)
          .frame(height: Theme.sidebarRowHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Hairline()
      }

      Button("Cancel") { dismiss() }
        .font(.septenaButton)
        .foregroundStyle(theme.accent)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Theme.paperBackground.ignoresSafeArea())
  }
}

// MARK: - Hairline divider

struct Hairline: View {
  var leadingInset: CGFloat = Theme.hPadding
  var body: some View {
    Rectangle()
      .fill(Theme.divider)
      .frame(height: 0.5)
      .padding(.leading, leadingInset)
  }
}
