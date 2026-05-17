import SwiftUI

// Settings mini-app — read-only display of the user's Septena
// configuration: targets, units, theme, time. Editing isn't wired yet
// (the webapp is still the source of truth for changes). Surfaced here
// so users can confirm what the iOS app is seeing.

struct SettingsDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  @State private var settings: AppSettings? = nil
  @State private var loading = true

  private var accent: Color { theme.color(for: "settings") }

  var body: some View {
    List {
      if let s = settings {
        appSection(s)
        if let t = s.targets { targetsSection(t) }
      } else if loading {
        ProgressView().frame(maxWidth: .infinity)
      } else {
        ContentUnavailableView("Couldn't load settings",
                               systemImage: "gear",
                               description: Text("Check the backend connection."))
      }
    }
    .listStyle(.insetGrouped)
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Settings")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task { await load() }
    .refreshable { await load() }
  }

  // MARK: - Sections

  @ViewBuilder
  private func appSection(_ s: AppSettings) -> some View {
    Section("App") {
      row("Theme", s.theme?.capitalized ?? "—")
      row("eInk mode", (s.eink ?? false) ? "On" : "Off")
      if let u = s.units {
        row("Weight unit", u.weight)
        row("Distance unit", u.distance)
      }
      if let t = s.time {
        row("Home timezone", t.homeTimezone)
        if let m = t.travelMode, m != "off" {
          row("Travel mode", m)
          if let tz = t.travelTimezone { row("Travel timezone", tz) }
        }
      }
      if let order = s.sectionOrder, !order.isEmpty {
        row("Section order", order.joined(separator: " · "))
      }
    }
  }

  @ViewBuilder
  private func targetsSection(_ t: AppTargets) -> some View {
    Section("Targets") {
      if let lo = t.proteinMinG, let hi = t.proteinMaxG {
        row("Protein", "\(Int(lo))–\(Int(hi)) g")
      }
      if let lo = t.fatMinG, let hi = t.fatMaxG {
        row("Fat", "\(Int(lo))–\(Int(hi)) g")
      }
      if let lo = t.carbsMinG, let hi = t.carbsMaxG {
        row("Carbs", "\(Int(lo))–\(Int(hi)) g")
      }
      if let lo = t.kcalMin, let hi = t.kcalMax {
        row("Calories", "\(Int(lo))–\(Int(hi)) kcal")
      }
      if let z2 = t.z2WeeklyMin {
        row("Z2 weekly", "\(z2) min")
      }
      if let s = t.sleepTargetH {
        row("Sleep target", String(format: "%.1f h", s))
      }
      if let lo = t.fastingMinH, let hi = t.fastingMaxH {
        row("Fasting", String(format: "%.0f–%.0f h", lo, hi))
      }
      if let lo = t.weightMinKg, let hi = t.weightMaxKg {
        row("Weight", String(format: "%.1f–%.1f kg", lo, hi))
      }
      if let lo = t.fatMinPct, let hi = t.fatMaxPct {
        row("Body fat", String(format: "%.0f–%.0f %%", lo, hi))
      }
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
  }

  // MARK: - Loading

  private func load() async {
    loading = true
    settings = try? await client.settings()
    loading = false
  }
}
