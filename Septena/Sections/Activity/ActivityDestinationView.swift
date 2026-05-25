import SwiftUI

// Activity mini-app — Apple Health (HealthKit) sourced directly from the
// device. First module wired to a native on-device source for data the
// webapp also exposes (via /api/health/apple); going direct gives us
// privacy + freshness and skips the FastAPI proxy entirely.

struct ActivityDestinationView: View {
  @Environment(SectionTheme.self) private var theme

  @State private var bridge = HealthKitBridge.shared

  private var accent: Color { theme.color(for: "activity") }

  var body: some View {
    List {
      SectionGoalsStrip(sectionKey: "activity")
      switch bridge.access {
      case .granted:       grantedBody
      case .notDetermined: askForAccess
      case .denied:        deniedNotice
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Activity")
    .trackScreen("activity")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task { await bridge.refresh() }
  }

  // MARK: - States

  @ViewBuilder
  private var grantedBody: some View {
    summary
    vitals
    Section("Last 7 days · steps") {
      ForEach(Array(zip(weekdayLabels, bridge.stepsHistory).enumerated()), id: \.offset) { _, pair in
        LogRow(title: pair.0,
               detail: nil,
               trailing: pair.1 > 0 ? "\(pair.1)" : "—")
          .listRowInsets(EdgeInsets())
      }
    }
  }

  private var askForAccess: some View {
    Section {
      VStack(alignment: .leading, spacing: 12) {
        Text("Read Apple Health on this device")
          .font(.headline)
        Text("Septena pulls steps, exercise minutes, VO2 max, HRV and resting heart rate from HealthKit. Data never leaves your phone.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Button("Grant access") {
          Task { _ = await bridge.requestAccess() }
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
      }
      .padding(.vertical, 6)
    }
  }

  private var deniedNotice: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        if !bridge.isAvailable {
          Text("HealthKit isn't available on this device")
            .font(.headline)
          Text("Activity tracking runs on iPhone / iPad. Open Septena Cloud there to see steps and recovery metrics.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          Text("Health access denied")
            .font(.headline)
          Text("Re-enable in Settings → Health → Data Access & Devices → Septena Cloud.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: - Sections

  private var summary: some View {
    Section {
      HStack(alignment: .top, spacing: 24) {
        stat(value: "\(bridge.stepsToday)",
             label: "steps",
             tint: accent)
        stat(value: "\(Int(bridge.activeKcalToday))",
             label: "active",
             tint: accent,
             unit: "kcal")
        stat(value: "\(bridge.exerciseMinutesToday)",
             label: "exercise",
             tint: accent,
             unit: "m")
        Spacer()
      }
    }
  }

  @ViewBuilder
  private var vitals: some View {
    if bridge.vo2Max != nil || bridge.hrv != nil || bridge.restingHR != nil {
      Section("Recent vitals") {
        if let v = bridge.vo2Max {
          row("VO2 max", String(format: "%.1f ml/kg·min", v))
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

  private func stat(value: String, label: String, tint: Color,
                    unit: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(value)
          .font(.system(.title2, design: .rounded).weight(.semibold))
          .foregroundStyle(tint)
        if let unit { Text(unit).font(.subheadline).foregroundStyle(.secondary) }
      }
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value).foregroundStyle(.secondary).monospacedDigit()
    }
  }

  /// Last 7 days oldest → newest as weekday names ("Mon", "Tue", …).
  private var weekdayLabels: [String] {
    let cal = Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "EEE"
    return (0..<7).reversed().compactMap { offset in
      cal.date(byAdding: .day, value: -offset, to: Date()).map(fmt.string(from:))
    }
  }
}
