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
/// affordance. An existing odd-minute timestamp is left untouched until you
/// actually spin the wheel, so opening an entry to edit something else never
/// quietly shifts its time.
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
    content
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
    context.coordinator.lastPushed = date
    picker.addTarget(context.coordinator,
                     action: #selector(Coordinator.changed(_:)),
                     for: .valueChanged)
    picker.setContentHuggingPriority(.required, for: .horizontal)
    picker.setContentHuggingPriority(.required, for: .vertical)
    picker.setContentCompressionResistancePriority(.required, for: .horizontal)
    picker.setContentCompressionResistancePriority(.required, for: .vertical)
    return picker
  }

  /// Report the picker's natural chip size so SwiftUI gives the Form row
  /// enough height. Without this the representable's ideal size is ambiguous,
  /// the row collapses to the label's line height, and the date/time chips get
  /// clipped top and bottom.
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIDatePicker, context: Context) -> CGSize? {
    uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
  }

  func updateUIView(_ picker: UIDatePicker, context: Context) {
    context.coordinator.date = $date
    if picker.datePickerMode != mode { picker.datePickerMode = mode }
    if picker.minuteInterval != minuteInterval { picker.minuteInterval = minuteInterval }
    // Push the binding in only when it actually changed since we last synced.
    // Comparing against `picker.date` would be wrong: the picker normalizes
    // its value (drops seconds, rounds to the interval), so an odd-minute or
    // non-zero-second binding never equals it — and we'd re-assign on every
    // layout pass, re-animating the label (the ghosted roll on sheet entry).
    if context.coordinator.lastPushed != date {
      picker.setDate(date, animated: false)
      context.coordinator.lastPushed = date
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

  final class Coordinator: NSObject {
    var date: Binding<Date>
    /// The last value we wrote into the picker, so `updateUIView` can tell a
    /// real binding change from the picker's own normalization.
    var lastPushed: Date?
    init(date: Binding<Date>) { self.date = date }
    @objc func changed(_ sender: UIDatePicker) {
      date.wrappedValue = sender.date
      lastPushed = sender.date
    }
  }
}
#endif
