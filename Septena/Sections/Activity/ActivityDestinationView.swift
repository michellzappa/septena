import SwiftUI
import SwiftData
import Charts

// Activity mini-app — Apple Health (HealthKit) sourced directly from the
// device, then persisted as one ActivityDayEntity per day and synced through
// CloudKit. The step chart therefore reads from SwiftData (works on macOS,
// which has no HealthKit), while the live vitals + access flows stay iOS-only.

struct ActivityDestinationView: View {
  @Environment(SectionTheme.self) private var theme

  @State private var bridge = HealthKitBridge.shared
  @State private var rangeDays = DrawerRange.ninety.rawValue

  // The persisted, synced history. Present on every platform once a phone has
  // ingested at least once — this is what gives macOS a non-empty view.
  @Query(sort: \ActivityDayEntity.date) private var days: [ActivityDayEntity]

  private var accent: Color { theme.color(for: "activity") }

  var body: some View {
    SectionDrawer(sectionKey: "activity") {
      // History chart first — the primary content, derived from synced data.
      if !steppedDays.isEmpty {
        history
      }

      // Live, on-device extras. iOS shows vitals + the access flows; on macOS
      // (always `.denied`) we only fall back to the "not available" notice
      // when there's no synced history to show instead.
      switch bridge.access {
      case .granted:       vitals
      case .notDetermined: askForAccess
      case .denied:        if steppedDays.isEmpty { deniedNotice }
      }
    }
    .tint(accent)
    .task { await bridge.refresh() }
  }

  // MARK: - History

  /// Rows within the selected window that actually have a step count.
  private var windowed: [ActivityDayEntity] {
    let start = Calendar.current.date(byAdding: .day, value: -(rangeDays - 1), to: Date())
    let cutoff = SeptenaDate.format(start) ?? ""
    return days.filter { $0.date >= cutoff }
  }

  private var steppedDays: [ActivityDayEntity] {
    windowed.filter { ($0.stepCount ?? 0) > 0 }
  }

  private var averageSteps: Int {
    let counts = steppedDays.compactMap(\.stepCount)
    guard !counts.isEmpty else { return 0 }
    return counts.reduce(0, +) / counts.count
  }

  @ViewBuilder
  private var history: some View {
    DrawerSection {
      VStack(alignment: .leading, spacing: 12) {
        DrawerRangePicker(days: $rangeDays, options: [.month, .ninety, .year])

        Text("\(averageSteps) avg steps · \(steppedDays.count) active days")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()

        Chart(steppedDays, id: \.date) { row in
          if let d = SeptenaDate.parse(row.date) {
            AreaMark(x: .value("Day", d, unit: .day),
                     y: .value("Steps", row.stepCount ?? 0))
              .foregroundStyle(accent.opacity(0.15))
              .interpolationMethod(.monotone)
              .accessibilityHidden(true)
            LineMark(x: .value("Day", d, unit: .day),
                     y: .value("Steps", row.stepCount ?? 0))
              .foregroundStyle(accent)
              .interpolationMethod(.monotone)
              .accessibilityLabel(SeptenaDate.friendlyLabel(row.date))
              .accessibilityValue("\(row.stepCount ?? 0) steps")
          }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: 180)
      }
    }
  }

  // MARK: - States

  private var askForAccess: some View {
    DrawerSection {
      VStack(alignment: .leading, spacing: 12) {
        Text("Read Apple Health on this device")
          .font(.septenaCardTitle)
        Text("Septena pulls steps, exercise minutes, VO2 max, HRV and resting heart rate from HealthKit. Data never leaves your phone.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Button("Grant access") {
          Task { _ = await bridge.requestAccess() }
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
      }
    }
  }

  private var deniedNotice: some View {
    DrawerSection {
      VStack(alignment: .leading, spacing: 8) {
        if !bridge.isAvailable {
          Text("HealthKit isn't available on this device")
            .font(.septenaCardTitle)
          Text("Activity tracking runs on iPhone / iPad. Open Septena there to start syncing steps and recovery metrics.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          Text("Health access denied")
            .font(.septenaCardTitle)
          Text("Re-enable in Settings → Health → Data Access & Devices → Septena.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var vitals: some View {
    if bridge.vo2Max != nil || bridge.hrv != nil || bridge.restingHR != nil {
      DrawerSection("Recent vitals") {
        if let v = bridge.vo2Max {
          row("VO2 max", "\(v.decimalString(1)) ml/kg·min")
        }
        if let h = bridge.hrv {
          row("HRV (SDNN)", "\(Int(h)) ms")
        }
        if let r = bridge.restingHR {
          row("Resting HR", "\(Int(r)) bpm")
        }
      }
    }
  }

  // MARK: - Bits

  private func row(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value).foregroundStyle(.secondary).monospacedDigit()
    }
  }
}
