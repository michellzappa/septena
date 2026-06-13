import SwiftUI

/// A time / date-and-time picker whose minute field moves in
/// `minuteInterval`-minute steps (default 5) instead of every single minute.
///
/// SwiftUI's `DatePicker` exposes no minute-interval knob, so on iOS this
/// drops down to a real `UIDatePicker` with `minuteInterval` set — the wheel
/// then only lands on :00 / :05 / :10 … and the value snaps to the nearest
/// step the moment the user spins it. macOS has no equivalent on
/// `NSDatePicker` (its `.hourAndMinute` field is typed / stepped by one), so
/// there it falls back to a stock `DatePicker`; the :05 stepping is an iOS
/// affordance. Either way the bound value is snapped to the interval on
/// appear, so what the field shows is what gets saved.
///
/// Drop-in for `DatePicker(_:selection:displayedComponents:)`. Use the
/// label-less initializer wherever the old call paired with `.labelsHidden()`.
struct SteppedDatePicker: View {
  private let titleKey: LocalizedStringKey?
  @Binding var selection: Date
  private let displayedComponents: DatePickerComponents
  private let minuteInterval: Int

  init(_ titleKey: LocalizedStringKey,
       selection: Binding<Date>,
       displayedComponents: DatePickerComponents = .hourAndMinute,
       minuteInterval: Int = 5) {
    self.titleKey = titleKey
    self._selection = selection
    self.displayedComponents = displayedComponents
    self.minuteInterval = minuteInterval
  }

  /// Label-less variant — replaces `DatePicker("", …).labelsHidden()`.
  init(selection: Binding<Date>,
       displayedComponents: DatePickerComponents = .hourAndMinute,
       minuteInterval: Int = 5) {
    self.titleKey = nil
    self._selection = selection
    self.displayedComponents = displayedComponents
    self.minuteInterval = minuteInterval
  }

  var body: some View {
    content.onAppear(perform: snapToInterval)
  }

  @ViewBuilder private var content: some View {
    #if os(iOS)
    let wheel = MinuteIntervalDatePicker(date: $selection,
                                         mode: uiMode,
                                         minuteInterval: minuteInterval)
    if let titleKey {
      LabeledContent(titleKey) { wheel }
    } else {
      wheel
    }
    #else
    if let titleKey {
      DatePicker(titleKey, selection: $selection, displayedComponents: displayedComponents)
    } else {
      DatePicker("", selection: $selection, displayedComponents: displayedComponents)
        .labelsHidden()
    }
    #endif
  }

  /// Snap the stored value to the nearest `minuteInterval`, dropping seconds,
  /// so the field and the saved timestamp agree. No-op when already aligned.
  private func snapToInterval() {
    let cal = Calendar.current
    let minute = cal.component(.minute, from: selection)
    let second = cal.component(.second, from: selection)
    let target = Int((Double(minute) / Double(minuteInterval)).rounded()) * minuteInterval
    guard target != minute || second != 0 else { return }
    var snapped = selection
    if let m = cal.date(byAdding: .minute, value: target - minute, to: snapped) { snapped = m }
    if second != 0, let s = cal.date(byAdding: .second, value: -second, to: snapped) { snapped = s }
    selection = snapped
  }

  #if os(iOS)
  private var uiMode: UIDatePicker.Mode {
    displayedComponents.contains(.date) ? .dateAndTime : .time
  }
  #endif
}

#if os(iOS)
import UIKit

/// Compact `UIDatePicker` bridged into SwiftUI so we can set `minuteInterval`
/// — the one property SwiftUI's `DatePicker` doesn't surface. Matches the
/// look of a compact SwiftUI date picker (it is the same control underneath)
/// and hugs its content so it sits as a trailing chip inside a Form row.
private struct MinuteIntervalDatePicker: UIViewRepresentable {
  @Binding var date: Date
  let mode: UIDatePicker.Mode
  let minuteInterval: Int

  func makeUIView(context: Context) -> UIDatePicker {
    let picker = UIDatePicker()
    picker.datePickerMode = mode
    picker.preferredDatePickerStyle = .compact
    picker.minuteInterval = minuteInterval
    picker.date = date
    picker.addTarget(context.coordinator,
                     action: #selector(Coordinator.changed(_:)),
                     for: .valueChanged)
    picker.setContentHuggingPriority(.required, for: .horizontal)
    picker.setContentCompressionResistancePriority(.required, for: .horizontal)
    return picker
  }

  func updateUIView(_ picker: UIDatePicker, context: Context) {
    context.coordinator.date = $date
    if picker.datePickerMode != mode { picker.datePickerMode = mode }
    if picker.minuteInterval != minuteInterval { picker.minuteInterval = minuteInterval }
    // Only push an external change back into the picker; a user-driven edit
    // already set the binding to `picker.date`, so the diff is ~0 and we skip
    // it (re-assigning would fight the wheel mid-spin).
    if abs(picker.date.timeIntervalSince(date)) > 1 { picker.date = date }
  }

  func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

  final class Coordinator: NSObject {
    var date: Binding<Date>
    init(date: Binding<Date>) { self.date = date }
    @objc func changed(_ sender: UIDatePicker) { date.wrappedValue = sender.date }
  }
}
#endif
