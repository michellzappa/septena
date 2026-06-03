import SwiftUI

// TimeTravelSheet — the date picker behind a drawer's calendar toolbar
// button. Replaces the always-visible `DrawerDateStrip` with the same
// look as the Tasks "When / Deadline" picker: a 7-day strip up top for
// the common "yesterday / earlier this week" jump, a "Pick a Date…" row
// that reveals a compact calendar for anything further back, and a
// "Jump to Today" reset.
//
// Unlike the task picker this is past-oriented (you review logs you
// already made) and always resolves to a concrete day — there's no
// "clear" state. Bound to the destination's YYYY-MM-DD string so the
// drawer and its day-scoped fetch stay in sync.

struct TimeTravelSheet: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.a11yMotion) private var motion

  @Binding var date: String
  /// Earliest navigable date (inclusive). Default: 5 years back, matching
  /// the old `DrawerDateStrip`.
  var minDate: Date = Calendar.current.date(byAdding: .year, value: -5, to: .now) ?? .now

  @State private var picked: Date
  @State private var showingCalendar: Bool

  /// Fitted sheet height — same compact footprint as `DatePickerSheet`.
  static let sheetHeight: CGFloat = 300

  private static let isoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.calendar = Calendar(identifier: .iso8601)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    return f
  }()

  init(date: Binding<String>) {
    _date = date
    let seed = Self.isoFormatter.date(from: date.wrappedValue)
      ?? Calendar.current.startOfDay(for: Date())
    _picked = State(initialValue: Calendar.current.startOfDay(for: seed))
    // Reveal the calendar up-front when the viewed day sits outside the
    // recent strip (older than 6 days back) — the strip already covers
    // the past week.
    let today = Calendar.current.startOfDay(for: Date())
    let days = Calendar.current.dateComponents([.day], from: seed, to: today).day ?? 0
    _showingCalendar = State(initialValue: days < 0 || days > 6)
  }

  private var isToday: Bool {
    Calendar.current.isDateInToday(picked)
  }

  private func commit(_ day: Date) {
    date = Self.isoFormatter.string(from: Calendar.current.startOfDay(for: day))
    dismiss()
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        WeekStrip(selected: picked, range: .recent) { d in
          commit(d)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 6)
        .padding(.bottom, 8)

        Hairline()

        if showingCalendar {
          HStack(spacing: 14) {
            Image(systemName: "calendar")
              .scaledFont(size: 18)
              .foregroundStyle(Theme.inkSecondary)
              .frame(width: 24)
            Text("Date")
              .font(.septenaSidebarRow)
              .foregroundStyle(.primary)
            Spacer()
            DatePicker("", selection: $picked, in: minDate ... Date(),
                       displayedComponents: [.date])
              .labelsHidden()
              .datePickerStyle(.compact)
              .tint(theme.accent)
          }
          .padding(.horizontal, Theme.hPadding)
          .frame(height: Theme.sidebarRowHeight)
        } else {
          Button {
            motion.run(.easeInOut(duration: 0.18)) { showingCalendar = true }
          } label: {
            HStack(spacing: 14) {
              Image(systemName: "calendar")
                .scaledFont(size: 18)
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 24)
              Text("Pick a Date…")
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

        Spacer(minLength: 0)

        VStack(spacing: 6) {
          // Primary action confirms whatever the calendar field shows —
          // the week strip taps commit immediately, so this carries the
          // "Pick a Date…" path.
          Button {
            commit(picked)
          } label: {
            Text("View This Day")
              .scaledFont(size: 16, weight: .semibold)
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
              .background(theme.accent)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)

          Button {
            commit(Date())
          } label: {
            Text("Jump to Today")
              .scaledFont(size: 15, weight: .medium)
              .foregroundStyle(isToday ? Theme.inkSecondary : theme.accent)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 8)
          }
          .buttonStyle(.plain)
          .disabled(isToday)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.bottom, 12)
      }
      .navigationTitle("Time Travel")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }
}
