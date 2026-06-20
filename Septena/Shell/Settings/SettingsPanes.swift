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
  @AppStorage(SettingsKey.shareUsageData) private var share: Bool = true
  @AppStorage(SettingsKey.appLockEnabled) private var appLockEnabled: Bool = false
  @AppStorage(SettingsKey.appLockGraceSeconds) private var appLockGrace: Int = 60

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
        Toggle("Share anonymous usage data", isOn: $share)
      } footer: {
        Text("Helps us understand which features people use, so we improve the right things.")
      }

      Section("What is sent") {
        bullet("Which screens you open (e.g. \"Nutrition\", \"Sleep\")")
        bullet("App version, build, and platform (iOS or macOS)")
      }

      Section("What is never sent") {
        bullet("Anything you log — food, intake, supplements, sleep, mood, notes. None of it leaves your device through analytics.")
        bullet("Any identifier that links events to you, or links today's session to yesterday's.")
        bullet("Your IP address. The analytics provider uses it briefly to derive your country, then discards it.")
      }

      Section {
        EmptyView()
      } footer: {
        VStack(alignment: .leading, spacing: 8) {
          Text("Analytics is provided by Plausible Analytics (EU-hosted, cookie-free).")
          Link("plausible.io/privacy",
               destination: URL(string: "https://plausible.io/privacy")!)
            .font(.callout)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func bullet(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("•").foregroundStyle(.secondary)
      Text(text).foregroundStyle(.primary)
    }
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
  @AppStorage(SettingsKey.wheelTodayOnly)
  private var wheelTodayOnly: Bool = true
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
      } footer: {
        Text("Layout picks how the homepage renders — Histogram, Sparkline, Heatmap, Rings, or Wheel. Insights tunes the cross-section correlation explorer.")
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
        Toggle(isOn: Binding(get: { !wheelTodayOnly },
                             set: { wheelTodayOnly = !$0 })) {
          Label("Open on the full week", systemImage: "calendar")
        }
      } header: {
        Text("Day dial")
      } footer: {
        Text("Start day at wake rolls the dial over when you wake rather than at midnight, so a late night stays on the same day. Open on the full week starts on the last 7 days instead of today — tap any wheel to switch.")
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
    }
    .formStyle(.grouped)
  }
}

// MARK: - General (app behavior)

/// The small, honest catch-all Apple keeps too: time boundaries, the app icon,
/// Home Screen quick actions, and the logging-animation switch. Notifications
/// graduated to its own root row; homepage settings moved to Home.
struct GeneralSettingsPane: View {
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
    Form {
      Section {
        Picker(selection: unitsBinding) {
          Text("Metric (kg, km)").tag(WeightUnit.kg)
          Text("Imperial (lb, mi)").tag(WeightUnit.lb)
        } label: {
          Label("Units", systemImage: "scalemass")
        }
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
    .formStyle(.grouped)
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
// (`ModuleTile`, `DenseHomepageView`, `HeatmapHomepageView`) populated
// with deterministic fake data — so the preview matches what the
// homepage actually draws, not a hand-rolled approximation.

private enum LayoutPreviewSample {
  /// Deterministic 90-day series shared by all three renderers — the
  /// tile's 7-day histogram is just `bars90.suffix(7)`, the sparkline
  /// and heatmap consume the full 90-day window. Values span 1…7 so
  /// every day is visible (no all-zero gaps in the 7-day strip) while
  /// still covering enough range for the heatmap to bucket into all
  /// five levels.
  static let bars90: [Int] = (0..<90).map { i in
    let phase = Double(i) * 0.42
    let v = 4.0 + 2.6 * sin(phase) + 1.2 * sin(phase * 0.31)
    return max(1, Int(v.rounded()))
  }

  /// Trailing 7-day window of `bars90` — same source data, just sliced.
  static let bars7: [Int] = Array(bars90.suffix(7))
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
        ModuleTile(
          title: "Habits",
          accent: LayoutPreviewSample.accent,
          stats: [
            .init(label: "Today",   value: "5"),
            .init(label: "Skipped", value: "1"),
          ],
          progress: .init(
            label: "Today's progress",
            current: 5,
            target: 7
          ),
          history: .init(label: "7-day adherence", values: LayoutPreviewSample.bars7)
        )
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

// MARK: - Support Septena (patronage, not a paid tier)
//
// The whole app is free — every section, every feature, forever, with
// nothing gated. "Support Septena" is a pure tip jar: an optional way to
// keep the app independent and ad-free. A supporter unlocks NOTHING another
// user can't have; the only thing it changes is cosmetic (a "Supporter"
// badge + the avatar foil ring). That discipline is the whole product, so
// don't put a real feature behind `plusUnlocked` — ship it free.
//
// Purchases run through StoreKit 2 (`SupportStore`). Locally they resolve
// against Config/Septena.storekit wired into the scheme, so the flow is
// testable with no App Store Connect account; the matching ASC products are
// still to be created (their ids are permanent once they are). `SupportStore`
// mirrors the entitlement into `SettingsKey.plusUnlocked`. (Internal type
// names keep the `SeptenaPlus` prefix for continuity; everything user-facing
// reads "Support Septena".)

/// One "why support" reason. The support screen renders the list straight
/// from `SeptenaPlus.reasons`, so adding one is a one-line append. Keep `id`
/// stable. Also reused for the cosmetic perks a supporter actually gets.
struct SeptenaPlusFeature: Identifiable {
  let id: String
  let icon: String      // SF Symbol
  let title: String
  let detail: String
}

/// One support tier shown on the support screen. Annual is the highlighted
/// default; lifetime is the one-time "Founding Supporter". `id` maps to a
/// future StoreKit product identifier.
struct SupportTier: Identifiable {
  let id: String
  let title: String
  let price: String
  let cadence: String     // "per year" / "per month" / "one time"
  let note: String?       // e.g. "Two months free", "Lifetime"
  let highlighted: Bool
}

enum SeptenaPlus {
  /// User-facing name of the support offering (no "+", which would imply
  /// gated features — there are none).
  static let name = "Support Septena"
  /// The single word worn by a supporter (badge + thank-you copy).
  static let badgeWord = "Supporter"

  // MARK: Premium finish — "Obsidian + disc medallion"
  //
  // The rainbow is the *free* app's identity (the seven sections). The
  // membership is its refined, contained form: a graphite surface carrying a
  // single champagne-foil accent, with the spectrum distilled into a small
  // precise medallion (`SeptenaDiscMark`) — a jewel you earn, never a gradient
  // smeared across text. Restraint reads as premium; maximalism reads as free.
  //
  // Every value here is FIXED, never run through the global dark-mode `adaptive`
  // lift (`parseHexColor`): the lift hoists anything below 50% lightness up to
  // a flat gray, which would dissolve the obsidian plate into mud — exactly the
  // bug this finish exists to avoid. The foil and discs are the same in both
  // appearances (`AdaptiveColor.raw`); only `ink` is hand-tuned per mode.

  /// Authored-as-stored color, no dark-mode lift — the whole finish is fixed.
  private static func fixed(_ hex: String) -> Color { AdaptiveColor.raw(hex) ?? .gray }

  /// Graphite "ink" surface — the metal membership card. Deep graphite in
  /// light mode (pops against the white page); a *raised* graphite in dark
  /// mode that sits a touch lighter than the near-black sheet (~#1C1C1E) so the
  /// card reads as a jewel raised off the canvas, not a hole punched into it.
  static let ink = LinearGradient(
    colors: [AdaptiveColor.dual(light: "#33353B", dark: "#3A3D45"),
             AdaptiveColor.dual(light: "#17181B", dark: "#23252B")],
    startPoint: .top, endPoint: .bottom
  )

  /// Champagne-gold foil — the single Plus accent. Warm, to sit with the
  /// app's New York serif. Used flat for fills/strokes…
  static let foil = fixed("#C9A86A")
  /// …and as a metallic sweep for rims and the avatar ring.
  static let foilGradient = LinearGradient(
    colors: [fixed("#E7D29A"), fixed("#C9A86A"), fixed("#9C7E45")],
    startPoint: .topLeading, endPoint: .bottomTrailing
  )

  /// A faint top-down white sheen clipped to a rounded rect of `corner`, laid
  /// over an `ink` surface so it reads as raised metal with a glossed top edge
  /// rather than a flat slab — the cue that sells the card in dark mode.
  static func sheen(corner: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: corner, style: .continuous)
      .fill(LinearGradient(colors: [.white.opacity(0.10), .clear],
                           startPoint: .top, endPoint: .center))
      .allowsHitTesting(false)
  }

  /// Canonical seven-disc palette (red → orange → yellow → green → cyan →
  /// blue → purple) — the only place the spectrum survives, inside the
  /// medallion. Fixed (no lift) so the jewel stays the app-icon spectrum.
  static let discColors: [Color] = [
    fixed("#ef4444"), fixed("#f97316"), fixed("#eab308"),
    fixed("#22c55e"), fixed("#06b6d4"), fixed("#3b82f6"),
    fixed("#8b5cf6"),
  ]

  /// Heptagonal disc placement (unit square), shared with `AppIconPreview`
  /// so the emblem and the home-screen icon stay one mark.
  static let discCenters: [CGPoint] = [
    CGPoint(x: 0.50, y: 0.2235), CGPoint(x: 0.7171, y: 0.3256),
    CGPoint(x: 0.7709, y: 0.5631), CGPoint(x: 0.6206, y: 0.7505),
    CGPoint(x: 0.3794, y: 0.7505), CGPoint(x: 0.2291, y: 0.5631),
    CGPoint(x: 0.2829, y: 0.3256),
  ]

  /// Why support — what the money actually does. Note none of these is a
  /// feature you unlock: they're reasons the app can stay the way it is.
  static let reasons: [SeptenaPlusFeature] = [
    .init(id: "free",
          icon: "gift",
          title: "Keeps every feature free",
          detail: "Nothing here is held back for a paid tier. Your support is the reason there's no paywall — and the promise there never will be one."),
    .init(id: "independent",
          icon: "leaf",
          title: "Keeps it independent",
          detail: "No ads, no investors, no data sold. Septena answers to the people who use it, and that only works if some of them chip in."),
    .init(id: "next",
          icon: "hammer",
          title: "Funds the next update",
          detail: "Every fix and new section is built by one developer. Supporting is the most direct way to say “keep going.”"),
  ]

  /// The cosmetic perks a supporter actually gets. Deliberately small — the
  /// point is to support the app, not to buy capability.
  static let perks: [SeptenaPlusFeature] = [
    .init(id: "badge",
          icon: "checkmark.seal",
          title: "A Supporter badge",
          detail: "A quiet mark on your profile and a foil ring on your avatar. Just for you — it changes nothing about what the app can do."),
    .init(id: "thanks",
          icon: "heart",
          title: "Our genuine thanks",
          detail: "You're keeping a private, independent app alive. That's the whole deal, and it matters more than any feature could."),
  ]

  /// Support tiers, annual first (the highlighted default). A supporter
  /// picks one; none unlocks more than any other — they're amounts, not
  /// plans. Lifetime is the one-time "Founding Supporter".
  static let tiers: [SupportTier] = [
    .init(id: "annual",   title: "Annual",
          price: "€77", cadence: "per year",
          note: "Two months free", highlighted: true),
    .init(id: "monthly",  title: "Monthly",
          price: "€7",  cadence: "per month",
          note: nil, highlighted: false),
    .init(id: "lifetime", title: "Founding Supporter",
          price: "€177", cadence: "one time",
          note: "Lifetime — for being here early", highlighted: false),
  ]
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
          celebrationStyle = .milestone(accent: SeptenaPlus.foil,
                                        headline: String(localized: "Thank you"),
                                        caption: String(localized: "YOU'RE A SUPPORTER"))
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

      Section {
        NavigationLink(value: SettingsView.SettingsDestination.communityProfile) {
          Label("Community Profile", systemImage: "person.text.rectangle")
        }
        NavigationLink(value: SettingsView.SettingsDestination.communityRoadmap) {
          Label("Roadmap", systemImage: "map")
        }
        NavigationLink(value: SettingsView.SettingsDestination.communityTestimonial) {
          Label("Testimonial", systemImage: "quote.bubble")
        }
      } header: {
        Text("Community")
      } footer: {
        Text("Your public handle, the roadmap board to suggest and upvote features, and a testimonial you can share about Septena.")
      }
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
      IgnitionView(accent: accent, streak: streak, trigger: trigger)
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

