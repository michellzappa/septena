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
  // Bridges referenced so .access changes redraw the rows.
  @State private var calendarBridge = CalendarBridge.shared
  @State private var remindersBridge = RemindersBridge.shared
  @State private var healthBridge = HealthKitBridge.shared

  private var accent: Color { theme.color(for: "settings") }

  var body: some View {
    List {
      integrationsSection
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

  // MARK: - Integrations
  //
  // Native iOS data sources Septena reaches outside the FastAPI proxy:
  // Reminders + Calendar (EventKit) and Apple Health (HealthKit). Each
  // row shows current access state and offers a grant prompt where it
  // makes sense; denied / not-available cases route to system Settings.

  private var integrationsSection: some View {
    Section("Integrations") {
      remindersRow
      calendarRow
      healthRow
    }
  }

  private var remindersRow: some View {
    integrationRow(
      title: "Reminders",
      systemImage: "checklist",
      state: remindersAccessLabel,
      stateColor: remindersBridge.access == .granted ? .green : .secondary
    ) {
      if remindersBridge.access == .notDetermined {
        Task { _ = await remindersBridge.requestAccess() }
      }
    }
  }

  private var calendarRow: some View {
    integrationRow(
      title: "Calendar",
      systemImage: "calendar",
      state: calendarAccessLabel,
      stateColor: calendarBridge.access == .granted ? .green : .secondary
    ) {
      if calendarBridge.access == .notDetermined {
        Task { _ = await calendarBridge.requestAccess() }
      }
    }
  }

  private var healthRow: some View {
    integrationRow(
      title: "Apple Health",
      systemImage: "heart.text.square",
      state: healthAccessLabel,
      stateColor: healthBridge.access == .granted ? .green : .secondary
    ) {
      if healthBridge.access == .notDetermined && healthBridge.isAvailable {
        Task { _ = await healthBridge.requestAccess() }
      }
    }
  }

  private func integrationRow(title: String,
                              systemImage: String,
                              state: String,
                              stateColor: Color,
                              onTap: @escaping () -> Void) -> some View {
    Button(action: onTap) {
      HStack {
        Label(title, systemImage: systemImage)
          .foregroundStyle(Theme.inkPrimary)
        Spacer()
        Text(state)
          .font(.subheadline)
          .foregroundStyle(stateColor)
      }
    }
    .buttonStyle(.plain)
  }

  private var remindersAccessLabel: String {
    switch remindersBridge.access {
    case .granted:        return "Granted"
    case .writeOnly:      return "Write-only"
    case .denied:         return "Denied"
    case .notDetermined:  return "Grant"
    }
  }

  private var calendarAccessLabel: String {
    switch calendarBridge.access {
    case .granted:       return "Granted"
    case .writeOnly:     return "Write-only"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }

  private var healthAccessLabel: String {
    guard healthBridge.isAvailable else { return "Not available" }
    switch healthBridge.access {
    case .granted:       return "Granted"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
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
