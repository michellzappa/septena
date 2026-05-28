import SwiftUI

// Compact date navigator surfaced by `SectionDrawer` when the
// destination passes a `currentDate` binding. Lets the user "time
// travel" within a section drawer without leaving the page — replacing
// the per-section BrowseXDaySheet detours.
//
// Layout: [<] [Friday · May 28]  [Today]  [>]
//
// • Left/right chevrons jump one day at a time.
// • Tapping the date label opens an inline DatePicker for jumping
//   weeks/months. Bound to the underlying String via Binding<Date>.
// • The "Today" pill appears (and is enabled) only when the user isn't
//   already on today. Tap returns to today instantly.

struct DrawerDateStrip: View {
  @Binding var date: String
  /// Earliest navigable date (inclusive). Default: 5 years back so the
  /// chevrons never wander into a meaningless distant past for users
  /// who don't have years of data.
  var minDate: Date = Calendar.current.date(byAdding: .year, value: -5, to: .now) ?? .now
  /// Latest navigable date (inclusive). Default: today — sections
  /// shouldn't let you scroll into the future.
  var maxDate: Date = .now

  @State private var pickerOpen = false

  private static let isoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.calendar = Calendar(identifier: .iso8601)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    return f
  }()

  private var asDate: Date {
    Self.isoFormatter.date(from: date) ?? .now
  }

  private var isToday: Bool {
    Calendar.current.isDateInToday(asDate)
  }

  private var canGoPrev: Bool {
    Calendar.current.startOfDay(for: asDate) > Calendar.current.startOfDay(for: minDate)
  }

  private var canGoNext: Bool {
    Calendar.current.startOfDay(for: asDate) < Calendar.current.startOfDay(for: maxDate)
  }

  private var label: String {
    let cal = Calendar.current
    if cal.isDateInToday(asDate)     { return "Today" }
    if cal.isDateInYesterday(asDate) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: asDate, to: .now).day ?? 0
    if days < 7 {
      let f = DateFormatter(); f.dateFormat = "EEEE"
      return f.string(from: asDate)
    }
    let f = DateFormatter(); f.dateFormat = "EEEE · MMM d"
    return f.string(from: asDate)
  }

  var body: some View {
    HStack(spacing: Theme.Spacing.sm) {
      chevron(systemImage: "chevron.left", enabled: canGoPrev) {
        step(days: -1)
      }
      Button { pickerOpen = true } label: {
        Text(label)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(Theme.inkPrimary)
          .padding(.horizontal, Theme.Spacing.md)
          .padding(.vertical, 6)
          .background(Theme.secondaryGroupedBackground,
                      in: Capsule())
      }
      .buttonStyle(.plain)
      .popover(isPresented: $pickerOpen, arrowEdge: .top) {
        DatePicker("Pick a date",
                   selection: Binding(get: { asDate }, set: { newDate in
                     date = Self.isoFormatter.string(from: newDate)
                   }),
                   in: minDate ... maxDate,
                   displayedComponents: .date)
          .datePickerStyle(.graphical)
          .padding()
          .presentationCompactAdaptation(.popover)
      }
      if !isToday {
        Button("Today") {
          date = Self.isoFormatter.string(from: .now)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      Spacer()
      chevron(systemImage: "chevron.right", enabled: canGoNext) {
        step(days: 1)
      }
    }
    .padding(.horizontal, Theme.Spacing.xl)
  }

  private func step(days: Int) {
    guard let next = Calendar.current.date(byAdding: .day, value: days, to: asDate) else { return }
    let clamped = max(Calendar.current.startOfDay(for: minDate),
                      min(next, Calendar.current.startOfDay(for: maxDate)))
    date = Self.isoFormatter.string(from: clamped)
  }

  @ViewBuilder
  private func chevron(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.headline)
        .frame(width: 32, height: 32)
        .background(Theme.secondaryGroupedBackground, in: Circle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1.0 : 0.35)
  }
}

#Preview("DrawerDateStrip — today") {
  StatefulPreviewWrapper("2026-05-28") { binding in
    DrawerDateStrip(date: binding)
      .padding(.vertical)
      .background(Theme.groupedBackground)
  }
}

#Preview("DrawerDateStrip — back a few days") {
  StatefulPreviewWrapper("2026-05-23") { binding in
    DrawerDateStrip(date: binding)
      .padding(.vertical)
      .background(Theme.groupedBackground)
  }
}

/// Lightweight wrapper that holds @State for #Preview callsites that
/// need to bind a value. Keeps preview blocks pure-content without
/// requiring a full @Observable model.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
  @State private var value: Value
  let content: (Binding<Value>) -> Content
  init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
    self._value = State(wrappedValue: initial)
    self.content = content
  }
  var body: some View { content($value) }
}
