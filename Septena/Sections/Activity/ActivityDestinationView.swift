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
    SectionDrawer(sectionKey: "activity", title: "Activity") {
      switch bridge.access {
      case .granted:       grantedBody
      case .notDetermined: askForAccess
      case .denied:        deniedNotice
      }
    }
    .trackScreen("activity")
    .tint(accent)
    .task { await bridge.refresh() }
  }

  // MARK: - States

  @ViewBuilder
  private var grantedBody: some View {
    vitals
    DrawerSection("Last 7 days · steps", padding: .none) {
      ForEach(Array(zip(weekdayLabels, bridge.stepsHistory).enumerated()), id: \.offset) { _, pair in
        LogRow(title: pair.0,
               detail: nil,
               trailing: pair.1 > 0 ? "\(pair.1)" : "—")
      }
    }
  }

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
          Text("Activity tracking runs on iPhone / iPad. Open Septena there to see steps and recovery metrics.")
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

  /// Last 7 days oldest → newest as weekday names ("Mon", "Tue", …).
  private var weekdayLabels: [String] {
    let cal = Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "EEE"
    return (0..<7).reversed().compactMap { offset in
      cal.date(byAdding: .day, value: -offset, to: Date()).map(fmt.string(from:))
    }
  }
}
