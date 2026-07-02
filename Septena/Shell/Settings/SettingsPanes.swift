import SwiftUI
import SwiftData
import EventKit
import CloudKit
import CoreLocation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

struct PrivacySettingsPane: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store

  @AppStorage(SettingsKey.telemetryLevel) private var levelRaw: String =
    TelemetryClient.TelemetryLevel.balanced.rawValue
  @AppStorage(SettingsKey.appLockEnabled) private var appLockEnabled: Bool = false
  @AppStorage(SettingsKey.appLockGraceSeconds) private var appLockGrace: Int = 60

  @State private var recent: [TelemetryClient.SentRecord] = []

  private var level: TelemetryClient.TelemetryLevel {
    TelemetryClient.TelemetryLevel(rawValue: levelRaw) ?? .balanced
  }

  private var levelBinding: Binding<TelemetryClient.TelemetryLevel> {
    Binding(
      get: { level },
      set: { store.setTelemetryLevel($0, context: modelContext, engine: ckEngine) }
    )
  }

  var body: some View {
    Form {
      Section {
        Toggle(AppLock.requireActionLabel, isOn: $appLockEnabled)
          .disabled(!AppLock.isAvailable)
        if appLockEnabled {
          Picker("Lock after", selection: $appLockGrace) {
            Text("Immediately").tag(0)
            Text("After 1 minute").tag(60)
            Text("After 5 minutes").tag(300)
          }
        }
      } header: {
        Text("App Lock")
      } footer: {
        Text(AppLock.isAvailable
             ? "Asks for \(AppLock.biometryLabel) or your passcode when you reopen Septena. Your data is already protected by your device passcode — this adds a gate in front of the app itself, for when the phone is unlocked and handed over."
             : "Set up \(AppLock.biometryLabel) or a device passcode in Settings to use App Lock.")
      }

      Section {
        Picker("Usage data", selection: levelBinding) {
          ForEach(TelemetryClient.TelemetryLevel.allCases, id: \.self) { lvl in
            Text(lvl.title).tag(lvl)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } header: {
        Text("Anonymous usage data")
      } footer: {
        Text(level.summary)
      }

      Section {
        ForEach(TelemetryClient.dataCatalog) { sentRow($0) }
      } header: {
        Text("What is sent")
      } footer: {
        Text("Checked items are sent at your current level (\(level.title)). The rest stay on your device until you raise the level.")
      }

      Section {
        if recent.isEmpty {
          Text("Nothing has been sent from this device yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(recent) { rec in
            VStack(alignment: .leading, spacing: 2) {
              HStack(alignment: .firstTextBaseline) {
                Text(rec.event)
                Spacer()
                Text(rec.date.formatted(date: .abbreviated, time: .shortened))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              if let detail = rec.detail {
                Text(detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      } header: {
        Text("Recently sent from this device")
      } footer: {
        Text("The last \(TelemetryClient.maxLogEntries) analytics events actually transmitted, recorded only on this device. This is the ground truth for the list above.")
      }

      Section("What is never sent — at any level") {
        bullet("Anything you log — food, intake, supplements, sleep, mood, notes. None of it leaves your device through analytics.")
        bullet("Your community profile, iCloud identity, or anything that links analytics to your personal data.")
        bullet("Your IP address. Cloudflare receives it to deliver the request, but Septena does not store it in analytics tables.")
      }

      // Future: opt-in donation of select, anonymized life data to support
      // research. Deliberately unselectable for now — shown so the intent is
      // transparent, but it does nothing until the contribution pipeline ships.
      Section {
        HStack {
          Label("Contribute anonymized data to research", systemImage: "flask")
          Spacer()
          Text("Coming soon")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
      } header: {
        Text("Research")
      } footer: {
        Text("In a future update you'll be able to opt in to sharing a select, anonymized slice of your data to support health research. It will always be off by default, fully opt-in, and separate from the usage data above — never your raw logs or anything that identifies you.")
      }

      Section {
        EmptyView()
      } footer: {
        VStack(alignment: .leading, spacing: 8) {
          Text("Analytics is processed by Septena on Cloudflare infrastructure. Your privacy level syncs across your own devices through iCloud.")
          Link("cloudflare.com/privacypolicy",
               destination: URL(string: "https://www.cloudflare.com/privacypolicy/")!)
            .font(.callout)
          Text("Septena is open source. Read exactly what's collected and when, in the code:")
            .padding(.top, 4)
          Link("View the analytics source on GitHub",
               destination: URL(string: "https://github.com/septena/septena/blob/main/SeptenaCore/Telemetry.swift")!)
            .font(.callout)
        }
      }
    }
    .formStyle(.grouped)
    .task(id: levelRaw) { recent = await TelemetryClient.shared.recentlySent() }
  }

  private func bullet(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("•").foregroundStyle(.secondary)
      Text(text).foregroundStyle(.primary)
    }
  }

  @ViewBuilder
  private func sentRow(_ item: TelemetryClient.DataItem) -> some View {
    let included = item.isSent(at: level)
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: included ? "checkmark.circle.fill" : "circle.dashed")
        .foregroundStyle(included ? Color.accentColor : Color.secondary)
        .accessibilityLabel(included ? "Sent" : "Not sent")
      Text(item.text)
        .foregroundStyle(included ? .primary : .secondary)
    }
  }
}

// MARK: - Connections & AI

struct ConnectionsAISettingsPane: View {
  var body: some View {
    Form {
      Section {
        NavigationLink(value: SettingsView.SettingsDestination.claudeAI) {
          Label("AI Mode & Claude", systemImage: "brain.head.profile")
        }
        NavigationLink(value: SettingsView.SettingsDestination.skills) {
          Label("MCP Skills", systemImage: "book.closed")
        }
        NavigationLink(value: SettingsView.SettingsDestination.localMcp) {
          Label("MCP Server", systemImage: "server.rack")
        }
      } header: {
        Text("AI & MCP")
      } footer: {
        Text("Choose how far AI may reach, connect Claude through MCP, and review the skills that teach models how to use your sections.")
      }

      ConnectedAppsSettingsSections()
    }
    .formStyle(.grouped)
  }
}

#if !os(macOS)
struct MCPServerUnavailablePane: View {
  var body: some View {
    Form {
      Section {
        Label("MCP Server runs on Mac", systemImage: "server.rack")
      } footer: {
        Text("The local MCP server lets Claude Code connect directly to Septena through the Mac app. iPhone and iPad can still use the hosted Claude connection and MCP Skills, but they don't host the local server.")
      }
    }
    .formStyle(.grouped)
  }
}
#endif

// MARK: - Sharing & Data

struct SharingDataSettingsPane: View {
  var body: some View {
    Form {
      Section {
        NavigationLink(value: SettingsView.SettingsDestination.reports) {
          Label("Practitioner Reports", systemImage: "chart.bar.doc.horizontal")
        }
      } footer: {
        Text("Build focused reports to share with a doctor, therapist, coach, or other practitioner.")
      }

      Section {
        NavigationLink(value: SettingsView.SettingsDestination.data) {
          Label("Import & Export", systemImage: "square.and.arrow.up")
        }
      } footer: {
        Text("Export backups as JSON, import compatible data, or move records between devices and tools.")
      }

      Section {
        NavigationLink(value: SettingsView.SettingsDestination.dataTools) {
          Label("Data Tools", systemImage: "stethoscope")
        }
      } footer: {
        Text("Repair local data from iCloud and copy schema prompts for model-assisted imports.")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Feedback

struct FeedbackSettingsPane: View {
  var body: some View {
    Form {
      Section {
        NavigationLink(value: SettingsView.SettingsDestination.communityRoadmap) {
          Label("Roadmap", systemImage: "map")
        }
        NavigationLink(value: SettingsView.SettingsDestination.communityTestimonial) {
          Label("Testimonial", systemImage: "quote.bubble")
        }
        NavigationLink(value: SettingsView.SettingsDestination.communityProfile) {
          Label("Public Profile", systemImage: "person.text.rectangle")
        }
      } footer: {
        Text("Suggest and vote on what comes next, share a testimonial, and choose the public profile attached to community contributions.")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Home (homepage configuration)

/// Everything that shapes the home tab, pulled out of the old "Customize"
/// junk drawer: how it renders (Layout, Insights), the greeting (Welcome),
/// and the day view.
struct HomeSettingsPane: View {
  @AppStorage(SettingsKey.homepageDayView)
  private var dayViewRaw: String = DayViewStyle.dial.rawValue
  @AppStorage(SettingsKey.wheelWakingDay)
  private var wakingDay: Bool = true
  @AppStorage(SettingsKey.dailyMessageEnabled)
  private var dailyMessageEnabled: Bool = false
  @AppStorage(SettingsKey.dailyMessagePacks)
  private var dailyMessagePacksRaw: String = "practice,stoic,zen"

  private var activePacks: Set<QuotePack> {
    Set(dailyMessagePacksRaw.split(separator: ",").compactMap { QuotePack(rawValue: String($0)) })
  }

  private func packBinding(_ pack: QuotePack) -> Binding<Bool> {
    Binding(
      get: { activePacks.contains(pack) },
      set: { on in
        var set = activePacks
        if on { set.insert(pack) } else { set.remove(pack) }
        dailyMessagePacksRaw = QuotePack.allCases
          .filter { set.contains($0) }.map(\.rawValue).joined(separator: ",")
      }
    )
  }

  var body: some View {
    Form {
      Section {
        NavigationLink(value: SettingsView.SettingsDestination.layout) {
          Label("Layout", systemImage: "square.grid.2x2")
        }
        NavigationLink(value: SettingsView.SettingsDestination.correlations) {
          Label("Insights", systemImage: "chart.dots.scatter")
        }
        NavigationLink(value: SettingsView.SettingsDestination.nextFeed) {
          Label("Next", systemImage: "arrow.forward.circle")
        }
      } footer: {
        Text("Layout picks how the homepage renders — Histogram, Sparkline, Heatmap, Rings, or Wheel. Insights tunes the cross-section correlation explorer. Next shapes the daily list — suggestions, carry-over, and which sections appear.")
      }

      Section {
        Picker(selection: Binding(
          get: { DayViewStyle(rawValue: dayViewRaw) ?? .dial },
          set: { dayViewRaw = $0.rawValue }
        )) {
          ForEach(DayViewStyle.allCases) { style in
            Label(style.label, systemImage: style.icon).tag(style)
          }
        } label: {
          Text("Day view")
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } header: {
        Text("Day view")
      } footer: {
        Text("Shows today at a glance, above the layout. Dial is a 24-hour clock with your logs as dots and sleep as an arc, lit by the real sunrise and sunset for your time zone — no location needed. Timeline shows the same day as a horizontal strip.")
      }

      Section {
        Toggle(isOn: $wakingDay) {
          Label("Start day at wake", systemImage: "sunrise")
        }
      } header: {
        Text("Day dial")
      } footer: {
        Text("Start day at wake rolls the dial over when you wake rather than at midnight, so a late night stays on the same day.")
      }

      Section {
        Toggle(isOn: $dailyMessageEnabled) {
          Label("Daily message", systemImage: "text.quote")
        }
        if dailyMessageEnabled {
          ForEach(QuotePack.allCases) { pack in
            Toggle(isOn: packBinding(pack)) {
              VStack(alignment: .leading, spacing: 2) {
                Text(pack.title)
                Text(pack.subtitle)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          NavigationLink {
            DailyMessageQuotesEditor()
          } label: {
            Label("Your quotes", systemImage: "quote.opening")
          }
          NavigationLink {
            ReadwiseConnectView()
          } label: {
            Label("Readwise", systemImage: "highlighter")
          }
        }
      } header: {
        Text("Daily message")
      } footer: {
        Text("A quiet line at the very bottom of the home dashboard — a quote that changes through the day. Off by default. Draws from the packs you pick, your own quotes, and your Readwise highlights.")
      }

      DisplayBehaviorSettingsSections()
    }
    .formStyle(.grouped)
  }
}

// MARK: - General (app behavior)

/// The small, honest catch-all Apple keeps too: time boundaries, the app icon,
/// Home Screen quick actions, and the logging-animation switch. Notifications
/// graduated to its own root row; homepage settings moved to Home.
struct GeneralSettingsPane: View {
  var body: some View {
    Form {
      DisplayBehaviorSettingsSections()
    }
    .formStyle(.grouped)
  }
}

private struct DisplayBehaviorSettingsSections: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store

  @AppStorage(SettingsKey.loggingAnimationsEnabled)
  private var loggingAnimationsEnabled: Bool = true
  // Drives the units picker's selection reactively; the actual write goes
  // through `store.setWeightUnit` (mirror + synced payload), which rewrites
  // this same key so the control reflects the change immediately.
  @AppStorage(SettingsKey.weightUnit)
  private var weightUnitRaw = WeightUnit.kg.rawValue

  private var unitsBinding: Binding<WeightUnit> {
    Binding {
      WeightUnit.resolve(weightUnitRaw)
    } set: { newValue in
      store.setWeightUnit(newValue, context: modelContext, engine: ckEngine)
    }
  }

  var body: some View {
    Section {
      Picker(selection: unitsBinding) {
        Text("Metric (kg, km)").tag(WeightUnit.kg)
        Text("Imperial (lb, mi)").tag(WeightUnit.lb)
      } label: {
        Label("Units", systemImage: "scalemass")
      }
    } header: {
      Text("Display & Behavior")
    } footer: {
      Text("Whether weights, distances, and fluids show in metric (kg, km, ml) or imperial (lb, mi, fl oz) across Training, Body, and Hydration. Your data is always stored the same way — this only changes how it’s displayed and entered.")
    }

    Section {
      NavigationLink(value: SettingsView.SettingsDestination.timeOfDay) {
        Label("Time of Day", systemImage: "clock")
      }
    } footer: {
      Text("Set when morning, afternoon, and evening begin — used across Habits, Supplements, the “Now” marker, and the greeting.")
    }

    #if os(iOS)
    Section {
      NavigationLink(value: SettingsView.SettingsDestination.quickActions) {
        Label("Quick Actions", systemImage: "bolt")
      }
    } footer: {
      Text("Choose up to 4 sections to surface when you long-press the app icon on the Home Screen.")
    }
    #endif

    Section {
      NavigationLink(value: SettingsView.SettingsDestination.appIcon) {
        Label("App Icon", systemImage: "app.badge")
      }
    }

    Section {
      Toggle(isOn: $loggingAnimationsEnabled) {
        Label("Logging animations", systemImage: "party.popper")
      }
    } footer: {
      Text("The little celebration that plays when you log something — confetti, ripples, a streak landing — and the checkbox feels when you check things off. Off keeps the confirming haptic but skips the motion. Reduce Motion always overrides this.")
    }
  }
}

// MARK: - Time of Day submenu
//
// Lets the user move the two boundaries that split the day into Morning /
// Afternoon / Evening. The values write straight through to the App Group
// mirror `DayBucket` reads (so Habits, Supplements, the "Now" marker, the
// Next list, and the welcome greeting all shift at once) and up to the
// CloudKit-synced `AppSettings`.

struct TimeOfDaySettingsPane: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store

  @State private var morningEnd = DayBucketCutoffs.default.morningEnd
  @State private var afternoonEnd = DayBucketCutoffs.default.afternoonEnd
  @State private var loaded = false

  var body: some View {
    Form {
      Section {
        Picker(selection: $morningEnd) {
          ForEach(1...22, id: \.self) { Text(hourLabel($0)).tag($0) }
        } label: {
          Label("Morning ends", systemImage: DayBucket.morning.icon)
        }
        Picker(selection: $afternoonEnd) {
          ForEach((morningEnd + 1)...23, id: \.self) { Text(hourLabel($0)).tag($0) }
        } label: {
          Label("Afternoon ends", systemImage: DayBucket.afternoon.icon)
        }
      } footer: {
        Text("Set when each part of your day begins. These boundaries drive the Morning / Afternoon / Evening groups in Habits and Supplements, the “Now” marker, what the Next list surfaces, and the welcome greeting.")
      }

      Section("Your day") {
        bucketRow(.morning, start: hourLabel(0), end: hourLabel(morningEnd))
        bucketRow(.afternoon, start: hourLabel(morningEnd), end: hourLabel(afternoonEnd))
        bucketRow(.evening, start: hourLabel(afternoonEnd), end: hourLabel(0))
      }

      Section {
        Button("Reset to default") { apply(.default) }
          .disabled(morningEnd == DayBucketCutoffs.default.morningEnd
                    && afternoonEnd == DayBucketCutoffs.default.afternoonEnd)
      } footer: {
        Text("Default: morning until \(hourLabel(DayBucketCutoffs.default.morningEnd)), afternoon until \(hourLabel(DayBucketCutoffs.default.afternoonEnd)).")
      }
    }
    .formStyle(.grouped)
    .onAppear {
      let c = store.dayBucketCutoffs
      morningEnd = c.morningEnd
      afternoonEnd = c.afternoonEnd
      loaded = true
    }
    .onChange(of: morningEnd) { _, newMorning in
      if afternoonEnd <= newMorning { afternoonEnd = newMorning + 1 }
      persist()
    }
    .onChange(of: afternoonEnd) { _, _ in persist() }
  }

  private func bucketRow(_ b: DayBucket, start: String, end: String) -> some View {
    HStack {
      Label(b.title, systemImage: b.icon)
      Spacer()
      Text("\(start) – \(end)")
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }

  private func apply(_ c: DayBucketCutoffs) {
    morningEnd = c.morningEnd
    afternoonEnd = c.afternoonEnd
    // The onChange handlers fire from these mutations and persist.
  }

  private func persist() {
    guard loaded else { return }
    store.setDayBucketCutoffs(morningEnd: morningEnd, afternoonEnd: afternoonEnd,
                              context: modelContext, engine: ckEngine)
  }

  /// Localized short time for a whole hour (0–23), e.g. "12:00 PM" or "17:00"
  /// depending on the user's locale.
  private func hourLabel(_ h: Int) -> String {
    let cal = Calendar.current
    let base = cal.startOfDay(for: .now)
    let date = cal.date(byAdding: .hour, value: h, to: base) ?? base
    return date.formatted(date: .omitted, time: .shortened)
  }
}

// MARK: - Next submenu
//
// Consolidates what shapes the daily Next list, which was previously scattered
// across the feed's own context menus and each section's detail pane:
//   • Suggestions — the learned time-of-day nudge cards (master switch +
//     per-kind opt-out). Device-local, via `NextSuggestionsPrefs`.
//   • Carry over missed items — the "linger" toggles for the two bucketed
//     blocks (habits / supplements), via `NextLinger`. Same @AppStorage keys
//     the section panes write, so flipping here and there stays in sync.
//   • Sections in Next — a roll-up of the per-section "Show in Next" toggle
//     (`SectionConfig.showInToday`), writing through the same mirror the
//     section detail pane uses (one source of truth, no divergence).
//   • A link to Time of Day, since the day's buckets decide what's "due now".

struct NextSettingsPane: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store

  // Suggestions: master switch + per-kind opt-outs. Keys come from
  // `NextSuggestionsPrefs` so the Next view's filter reads the same storage.
  @AppStorage(NextSuggestionsPrefs.enabledKey)
  private var suggestionsEnabled = NextSuggestionsPrefs.enabledDefault
  @AppStorage(NextSuggestionsPrefs.kindKey("training"))
  private var suggestTraining = NextSuggestionsPrefs.kindDefault
  @AppStorage(NextSuggestionsPrefs.kindKey("fastBreak"))
  private var suggestFastBreak = NextSuggestionsPrefs.kindDefault
  @AppStorage(NextSuggestionsPrefs.kindKey("mood"))
  private var suggestMood = NextSuggestionsPrefs.kindDefault
  @AppStorage(NextSuggestionsPrefs.kindKey("intake"))
  private var suggestIntake = NextSuggestionsPrefs.kindDefault

  // Carry-over (linger) for the two bucketed blocks — same keys as the
  // Habits / Supplements section panes.
  @AppStorage(NextLinger.habitsKey)
  private var lingerHabits = NextLinger.habitsDefault
  @AppStorage(NextLinger.supplementsKey)
  private var lingerSupplements = NextLinger.supplementsDefault

  /// Enabled sections that actually contribute to the Next list — the only
  /// ones with a meaningful "Show in Next" toggle.
  private var todaySections: [SectionConfig] {
    store.sections.filter {
      $0.isEnabled && (SectionManifest.byKey[$0.key]?.appearsInToday ?? false)
    }
  }

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $suggestionsEnabled) {
          Label("Suggestions", systemImage: "sparkles")
        }
        if suggestionsEnabled {
          Toggle("Workouts", isOn: $suggestTraining)
          Toggle("Break your fast", isOn: $suggestFastBreak)
          Toggle("Mood check-in", isOn: $suggestMood)
          Toggle("Intake reminders", isOn: $suggestIntake)
        }
      } header: {
        Text("Suggestions")
      } footer: {
        Text("Learned, time-of-day nudge cards at the top of the Next list — they appear around when you usually do the thing and go quiet once you log it. Turn the lot off, or just the kinds you don't want.")
      }

      Section {
        Toggle(isOn: $lingerHabits) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Carry over missed habits")
            Text("Keep an undone habit on the list past its time of day, until you do it.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Toggle(isOn: $lingerSupplements) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Carry over missed doses")
            Text("Keep an undone supplement on the list past its time of day, until you take it.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Carry over missed items")
      } footer: {
        Text("Off shows each item only during its slot. Tasks and chores have no time of day, so they always stay until done.")
      }

      if !todaySections.isEmpty {
        Section {
          ForEach(todaySections, id: \.key) { config in
            Toggle(isOn: showInNextBinding(config)) {
              Label(
                SectionManifest.displayLabel(key: config.key, stored: config.label),
                systemImage: SectionManifest.byKey[config.key]?.iconSymbol ?? "circle.fill")
            }
          }
        } header: {
          Text("Sections in Next")
        } footer: {
          Text("Which sections contribute their entries to the Next list. Turning one off here hides it from Next only — its page and data stay put.")
        }
      }

      Section {
        NavigationLink(value: SettingsView.SettingsDestination.timeOfDay) {
          Label("Time of Day", systemImage: "clock")
        }
      } footer: {
        Text("Morning / afternoon / evening boundaries decide when a bucketed habit or supplement counts as “due now” in the list.")
      }
    }
    .formStyle(.grouped)
  }

  /// Read `SectionConfig.showInToday`, write through the same mirror the
  /// section detail pane uses — so this roll-up never becomes a second source
  /// of truth. Mirrors `SectionDetailPane.setShowInToday`.
  private func showInNextBinding(_ config: SectionConfig) -> Binding<Bool> {
    Binding(
      get: { config.showInToday },
      set: { value in
        SettingsMirror.setSectionShowInToday(config.key,
                                             showInToday: value,
                                             context: modelContext,
                                             engine: ckEngine)
        store.sections = store.sections.map { c in
          c.key == config.key
            ? SectionConfig(key: c.key, label: c.label, color: c.color,
                            isEnabled: c.isEnabled, showInToday: value,
                            showInSpotlight: c.showInSpotlight,
                            hasOnboarded: c.hasOnboarded)
            : c
        }
      }
    )
  }
}

// MARK: - Layout submenu
//
// Picker for the homepage renderer, plus one generic example
// (icon + label, no data) showing what the selected mode looks like.
// Example is mode-styled — Tile card / Sparkline row / Heatmap row.

struct LayoutSettingsPane: View {
  @AppStorage(SettingsKey.homepageLayout)
  private var homepageLayoutRaw: String = HomepageLayoutMode.tiles.rawValue

  private var current: HomepageLayoutMode {
    HomepageLayoutMode(rawValue: homepageLayoutRaw) ?? .tiles
  }

  private var binding: Binding<HomepageLayoutMode> {
    Binding(
      get: { HomepageLayoutMode(rawValue: homepageLayoutRaw) ?? .tiles },
      set: { homepageLayoutRaw = $0.rawValue }
    )
  }

  var body: some View {
    let current = self.current
    Form {
      Section {
        Picker(selection: binding) {
          ForEach(HomepageLayoutMode.allCases) { mode in
            Label {
              HStack {
                Text(mode.title)
                Spacer()
                if !mode.isImplemented {
                  Text("Coming soon")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
            } icon: {
              Image(systemName: mode.icon)
            }
            .tag(mode)
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
        #if os(iOS)
        .pickerStyle(.inline)
        #endif
      } footer: {
        Text(current.summary)
      }

      Section {
        LayoutPreviewExample(mode: current)
          .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
      } header: {
        Text("Example")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Insights submenu
//
// Tunes the Insights correlation explorer (the `InsightsDestinationView`
// grid) — time window, section filter, and which extra sections
// (supplements table / insufficient-data fold-out) render below the
// trusted + exploratory grids.

struct CorrelationsSettingsPane: View {
  @AppStorage(SettingsKey.correlationsWindowDays)
  private var windowDays: Int = 365
  @AppStorage(SettingsKey.correlationsSectionFilter)
  private var sectionFilter: String = "all"
  @AppStorage(SettingsKey.correlationsShowSupplements)
  private var showSupplements: Bool = true
  @AppStorage(SettingsKey.correlationsShowInsufficient)
  private var showInsufficient: Bool = false

  private let sectionOptions: [(key: String, label: String)] = [
    ("all",         "All"),
    ("habits",      "Habits"),
    ("supplements", "Supplements"),
    ("training",    "Training"),
    ("nutrition",   "Nutrition"),
    ("intake",      "Intake"),
    ("gut",         "Gut"),
    ("sleep",       "Sleep"),
  ]

  var body: some View {
    Form {
      Section {
        Picker("Time window", selection: $windowDays) {
          Text("30 days").tag(30)
          Text("90 days").tag(90)
          Text("6 months").tag(180)
          Text("1 year").tag(365)
          Text("2 years").tag(730)
        }
        Picker("Section filter", selection: $sectionFilter) {
          ForEach(sectionOptions, id: \.key) { Text($0.label).tag($0.key) }
        }
      } footer: {
        Text("Window sets how far back to look for patterns. Section filter narrows which relationships appear — a pairing shows if either section matches.")
      }

      Section {
        Toggle("Show Supplements → Sleep table", isOn: $showSupplements)
        Toggle("Show insufficient-data section", isOn: $showInsufficient)
      } footer: {
        Text("Relationships with fewer than \(CorrelationEngine.minN) overlapping days are too sparse to chart, but listed here so you can see what's almost ready.")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - App Icon submenu

struct AppIconSettingsPane: View {
  #if os(iOS)
  @State private var selectedIcon: AppIconOption = .current
  @State private var iconError: String? = nil
  @State private var iconChangeInFlight = false
  #endif

  var body: some View {
    Form {
      #if os(iOS)
      if UIApplication.shared.supportsAlternateIcons {
        appIconSection
      } else {
        Section {
          Text("App icon selection isn’t available on this device.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      #else
      Section {
        Text("App icon selection is available on the iPhone and iPad app.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      #endif
    }
    .formStyle(.grouped)
    #if os(iOS)
    .onAppear { selectedIcon = .current }
    .alert("Couldn’t Change App Icon", isPresented: Binding(
      get: { iconError != nil },
      set: { if !$0 { iconError = nil } }
    )) {
      Button("OK", role: .cancel) { iconError = nil }
    } message: {
      Text(iconError ?? "Please try again.")
    }
    #endif
  }

  #if os(iOS)
  private var appIconSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 14) {
          AppIconPreview(option: selectedIcon, size: 62)
          VStack(alignment: .leading, spacing: 3) {
            Text("Current Icon")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(selectedIcon.title)
              .font(.septenaCardTitle)
            if selectedIcon == .default {
              Text("The original multicolor icon.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
              Text("Light mode uses a \(selectedIcon.title.lowercased()) background with white discs. Dark mode uses transparent artwork so the system background shows through behind \(selectedIcon.title.lowercased()) discs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
          ForEach(AppIconOption.allCases) { option in
            Button {
              selectIcon(option)
            } label: {
              AppIconChoiceCard(option: option,
                                isSelected: option == selectedIcon,
                                isDisabled: iconChangeInFlight)
            }
            .buttonStyle(.plain)
            .disabled(iconChangeInFlight)
          }
        }
      }
      .padding(.vertical, 4)
    } footer: {
      Text("iOS shows a confirmation prompt each time you switch icons.")
    }
  }

  private func selectIcon(_ option: AppIconOption) {
    guard option != selectedIcon, !iconChangeInFlight else { return }
    iconChangeInFlight = true
    UIApplication.shared.setAlternateIconName(option.alternateIconName) { error in
      DispatchQueue.main.async {
        iconChangeInFlight = false
        if let error {
          selectedIcon = .current
          iconError = error.localizedDescription
        } else {
          selectedIcon = option
        }
      }
    }
  }
  #endif
}

// MARK: - Layout preview
//
// One generic example rendered with the real homepage components
// (`DomainTile`, `DenseHomepageView`, `HeatmapHomepageView`,
// `RingsHomepageView`) populated from a single deterministic
// `HomepageDomainData` — the same view model each mode draws on the
// homepage, so the preview matches what the homepage actually draws
// rather than a hand-rolled approximation.

private enum LayoutPreviewSample {
  /// Deterministic 90-day series shared by all four renderers — the
  /// tile's 7-day histogram slices the trailing window itself, the
  /// sparkline and heatmap consume the full 90-day window. Values span
  /// 1…7 so every day is visible (no all-zero gaps in the 7-day strip)
  /// while still covering enough range for the heatmap to bucket into
  /// all five levels.
  static let bars90: [Int] = (0..<90).map { i in
    let phase = Double(i) * 0.42
    let v = 4.0 + 2.6 * sin(phase) + 1.2 * sin(phase * 0.31)
    return max(1, Int(v.rounded()))
  }

  static let accent: Color = .green

  static let domainData = HomepageDomainData(
    domain: .habits,
    title: "Habits",
    accent: accent,
    headline: "5 of 7 today",
    headlineStats: [
      .init(label: "Today",   value: "5"),
      .init(label: "Skipped", value: "1"),
    ],
    progress: .init(label: "Today's progress", current: 5, target: 7),
    history: .bars(bars90),
    tap: .openSheet(.habits)
  )
}

private struct LayoutPreviewExample: View {
  let mode: HomepageLayoutMode

  var body: some View {
    Group {
      switch mode {
      case .tiles:
        // Same `DomainTile` + `HomepageDomainData` the histogram dashboard
        // actually renders (see `WeekDashboardView` `.tiles`), so the preview
        // can't drift from the real tile. The dashboard lays tiles out in a
        // 2-column grid, so a single tile is half-width — mirror that here
        // with a trailing spacer rather than letting it stretch full width.
        HStack(spacing: 0) {
          DomainTile(data: LayoutPreviewSample.domainData)
            .frame(maxWidth: .infinity)
          Color.clear.frame(maxWidth: .infinity)
        }
      case .dense:
        DenseHomepageView(
          items: [LayoutPreviewSample.domainData],
          onTap: { _ in },
          menuContent: { _ in EmptyView() }
        )
      case .heatmap:
        HeatmapHomepageView(
          items: [LayoutPreviewSample.domainData],
          onTap: { _ in },
          menuContent: { _ in EmptyView() }
        )
      case .rings:
        RingsHomepageView(
          items: [LayoutPreviewSample.domainData],
          onTap: { _ in },
          menuContent: { _ in EmptyView() }
        )
      }
    }
    .allowsHitTesting(false)
  }
}

/// The Septena mark as a contained jewel — the seven discs in their
/// canonical colors on a graphite plate with a hairline foil rim. This is
/// the premium emblem for Septena+: the rainbow distilled into an object
/// you earn, never smeared as a wash. Size-parametrized so it works inline
/// (a badge dot) and as a paywall hero.
struct SeptenaDiscMark: View {
  var size: CGFloat = 44

  var body: some View {
    let corner = size * 0.232
    ZStack {
      RoundedRectangle(cornerRadius: corner, style: .continuous)
        .fill(SeptenaPlus.ink)
      SeptenaPlus.sheen(corner: corner)
      ForEach(Array(SeptenaPlus.discCenters.enumerated()), id: \.offset) { index, center in
        Circle()
          .fill(SeptenaPlus.discColors[index])
          .frame(width: size * 0.176, height: size * 0.176)
          .position(x: size * center.x, y: size * center.y)
      }
    }
    .frame(width: size, height: size)
    .overlay(
      RoundedRectangle(cornerRadius: corner, style: .continuous)
        .strokeBorder(SeptenaPlus.foilGradient, lineWidth: max(0.6, size * 0.022))
    )
    .shadow(color: .black.opacity(0.28), radius: size * 0.11, y: size * 0.045)
  }
}

/// Flighty-style feature row — a tinted rounded-square glyph chip with a
/// title + detail. Reusable wherever the membership perks are listed.
struct SeptenaPlusFeatureRow: View {
  let feature: SeptenaPlusFeature

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(SeptenaPlus.ink)
        .frame(width: 38, height: 38)
        .overlay(SeptenaPlus.sheen(corner: 10))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(SeptenaPlus.foil.opacity(0.42), lineWidth: 0.75)
        )
        .overlay(
          Image(systemName: feature.icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(SeptenaPlus.foilGradient)
        )
      VStack(alignment: .leading, spacing: 3) {
        // The reason/perk text is stored as English in `SeptenaPlus`; render it
        // through LocalizedStringKey so the string catalog can translate it
        // (a plain `Text(String)` would print verbatim, unlocalized).
        Text(LocalizedStringKey(feature.title))
          .font(.subheadline.weight(.semibold))
        Text(LocalizedStringKey(feature.detail))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }
}

/// Compact "Supporter" pill worn on the profile. Ink capsule with a
/// champagne-foil hairline and a small foil heart, so it reads as a small
/// pressed-metal plate of thanks rather than a colorful sticker. Marks who
/// chose to support — it never gates anything.
struct SeptenaPlusBadge: View {
  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "heart.fill")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(SeptenaPlus.foil)
      Text(LocalizedStringKey(SeptenaPlus.badgeWord))
        .foregroundStyle(.white)
    }
    .font(.caption2.weight(.bold))
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(SeptenaPlus.ink, in: Capsule())
    .overlay(Capsule().strokeBorder(SeptenaPlus.foil.opacity(0.5), lineWidth: 0.75))
  }
}

/// The one member badge worn beside a name across every community surface —
/// the roadmap, testimonials, support threads, and the profile pane. Precedence
/// is maintainer → moderator → supporter tier → nothing, so a general member
/// shows no badge and callers can drop it in unconditionally (it renders empty
/// when there's nothing to say). Keeping this the single source is what makes
/// the badge read the same everywhere. Supporter tiers reuse the `SeptenaPlus`
/// ink-and-foil look of `SeptenaPlusBadge` so the two never diverge.
struct CommunityBadge: View {
  var role: String?
  var supporterTier: String?

  var body: some View {
    if let kind = Kind(role: role, supporterTier: supporterTier) {
      HStack(spacing: 3) {
        Image(systemName: kind.symbol)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(kind.usesFoil ? AnyShapeStyle(SeptenaPlus.foil) : AnyShapeStyle(Color.secondary))
        Text(LocalizedStringKey(kind.word))
          .foregroundStyle(kind.usesFoil ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
      }
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(kind.background, in: Capsule())
      .overlay {
        if kind.usesFoil {
          Capsule().strokeBorder(SeptenaPlus.foil.opacity(0.5), lineWidth: 0.75)
        }
      }
      .accessibilityLabel(Text(kind.accessibility))
    }
  }

  enum Kind {
    case maker, moderator, supporter, founding

    /// Role wins over tier — the maker/moderator mark is the identity that
    /// matters most, and a maintainer needn't also wear a supporter badge.
    init?(role: String?, supporterTier: String?) {
      switch role {
      case "maintainer": self = .maker; return
      case "moderator":  self = .moderator; return
      default: break
      }
      switch supporterTier {
      case "lifetime":            self = .founding
      case "annual", "monthly":   self = .supporter
      default:                    return nil
      }
    }

    var symbol: String {
      switch self {
      case .maker:      return "checkmark.seal.fill"
      case .moderator:  return "shield.fill"
      case .supporter:  return "heart.fill"
      case .founding:   return "star.fill"
      }
    }

    var word: String {
      switch self {
      case .maker:      return "Maker"
      case .moderator:  return "Mod"
      case .supporter:  return SeptenaPlus.badgeWord  // "Supporter"
      case .founding:   return "Founding"
      }
    }

    /// Maker/supporter wear the premium ink-and-foil plate; moderator stays a
    /// quiet neutral capsule so it doesn't compete with it.
    var usesFoil: Bool { self != .moderator }

    var background: AnyShapeStyle {
      usesFoil ? AnyShapeStyle(SeptenaPlus.ink) : AnyShapeStyle(Color.secondary.opacity(0.15))
    }

    var accessibility: String {
      switch self {
      case .maker:      return "Maker"
      case .moderator:  return "Moderator"
      case .supporter:  return "Supporter"
      case .founding:   return "Founding supporter"
      }
    }
  }
}

/// The quiet counterpart to `SeptenaPlusBadge`, worn by a non-supporter. The
/// whole app is free, so this is a plain statement of fact, not a nudge — a
/// muted capsule with no foil, deliberately understated next to the supporter
/// mark. It only exists so the profile reads the same either way (a labelled
/// tier) instead of looking empty until you support.
struct FreeAccountBadge: View {
  var body: some View {
    Text("Free")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(.quaternary, in: Capsule())
  }
}

/// The support screen. NOT a paywall — it sells nothing functional. A
/// free-forever promise up top, the reasons supporting matters, the three
/// amounts (annual highlighted as the default), and an honest line that you
/// unlock nothing. Tiers show the real localized `Product.displayPrice` and a
/// tap runs a StoreKit purchase via `SupportStore`; a completed purchase (or a
/// restore) flips the entitlement and the screen dismisses itself.
struct SeptenaPlusPaywall: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(SupportStore.self) private var store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The thank-you celebration, played ON this screen (the topmost layer) so
  /// it's visible regardless of what presented us — the root `LogCommitOverlay`
  /// sits below Settings, so firing it there would play out of sight.
  @State private var celebrationStyle: LogCommitStyle?
  @State private var celebrateTrigger = 0

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          header
          VStack(alignment: .leading, spacing: 18) {
            ForEach(SeptenaPlus.reasons) { reason in
              SeptenaPlusFeatureRow(feature: reason)
            }
          }
          tiers
          honesty
        }
        .padding(20)
      }
      .background(Theme.groupedBackground.ignoresSafeArea())
      .navigationTitle(Text(LocalizedStringKey(SeptenaPlus.name)))
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Maybe later") { dismiss() }
        }
      }
      // A completed purchase (or restore) flips the entitlement. Play the
      // app's own milestone celebration on this screen, then auto-dismiss —
      // rendering it here (not on the root overlay) keeps it visible above
      // Settings. Under Reduce Motion, skip the animation and just close.
      .onChange(of: store.isSupporter) { _, nowSupporter in
        guard nowSupporter else { return }
        Haptics.success()
        if reduceMotion {
          Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            dismiss()
          }
        } else {
          celebrationStyle = .septenaOpen(headline: String(localized: "Thank you"),
                                          caption: String(localized: "YOU'RE A SUPPORTER"),
                                          palette: .gold)
          celebrateTrigger += 1
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.9))
            dismiss()
          }
        }
      }
    }
    .overlay {
      if let style = celebrationStyle {
        LogCommitStyleView(style: style, trigger: celebrateTrigger)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    #if os(macOS)
    .frame(width: 500, height: 680)
    #endif
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 14) {
      SeptenaDiscMark(size: 56)
      VStack(alignment: .leading, spacing: 6) {
        Text("Septena is free. All of it. Always.")
          .font(.title2.weight(.semibold))
        Text("Every section, every feature — yours, with nothing held back and no ads watching you. That's a promise, not a trial. If it's become part of how you run your life, you can chip in to keep it independent. You won't unlock anything — there's nothing to unlock.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var tiers: some View {
    VStack(spacing: 12) {
      ForEach(SeptenaPlus.tiers) { tier in
        let product = store.product(forTier: tier.id)
        SupportTierCard(tier: tier,
                        product: product,
                        inFlight: store.purchaseInFlight == product?.id) {
          guard let product else { return }
          Task { await store.purchase(product) }
        }
      }
      if store.loadFailed {
        Text("Prices couldn't load right now — check your connection and reopen this screen.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 2)
      }
      Button("Restore purchases") {
        Task { await store.restore() }
      }
      .font(.subheadline)
      .frame(maxWidth: .infinity)
      .padding(.top, 4)
    }
  }

  private var honesty: some View {
    Text("Not now? Genuinely fine — the app stays exactly the same. You can support any time from Settings.")
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A single tappable support tier. The highlighted (annual) tier wears the
/// ink/foil treatment so it reads as the default; the rest are quiet
/// outlined cards. Tapping becomes a supporter at that amount.
struct SupportTierCard: View {
  let tier: SupportTier
  /// The resolved StoreKit product, if loaded — its `displayPrice` is the
  /// real, localized price. Falls back to the tier's static price otherwise.
  var product: Product?
  /// True while this tier's purchase is in flight (show a spinner, block taps).
  var inFlight: Bool = false
  let onTap: () -> Void

  private var priceText: String { product?.displayPrice ?? tier.price }

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 3) {
          // Title / note / cadence are stored as English in `SeptenaPlus.tiers`;
          // render through LocalizedStringKey so the catalog can translate them.
          // (`priceText` stays verbatim — it's StoreKit's localized displayPrice,
          // or a €-amount fallback, neither of which the catalog should touch.)
          Text(LocalizedStringKey(tier.title))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tier.highlighted ? .white : .primary)
          if let note = tier.note {
            Text(LocalizedStringKey(note))
              .font(.caption)
              .foregroundStyle(tier.highlighted ? .white.opacity(0.7) : .secondary)
          }
        }
        Spacer(minLength: 8)
        if inFlight {
          ProgressView()
            .tint(tier.highlighted ? .white : .primary)
        } else {
          VStack(alignment: .trailing, spacing: 1) {
            Text(priceText)
              .font(.title3.weight(.bold))
              .foregroundStyle(tier.highlighted ? AnyShapeStyle(SeptenaPlus.foilGradient) : AnyShapeStyle(.primary))
            Text(LocalizedStringKey(tier.cadence))
              .font(.caption2)
              .foregroundStyle(tier.highlighted ? .white.opacity(0.7) : .secondary)
          }
        }
      }
      .padding(16)
      .background(
        ZStack {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(tier.highlighted ? AnyShapeStyle(SeptenaPlus.ink) : AnyShapeStyle(Theme.cardSurface))
          if tier.highlighted { SeptenaPlus.sheen(corner: 16) }
        }
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(tier.highlighted ? SeptenaPlus.foil.opacity(0.5)
                                          : Color.primary.opacity(0.08),
                        lineWidth: tier.highlighted ? 0.75 : 0.5)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(product == nil || inFlight)
    .opacity(product == nil ? 0.5 : 1)
  }
}

// MARK: - Identity (profile header + Account pane)
//
// Apple's Settings.app shows an Apple-ID card at the top of the list. We
// can't read the real iCloud avatar or name (no public API for either),
// so we render the standard substitute: a monogram avatar built from the
// user's given name (`welcomeName`, already CloudKit-synced) with the
// supporter status attached to that identity — a foil ring on the
// avatar plus a badge. The card pushes to `AccountSettingsPane`, the home
// for name, support, and iCloud sync state.

/// Circular monogram avatar. Initials over a neutral fill; a supporter
/// gets the champagne-foil ring so the thanks reads as part of who they
/// are, not a buried setting.
struct ProfileAvatar: View {
  let name: String
  let isPlus: Bool
  var size: CGFloat = 56

  private var initials: String {
    let words = name.trimmingCharacters(in: .whitespaces).split(separator: " ")
    // A single short token is almost certainly typed-in initials ("MZ",
    // "abc") — show it verbatim. A longer single name → its first letter.
    // Multi-word → first letter of the first two words.
    if words.count <= 1 {
      let token = words.first.map(String.init) ?? ""
      return (token.count <= 3 ? token : String(token.prefix(1))).uppercased()
    }
    return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
  }

  var body: some View {
    ZStack {
      Circle().fill(Color.secondary.opacity(0.18))
      if initials.isEmpty {
        Image(systemName: "person.fill")
          .font(.system(size: size * 0.46))
          .foregroundStyle(.secondary)
      } else {
        Text(initials)
          .font(.system(size: size * 0.4, weight: .semibold))
          .foregroundStyle(.primary)
      }
    }
    .frame(width: size, height: size)
    .overlay {
      if isPlus {
        Circle().inset(by: -3).strokeBorder(SeptenaPlus.foilGradient, lineWidth: 2)
      }
    }
  }
}

/// Top-of-Settings identity row (avatar + name + plan). The enclosing
/// `NavigationLink` supplies the disclosure chevron.
struct IdentityHeaderRow: View {
  @AppStorage(SettingsKey.welcomeName) private var welcomeName: String = ""
  @AppStorage(SettingsKey.plusUnlocked) private var plusUnlocked: Bool = false

  var body: some View {
    HStack(spacing: 14) {
      ProfileAvatar(name: welcomeName, isPlus: plusUnlocked, size: 56)
      VStack(alignment: .leading, spacing: 3) {
        Text(welcomeName.isEmpty ? "Your Profile" : welcomeName)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)
        if plusUnlocked {
          SeptenaPlusBadge()
        } else {
          FreeAccountBadge()
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
  }
}

/// The "Apple ID" analogue: name + avatar, membership (with the mock
/// unlock/relock toggle), and iCloud sync state — since there's no
/// Septena account, identity *is* the Apple ID / iCloud.
struct AccountSettingsPane: View {
  @AppStorage(SettingsKey.welcomeName) private var welcomeName: String = ""
  @AppStorage(SettingsKey.plusUnlocked) private var plusUnlocked: Bool = false
  @State private var showPaywall = false
  @State private var showManageSubscriptions = false
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store
  @Environment(SupportStore.self) private var supportStore

  var body: some View {
    Form {
      Section {
        HStack(spacing: 16) {
          ProfileAvatar(name: welcomeName, isPlus: plusUnlocked, size: 64)
          VStack(alignment: .leading, spacing: 4) {
            TextField("Your name", text: $welcomeName)
              .font(.title2.weight(.semibold))
              .textContentType(.givenName)
              #if os(iOS)
              .textInputAutocapitalization(.words)
              #endif
              .onChange(of: welcomeName) { _, newValue in
                store.setWelcomeName(newValue, context: modelContext, engine: ckEngine)
              }
            if plusUnlocked {
              SeptenaPlusBadge()
            } else {
              FreeAccountBadge()
            }
          }
        }
        .padding(.vertical, 6)
      } footer: {
        Text("Your name personalizes the home greeting and this profile. It syncs across your devices via iCloud.")
      }

      membershipSection

      Section {
        HStack {
          Label("Sync", systemImage: iCloudStatus.symbol)
          Spacer()
          Text(iCloudStatus.text).foregroundStyle(.secondary)
        }
      } header: {
        Text("iCloud")
      } footer: {
        Text("Septena keeps everything in your private iCloud — there's no separate Septena account. Your data and membership are tied to your Apple ID.")
      }

      // macOS only (renders nothing on iOS). Optional Sign in with Apple — the
      // App-Attest substitute that unlocks community features on this Mac and
      // does nothing else. Sits under Sync because it's the same Apple-ID story.
      CommunityAppleAccountSection()
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showPaywall) {
      SeptenaPlusPaywall()
    }
    #if os(iOS)
    .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
    #endif
  }

  @ViewBuilder
  private var membershipSection: some View {
    if plusUnlocked {
      Section {
        ForEach(SeptenaPlus.perks) { perk in
          SeptenaPlusFeatureRow(feature: perk)
        }
      } header: {
        Text("You're a supporter")
      } footer: {
        Text("Thank you — you're the reason Septena stays free and independent.")
      }
      Section {
        Button("Restore purchases") {
          Task { await supportStore.restore() }
        }
        #if os(iOS)
        Button("Manage subscription") {
          showManageSubscriptions = true
        }
        #endif
      } footer: {
        Text("Your support is tied to your Apple ID. Restore re-syncs it on a new device; managing lets you change or cancel an ongoing subscription.")
      }
    } else {
      Section {
        Button {
          showPaywall = true
        } label: {
          HStack(spacing: 14) {
            SeptenaDiscMark(size: 30)
            VStack(alignment: .leading, spacing: 2) {
              Text(LocalizedStringKey(SeptenaPlus.name))
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
              Text("The app is free. Chip in to keep it independent.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      } header: {
        // Unique string (not the shared "Support" key, which means help/support
        // elsewhere) so the localization can't collide with that context.
        Text("Support the app")
      }
    }
  }

  /// Friendly label for the live CloudKit account state (`CKEngine`
  /// publishes `accountStatus`). Keeps the iCloud row honest rather than
  /// claiming "synced" unconditionally.
  private var iCloudStatus: (text: String, symbol: String) {
    switch ckEngine.accountStatus {
    case .available:              return ("Active", "checkmark.icloud.fill")
    case .noAccount:              return ("No iCloud account", "exclamationmark.icloud.fill")
    case .restricted:             return ("Restricted", "xmark.icloud.fill")
    case .temporarilyUnavailable: return ("Temporarily unavailable", "exclamationmark.icloud.fill")
    default:                      return ("Checking…", "icloud")
    }
  }
}

struct AppIconPreview: View {
  @Environment(\.colorScheme) private var colorScheme
  let option: AppIconOption
  let size: CGFloat

  var body: some View {
    let isDarkMode = colorScheme == .dark
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.223, style: .continuous)
        .fill(option.background(forDarkMode: isDarkMode))
      ForEach(Array(SeptenaPlus.discCenters.enumerated()), id: \.offset) { index, center in
        Circle()
          .fill(option.dotColors(forDarkMode: isDarkMode)[index])
          .frame(width: size * 0.182, height: size * 0.182)
          .position(x: size * center.x, y: size * center.y)
      }
    }
    .frame(width: size, height: size)
    .overlay(
      RoundedRectangle(cornerRadius: size * 0.223, style: .continuous)
        .stroke(Color.black.opacity(isDarkMode ? 0.12 : (option == .default ? 0.07 : 0.09)), lineWidth: 0.8)
    )
    .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
  }
}

#if os(iOS)
private struct AppIconChoiceCard: View {
  let option: AppIconOption
  let isSelected: Bool
  let isDisabled: Bool

  var body: some View {
    VStack(spacing: 8) {
      ZStack(alignment: .topTrailing) {
        AppIconPreview(option: option, size: 64)
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .scaledFont(size: 18, weight: .semibold)
            .foregroundStyle(.white, .green)
            .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
            .offset(x: 5, y: -5)
        }
      }
      Text(option.title)
        .font(.footnote.weight(isSelected ? .semibold : .regular))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.9)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .background(cardBackground)
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(isSelected ? option.background.opacity(option == .default ? 0.18 : 0.92)
                           : Color.primary.opacity(0.08),
                lineWidth: isSelected ? 2 : 1)
    )
    .opacity(isDisabled ? 0.7 : 1)
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var cardBackground: some ShapeStyle {
    isSelected
      ? AnyShapeStyle(option.background.opacity(option == .default ? 0.08 : 0.16))
      : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
  }
}
#endif

// MARK: - Quick Actions
//
// Multi-select pane (capped at 4) that picks which sections appear in the
// Home Screen long-press menu. Persists as a comma-separated list of
// section keys in UserDefaults; on every change, `QuickActionsApplier`
// rebuilds `UIApplication.shared.shortcutItems` to match. Listing is
// driven by `store.sections` filtered to enabled rows so disabled
// sections can never be picked.

struct QuickActionsSettingsPane: View {
  @Environment(SettingsStore.self) private var store
  @AppStorage(SettingsKey.quickActionKeys) private var stored: String = ""

  private static let limit = 4

  private var selected: [String] {
    stored.split(separator: ",")
      .map { String($0) }
      .filter { !$0.isEmpty }
  }

  private var availableEntries: [(manifest: SectionManifest, accent: Color)] {
    // Iterate `store.sections` — the canonical ordered+complete list from
    // SettingsMirror.loadSections, which already ranks by `section_order` AND
    // appends enabled sections that aren't in the order yet. Re-deriving from
    // raw `serverSettings.sectionOrder` is the trap: it treats order as
    // membership, so a section enabled but absent from a stale order silently
    // vanishes here. `section_order` is ORDERING, never membership.
    store.sections.compactMap { config -> (SectionManifest, Color)? in
      guard config.isEnabled,
            let manifest = SectionManifest.byKey[config.key],
            manifest.supportsDashboard,
            WeekDestination(rawValue: config.key) != nil else { return nil }
      return (manifest, parseHexColor(config.color))
    }
  }

  var body: some View {
    Form {
      Section {
        ForEach(availableEntries, id: \.manifest.key) { entry in
          row(for: entry.manifest, accent: entry.accent)
        }
      } header: {
        HStack {
          Text("Sections")
          Spacer()
          Text("\(selected.count) / \(Self.limit)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      } footer: {
        Text("Pick up to \(Self.limit) sections. Each one becomes a shortcut in the Home Screen long-press menu, opening directly into that section.")
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private func row(for manifest: SectionManifest, accent: Color) -> some View {
    let isSelected = selected.contains(manifest.key)
    let isAtLimit = selected.count >= Self.limit
    Button {
      toggle(manifest.key)
    } label: {
      HStack(spacing: 12) {
        ColoredGlyph(icon: manifest.iconSymbol, color: accent, size: 22)
        VStack(alignment: .leading, spacing: 1) {
          let serverLabel = store.sections.first(where: { $0.key == manifest.key })?.label ?? ""
          Text(SectionManifest.displayLabel(key: manifest.key, stored: serverLabel))
            .foregroundStyle(.primary)
          if !manifest.shortDescription.isEmpty {
            Text(manifest.shortDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isSelected && isAtLimit)
    .opacity(!isSelected && isAtLimit ? 0.5 : 1)
  }

  private func toggle(_ key: String) {
    var current = selected
    if let idx = current.firstIndex(of: key) {
      current.remove(at: idx)
    } else {
      guard current.count < Self.limit else { return }
      current.append(key)
    }
    stored = current.joined(separator: ",")
    #if os(iOS)
    QuickActionsApplier.apply()
    #endif
  }
}

// MARK: - Motion Gallery
//
// A test surface for the commit-motion vocabulary: fire every log
// flourish (and its matched haptic) on demand, tune intensity / accent,
// and feel how each primitive reads. Uses the SAME renderers and haptics
// a real log site plays (`CommitFlourish` / `IgnitionView` /
// `CommitMotion.hapticSpec`) — so what you feel here is what ships.
// Reduce Motion still suppresses the visual centrally; the haptic fires.

struct MotionGalleryPane: View {
  @State private var intensity: Double = 1.0
  @State private var accentID: String = MotionGalleryPane.accents[0].id
  @State private var streak: Int = 30
  @State private var current: Demo = .burst
  @State private var trigger: Int = 0
  /// Live per-row state for the checkbox-feel demos below.
  @State private var feelDone: [String: Bool] = [:]

  /// One live checkbox per `CheckFeel` — the checkbox-local vocabulary the
  /// checkable rows use instead of canvas flourishes.
  private struct FeelDemo: Identifiable {
    let id: String
    let feel: CheckFeel
    let title: String
    let subtitle: String
  }
  private static let feelDemos: [FeelDemo] = [
    .init(id: "stamp", feel: .stamp, title: "Stamp",
          subtitle: "Tasks — crisp stamp + one pulse ring"),
    .init(id: "echo", feel: .echo, title: "Echo",
          subtitle: "Habits — the pulse answers itself: one more mark on the streak"),
    .init(id: "drop", feel: .drop, title: "Drop",
          subtitle: "Supplements — the fill falls in, lands with a soft splash"),
    .init(id: "tuck", feel: .tuck, title: "Tuck",
          subtitle: "Chores — stamps, dips, files the ring down the pile"),
  ]

  private var accent: Color {
    Self.accents.first { $0.id == accentID }?.color ?? .green
  }

  /// One row per thing the gallery can fire: the seven `CommitMotion`
  /// primitives plus `.ignition` (a sibling `LogCommitStyle`, not a
  /// CommitMotion — the habit-streak milestone).
  private enum Demo: String, CaseIterable, Identifiable {
    case burst, snap, bloom, sink, ripple, arc, fill, ignition
    var id: String { rawValue }

    /// The CommitMotion this row plays, or nil for `.ignition`.
    var motion: CommitMotion? {
      switch self {
      case .burst:    return .burst
      case .snap:     return .snap
      case .bloom:    return .bloom
      case .sink:     return .sink
      case .ripple:   return .ripple
      case .arc:      return .arc
      case .fill:     return .fill
      case .ignition: return nil
      }
    }

    var title: String {
      switch self {
      case .burst:    return "Burst"
      case .snap:     return "Snap"
      case .bloom:    return "Bloom"
      case .sink:     return "Sink"
      case .ripple:   return "Ripple"
      case .arc:      return "Arc"
      case .fill:     return "Fill"
      case .ignition: return "Ignition"
      }
    }

    // Where each motion *ships* now that the canvas is reserved (see footer).
    var subtitle: String {
      switch self {
      case .burst:    return "Confetti — clearing a daily stack: habits/supplements/chores (canvas); Mood HAP (in-sheet)"
      case .snap:     return "Ring + flash — Mood HAN (in-sheet), intake tracker (in-page)"
      case .bloom:    return "Soft swell — fast-breaking meal (canvas); training session (in-sheet)"
      case .sink:     return "Quiet dot — acknowledgment (Mood LAN, in-sheet)"
      case .ripple:   return "Full-screen sonar — training PR payoff (in-sheet)"
      case .arc:      return "Comet arc — last Today task cleared (canvas)"
      case .fill:     return "Full-page flood — hydration target reached (canvas)"
      case .ignition: return "Rings + streak number — milestone (7/30/100/365)"
      }
    }
  }

  private struct AccentChoice: Identifiable {
    let id: String
    let color: Color
  }
  private static let accents: [AccentChoice] = [
    .init(id: "green",  color: parseHexColor("#22c55e")),
    .init(id: "blue",   color: parseHexColor("#3b82f6")),
    .init(id: "orange", color: parseHexColor("#f97316")),
    .init(id: "purple", color: parseHexColor("#8b5cf6")),
    .init(id: "red",    color: parseHexColor("#ef4444")),
    .init(id: "cyan",   color: parseHexColor("#06b6d4")),
  ]

  var body: some View {
    Form {
      Section {
        ForEach(Demo.allCases) { demo in
          Button { fire(demo) } label: { row(demo) }
            .buttonStyle(.plain)
        }
      } header: {
        Text("Tap to play")
      } footer: {
        Text("Each row fires the same renderer and haptic a real log uses. Under Reduce Motion the visual is suppressed (by design) — you'll still feel the haptic.")
      }

      // Checkable rows celebrate at the checkbox, never on the canvas —
      // checking things off is the app's highest-frequency action. Each
      // type has its own feel (see `CheckFeel`); these are live primitives.
      Section {
        ForEach(Self.feelDemos) { demo in
          HStack(spacing: 12) {
            TaskCheckbox(tint: accent,
                         isDone: feelDone[demo.id] ?? false,
                         feel: demo.feel,
                         ignoresUserPreference: true,
                         onToggle: {
                           let next = !(feelDone[demo.id] ?? false)
                           feelDone[demo.id] = next
                           if next {
                             Haptics.play(demo.feel.hapticSpec())
                           } else {
                             Haptics.tap()
                           }
                         })
            VStack(alignment: .leading, spacing: 2) {
              Text(demo.title).foregroundStyle(.primary)
              Text(demo.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
          }
        }
      } header: {
        Text("Checkbox feels")
      } footer: {
        Text("Checkable rows celebrate at the box — four feels separated by rhythm: one beat, two spaced beats, fall-then-thud, thud-then-close — each with a CoreHaptics pattern timed to its visual. The full-screen canvas is reserved for milestones (habit streaks, PRs, goal rungs — Ignition / Milestone) and at-most-once-a-day completion moments: clearing your last Today task (Arc), hitting your hydration target (Fill), the first meal that breaks your fast (Bloom), and clearing your whole day's habits, supplements, or chores (Burst). Everyday logs — gut, symptoms, medications, repeat intake, groceries — confirm with haptic + VoiceOver only; Mood and a finished training session play inside their own sheet.")
      }

      Section("Accent") {
        HStack(spacing: 12) {
          ForEach(Self.accents) { choice in
            Button {
              accentID = choice.id
              fire(current)
            } label: {
              Circle()
                .fill(choice.color)
                .frame(width: 28, height: 28)
                .overlay(
                  Circle()
                    .strokeBorder(Color.primary.opacity(accentID == choice.id ? 0.9 : 0), lineWidth: 2)
                    .padding(-3)
                )
            }
            .buttonStyle(.plain)
          }
          Spacer()
        }
        .padding(.vertical, 2)
      }

      Section {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Intensity")
            Spacer()
            Text(String(format: "%.2f", intensity))
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Slider(value: $intensity, in: 0.5...1.5)
        }
        Stepper("Streak: \(streak) days", value: $streak, in: 1...365)
      } header: {
        Text("Parameters")
      } footer: {
        Text("Intensity scales each motion's loudness — sink ignores it on purpose. Streak drives the Ignition milestone number.")
      }
    }
    .formStyle(.grouped)
    .overlay { flourishOverlay }
  }

  @ViewBuilder
  private var flourishOverlay: some View {
    if current == .ignition {
      IgnitionView(accent: accent, streak: streak, subject: "Habit", trigger: trigger)
        .allowsHitTesting(false)
    } else if let motion = current.motion {
      // The gallery exists to feel motions on demand, so it bypasses the
      // global "Logging animations" opt-out (Reduce Motion still applies).
      CommitFlourish(motion: motion, accent: accent, intensity: intensity,
                     trigger: trigger, ignoresUserPreference: true)
    }
  }

  private func row(_ demo: Demo) -> some View {
    HStack(spacing: 12) {
      Circle()
        .fill(accent.opacity(0.18))
        .frame(width: 30, height: 30)
        .overlay(Image(systemName: "play.fill").font(.caption).foregroundStyle(accent))
      VStack(alignment: .leading, spacing: 2) {
        Text(demo.title).foregroundStyle(.primary)
        Text(demo.subtitle).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .contentShape(Rectangle())
  }

  private func fire(_ demo: Demo) {
    current = demo
    if let motion = demo.motion {
      Haptics.play(motion.hapticSpec(intensity: intensity))
    } else {
      Haptics.success()  // ignition keeps the milestone success haptic
    }
    trigger += 1
  }
}

// MARK: - Section detail
//
// One pane per section, addressed by stable key. Identity (icon, label,
// color, description) comes from the local `SectionManifest`; the user's
// installed `SectionEntity` (label/color) overrides the defaults when
// present. Per-key content below uses cached catalog data from
// `SettingsStore` — intake catalogs, etc. Sections
// without catalog data show identity only. Tasks is special-cased to
// host the local task prefs (badge, today, sort) that used to live in
// a top-level Tasks pane.

// MARK: - Palette
