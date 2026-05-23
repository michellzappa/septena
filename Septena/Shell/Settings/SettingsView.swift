import SwiftUI
import SwiftData
import EventKit
import CloudKit
#if canImport(UIKit)
import UIKit
#endif

// Settings — the single unified surface for everything user-configurable.
// One sheet, one store, one entry point (sidebar row + ⌘,).
//
// Layout (Apple-style: app-wide rows on top, per-section rows below):
//   • General         — app-wide settings (currently empty, for future use)
//   • Integrations    — Reminders / Calendar / HealthKit permissions
//   • Sync            — server URL + manual sync
//   • Privacy         — analytics consent
//   • About           — version / links
//   ── Sections ────────────────────────────
//   • Tasks           — badge, today toggle, task sort + identity
//   • Training, Nutrition, Sleep, Habits, Cannabis, Caffeine, …
//                     — identity + (where applicable) catalog data
//
// Per-section rows are driven by `SectionManifest.all` filtered against
// the server's `/api/sections` response (an "enabled" set today; will be
// a CloudKit-backed per-account set in the future). Each row pushes to
// `SectionDetailPane(key:)` which composes identity + section-specific
// content.

// MARK: - Default keys

enum SettingsKey {
  static let badgeShowOverdue = "septena.badge.showOverdue"
  static let todayShowCompleted = "septena.today.showCompleted"
  static let syncLastSucceeded = "septena.sync.lastSucceededAt"
  /// Consent toggle for anonymous aggregate usage analytics (Plausible).
  /// Same key string is referenced by `PlausibleClient.consentKey` so the
  /// guard inside the actor and the @AppStorage binding stay in sync.
  static let shareUsageData   = "septena.privacy.shareUsageData"
  /// Global sort applied to task lists inside a project or area. Stored as
  /// the raw value of `TaskSort`. Lives in UserDefaults rather than per-list
  /// state — there's no per-project manual order in this app, so one global
  /// choice is the whole sort surface.
  static let taskSort         = "septena.task.sort"
}

enum AppIconOption: String, CaseIterable, Identifiable {
  case `default` = "AppIcon"
  case red       = "AppIconRed"
  case orange    = "AppIconOrange"
  case yellow    = "AppIconYellow"
  case green     = "AppIconGreen"
  case cyan      = "AppIconCyan"
  case blue      = "AppIconBlue"
  case purple    = "AppIconPurple"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .default: return "Default"
    case .red:     return "Red"
    case .orange:  return "Orange"
    case .yellow:  return "Yellow"
    case .green:   return "Green"
    case .cyan:    return "Cyan"
    case .blue:    return "Blue"
    case .purple:  return "Purple"
    }
  }

  var alternateIconName: String? {
    self == .default ? nil : rawValue
  }

  var background: Color {
    background(forDarkMode: false)
  }

  func background(forDarkMode isDarkMode: Bool) -> Color {
    if isDarkMode {
      return .clear
    }
    switch self {
    case .default: return .white
    case .red:     return parseHexColor("#ef4444")
    case .orange:  return parseHexColor("#f97316")
    case .yellow:  return parseHexColor("#eab308")
    case .green:   return parseHexColor("#22c55e")
    case .cyan:    return parseHexColor("#06b6d4")
    case .blue:    return parseHexColor("#3b82f6")
    case .purple:  return parseHexColor("#8b5cf6")
    }
  }

  var dotColors: [Color] {
    dotColors(forDarkMode: false)
  }

  func dotColors(forDarkMode isDarkMode: Bool) -> [Color] {
    if isDarkMode {
      switch self {
      case .default:
        return [
          parseHexColor("#ef4444"),
          parseHexColor("#f97316"),
          parseHexColor("#eab308"),
          parseHexColor("#22c55e"),
          parseHexColor("#06b6d4"),
          parseHexColor("#3b82f6"),
          parseHexColor("#8b5cf6"),
        ]
      case .red:
        return Array(repeating: parseHexColor("#ef4444"), count: 7)
      case .orange:
        return Array(repeating: parseHexColor("#f97316"), count: 7)
      case .yellow:
        return Array(repeating: parseHexColor("#eab308"), count: 7)
      case .green:
        return Array(repeating: parseHexColor("#22c55e"), count: 7)
      case .cyan:
        return Array(repeating: parseHexColor("#06b6d4"), count: 7)
      case .blue:
        return Array(repeating: parseHexColor("#3b82f6"), count: 7)
      case .purple:
        return Array(repeating: parseHexColor("#8b5cf6"), count: 7)
      }
    }
    switch self {
    case .default:
      return [
        parseHexColor("#ef4444"),
        parseHexColor("#f97316"),
        parseHexColor("#eab308"),
        parseHexColor("#22c55e"),
        parseHexColor("#06b6d4"),
        parseHexColor("#3b82f6"),
        parseHexColor("#8b5cf6"),
      ]
    default:
      return Array(repeating: .white, count: 7)
    }
  }

  #if os(iOS)
  static var current: AppIconOption {
    guard let name = UIApplication.shared.alternateIconName else { return .default }
    return AppIconOption(rawValue: name) ?? .default
  }
  #endif
}

/// Sort modes for tasks within a project or area detail view. Areas and
/// projects in the sidebar have manual drag-reorder, but tasks inside them
/// do not — so these two derived orderings are the entire sort surface.
enum TaskSort: String, CaseIterable, Identifiable {
  case dateAdded
  case alphabetical
  case dueDate
  var id: String { rawValue }
  var label: String {
    switch self {
    case .dateAdded:    return "Sort by Date Added"
    case .alphabetical: return "Sort by Name"
    case .dueDate:      return "Sort by Due Date"
    }
  }
  var icon: String {
    switch self {
    case .dateAdded:    return "clock"
    case .alphabetical: return "textformat"
    case .dueDate:      return "calendar"
    }
  }
}

// MARK: - Store
//
// One Observable holding the cached /api/settings response. Local prefs
// continue to live as @AppStorage at use sites — they're already shared
// through the SettingsKey constants and don't need wrapping.

@MainActor
@Observable
final class SettingsStore {
  var serverSettings: AppSettings? = nil
  var sections: [SeptenaClient.SectionConfig] = []
  var caffeine: CaffeineConfig? = nil
  var cannabis: CannabisConfig? = nil
  var macros: MacrosConfig? = nil
  var sessionTypes: [SessionTypeConfig] = []
  var chores: [ChoreItem] = []
  var serverLoading: Bool = false

  private enum CacheKey {
    static let serverSettings = "settings.serverSettings"
    static let sections       = "settings.sections"
    static let caffeine       = "settings.caffeine"
    static let cannabis       = "settings.cannabis"
    static let macros         = "settings.macros"
    static let sessionTypes   = "settings.sessionTypes"
    static let chores         = "settings.chores"
  }

  /// Synchronous read from disk-cached responses. Run at app launch
  /// before `refresh()` so the dashboard's tile order (driven by
  /// `sections`) and the section-config sub-panes render with last-known
  /// data instead of empty / default state during the network round-trip.
  func paintFromCache() {
    let context = LocalStore.shared.container.mainContext
    if let v = SettingsMirror.loadSettings(context: context) {
      serverSettings = v
    } else if let v = ResponseCache.load(AppSettings.self, forKey: CacheKey.serverSettings) {
      serverSettings = v
    }
    let mirroredSections = SettingsMirror.loadSections(context: context)
    if !mirroredSections.isEmpty {
      sections = mirroredSections
    } else if let v = ResponseCache.load([SeptenaClient.SectionConfig].self, forKey: CacheKey.sections) {
      sections = v
    }
    if let v = ResponseCache.load(CaffeineConfig.self, forKey: CacheKey.caffeine) { caffeine = v }
    if let v = ResponseCache.load(CannabisConfig.self, forKey: CacheKey.cannabis) { cannabis = v }
    if let v = ResponseCache.load(MacrosConfig.self, forKey: CacheKey.macros) { macros = v }
    if let v = ResponseCache.load([SessionTypeConfig].self, forKey: CacheKey.sessionTypes) { sessionTypes = v }
    if let v = ResponseCache.load([ChoreItem].self, forKey: CacheKey.chores) { chores = v }
  }

  func refresh(from client: SeptenaClient) async {
    serverLoading = true
    defer { serverLoading = false }
    let context = LocalStore.shared.container.mainContext
    let mirroredSettings = SettingsMirror.loadSettings(context: context)
    let mirroredSections = SettingsMirror.loadSections(context: context)

    if let mirroredSettings {
      serverSettings = mirroredSettings
      ResponseCache.save(mirroredSettings, forKey: CacheKey.serverSettings)
    }
    if !mirroredSections.isEmpty {
      sections = mirroredSections
      ResponseCache.save(mirroredSections, forKey: CacheKey.sections)
    }

    let needsLegacySettings = mirroredSettings == nil
    let needsLegacySections = mirroredSections.isEmpty

    async let macs  = try? await client.nutritionMacrosConfig()
    // Training session-types live in CloudKit — local mirror, no network.
    let st: [SessionTypeConfig]? = ChecklistMirror.loadSessionTypes(context: context)
    // Chores/caffeine/cannabis are CloudKit-authoritative — pull from the
    // local mirror, not FastAPI.
    let ch: [ChoreItem]? = ChecklistMirror.loadChores(context: context)
    let cf: CaffeineConfig? = {
      let beans = ChecklistMirror.loadCaffeineBeans(context: context)
      return CaffeineConfig(beans: beans)
    }()
    let cn: CannabisConfig? = {
      let strains = ChecklistMirror.loadCannabisStrains(context: context)
      return CannabisConfig(strains: strains, usesPerCapsule: 3)
    }()
    let mc = await macs
    // Only overwrite + cache the values where the network actually
    // returned something — failed fetches leave the (cache-primed)
    // values alone instead of wiping them to nil / empty.
    if needsLegacySettings, let sv = try? await client.settings() {
      serverSettings = sv
      ResponseCache.save(sv, forKey: CacheKey.serverSettings)
      SettingsMirror.upsert(settings: sv, context: context,
                            engine: SeptenaServices.shared.ckEngine)
    }
    if needsLegacySections, let sc = try? await client.sections() {
      sections = sc
      ResponseCache.save(sc, forKey: CacheKey.sections)
      SettingsMirror.replaceSections(sc, context: context,
                                     engine: SeptenaServices.shared.ckEngine)
    }
    if let cf { caffeine = cf; ResponseCache.save(cf, forKey: CacheKey.caffeine) }
    if let cn { cannabis = cn; ResponseCache.save(cn, forKey: CacheKey.cannabis) }
    if let mc { macros = mc; ResponseCache.save(mc, forKey: CacheKey.macros) }
    if let st { sessionTypes = st; ResponseCache.save(st, forKey: CacheKey.sessionTypes) }
    if let ch { chores = ch; ResponseCache.save(ch, forKey: CacheKey.chores) }
  }
}

// MARK: - Sheet root

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(SettingsStore.self) private var store
  @State private var selection: SettingsDestination? = .general
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail

  /// Sidebar entries. Static cases for app-wide settings; `section(key)`
  /// for per-section rows resolved against `SectionManifest` + the live
  /// `store.sections` list.
  enum SettingsDestination: Hashable {
    case general, integrations, sync, privacy, about
    case section(String)
  }

  var body: some View {
    #if os(iOS)
    NavigationStack {
      sidebarList
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsDestination.self) { dest in
          pane(for: dest)
            .navigationTitle(title(for: dest))
            .navigationBarTitleDisplayMode(.inline)
        }
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
    #else
    NavigationSplitView(columnVisibility: $columnVisibility,
                        preferredCompactColumn: $preferredCompactColumn) {
      sidebarList(selection: $selection)
        .navigationTitle("Settings")
    } detail: {
      NavigationStack {
        let dest = selection ?? .general
        pane(for: dest)
          .navigationTitle(title(for: dest))
      }
    }
    .frame(minWidth: 720, minHeight: 460)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
      }
    }
    #endif
  }

  #if os(iOS)
  @ViewBuilder
  private var sidebarList: some View {
    List {
      SwiftUI.Section {
        ForEach(staticDestinations, id: \.self) { dest in
          NavigationLink(value: dest) { staticRow(dest) }
        }
      }
      if !sectionEntries.isEmpty {
        SwiftUI.Section("Sections") {
          ForEach(sectionEntries) { entry in
            NavigationLink(value: SettingsDestination.section(entry.key)) {
              sectionRow(entry)
            }
          }
        }
      }
    }
  }
  #else
  @ViewBuilder
  private func sidebarList(selection: Binding<SettingsDestination?>) -> some View {
    List(selection: selection) {
      SwiftUI.Section {
        ForEach(staticDestinations, id: \.self) { dest in
          staticRow(dest).tag(dest)
        }
      }
      if !sectionEntries.isEmpty {
        SwiftUI.Section("Sections") {
          ForEach(sectionEntries) { entry in
            sectionRow(entry).tag(SettingsDestination.section(entry.key))
          }
        }
      }
    }
  }
  #endif

  private var staticDestinations: [SettingsDestination] {
    [.general, .integrations, .sync, .privacy, .about]
  }

  /// Per-section sidebar rows, in server order (`section_order` from
  /// `/api/settings`), filtered to sections present in both the local
  /// manifest and the live `store.sections` list. Server-only or
  /// manifest-only keys are dropped — visible only when both agree the
  /// section exists for this user.
  private var sectionEntries: [SectionEntry] {
    let serverByKey = Dictionary(uniqueKeysWithValues: store.sections.map { ($0.key, $0) })
    let order = store.serverSettings?.sectionOrder ?? store.sections.map(\.key)
    return order.compactMap { key in
      guard let manifest = SectionManifest.byKey[key],
            let server = serverByKey[key] else { return nil }
      return SectionEntry(manifest: manifest, server: server)
    }
  }

  private func staticRow(_ dest: SettingsDestination) -> some View {
    Label {
      Text(title(for: dest))
    } icon: {
      ColoredGlyph(icon: icon(for: dest), color: tint(for: dest), size: 22)
    }
  }

  private func sectionRow(_ entry: SectionEntry) -> some View {
    // No per-section icon vocabulary in the app yet — match the webapp
    // and use a plain color dot. Sized to align with the 22pt
    // ColoredGlyph slot used by the static rows above.
    Label {
      Text(entry.label)
    } icon: {
      Circle()
        .fill(entry.accent)
        .frame(width: 14, height: 14)
        .frame(width: 22, height: 22, alignment: .center)
    }
  }

  private func title(for dest: SettingsDestination) -> String {
    switch dest {
    case .general:      return "General"
    case .integrations: return "Integrations"
    case .sync:         return "Sync"
    case .privacy:      return "Privacy"
    case .about:        return "About"
    case .section(let key):
      return store.sections.first(where: { $0.key == key })?.label
        ?? SectionManifest.byKey[key]?.defaultLabel
        ?? key.capitalized
    }
  }

  // Icon + tint helpers are only used for the static rows on top —
  // section rows render their own color-dot label via `sectionRow`.
  private func icon(for dest: SettingsDestination) -> String {
    switch dest {
    case .general:      return "gearshape"
    case .integrations: return "app.connected.to.app.below.fill"
    case .sync:         return "arrow.triangle.2.circlepath"
    case .privacy:      return "hand.raised"
    case .about:        return "info.circle"
    case .section:      return ""  // unreachable; sectionRow handles section dests
    }
  }

  private func tint(for dest: SettingsDestination) -> Color {
    switch dest {
    case .general:      return .gray
    case .integrations: return .indigo
    case .sync:         return .blue
    case .privacy:      return .teal
    case .about:        return .purple
    case .section:      return .gray  // unreachable; see above
    }
  }

  @ViewBuilder
  private func pane(for dest: SettingsDestination) -> some View {
    switch dest {
    case .general:           GeneralSettingsPane()
    case .integrations:      IntegrationsSettingsPane()
    case .sync:              SyncSettingsPane()
    case .privacy:           PrivacySettingsPane()
    case .about:             AboutSettingsPane()
    case .section(let key):  SectionDetailPane(sectionKey: key)
    }
  }
}

/// Resolved sidebar row for a section — combines the static manifest
/// (icon, defaults) with the live server overrides (label, accent).
struct SectionEntry: Identifiable, Hashable {
  let manifest: SectionManifest
  let server: SeptenaClient.SectionConfig
  var id: String { manifest.key }
  var key: String { manifest.key }
  /// Server label wins; manifest default is the fallback when the server
  /// hasn't returned a label yet (cold launch before refresh).
  var label: String {
    server.label.isEmpty ? manifest.defaultLabel : server.label
  }
  /// Accent comes from the server (today) / CloudKit account (tomorrow).
  /// No catalog default — `parseHexColor` already returns neutral gray
  /// for empty / unparseable strings, which is the right fallback when
  /// the user hasn't picked a color yet.
  var accent: Color { parseHexColor(server.color) }
}

// MARK: - Privacy
//
// One toggle (anonymous Plausible screen-view analytics) plus a plain-
// language disclosure of exactly what is and isn't sent. The toggle is
// the same UserDefault key the actor reads, so flipping it takes effect
// on the next screen view — no app restart needed.

struct PrivacySettingsPane: View {
  @AppStorage(SettingsKey.shareUsageData) private var share: Bool = true

  var body: some View {
    Form {
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
        bullet("Anything you log — food, caffeine, cannabis, supplements, sleep, mood, notes. None of it leaves your device through analytics.")
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

// MARK: - General

struct GeneralSettingsPane: View {
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
              .font(.headline)
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
    } header: {
      Text("App Icon")
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
            .font(.system(size: 18, weight: .semibold))
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

private struct AppIconPreview: View {
  @Environment(\.colorScheme) private var colorScheme
  let option: AppIconOption
  let size: CGFloat

  private let discCenters: [CGPoint] = [
    CGPoint(x: 0.50, y: 0.2235),
    CGPoint(x: 0.7171, y: 0.3256),
    CGPoint(x: 0.7709, y: 0.5631),
    CGPoint(x: 0.6206, y: 0.7505),
    CGPoint(x: 0.3794, y: 0.7505),
    CGPoint(x: 0.2291, y: 0.5631),
    CGPoint(x: 0.2829, y: 0.3256),
  ]

  var body: some View {
    let isDarkMode = colorScheme == .dark
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.223, style: .continuous)
        .fill(option.background(forDarkMode: isDarkMode))
      ForEach(Array(discCenters.enumerated()), id: \.offset) { index, center in
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
#endif

// MARK: - Section detail
//
// One pane per section, addressed by stable key. Identity (icon, label,
// color, description) comes from the local `SectionManifest`; the server
// label/color override the defaults when present. Per-key content below
// uses cached catalog data from `SettingsStore` — caffeine beans,
// cannabis strains, etc. Sections without catalog data show identity
// only. Tasks is special-cased to host the local task prefs (badge,
// today, sort) that used to live in a top-level Tasks pane.

// MARK: - Palette

private struct PaletteSwatch: Identifiable {
  let id: String
  let label: String
  let hex: String
}

private let sectionPalette: [PaletteSwatch] = [
  // Bright row — Tailwind 500
  .init(id: "red",        label: "Red",        hex: "#ef4444"),
  .init(id: "orange",     label: "Orange",     hex: "#f97316"),
  .init(id: "amber",      label: "Amber",      hex: "#f59e0b"),
  .init(id: "yellow",     label: "Yellow",     hex: "#eab308"),
  .init(id: "lime",       label: "Lime",       hex: "#84cc16"),
  .init(id: "green",      label: "Green",      hex: "#22c55e"),
  .init(id: "emerald",    label: "Emerald",    hex: "#10b981"),
  .init(id: "teal",       label: "Teal",       hex: "#14b8a6"),
  .init(id: "cyan",       label: "Cyan",       hex: "#06b6d4"),
  .init(id: "sky",        label: "Sky",        hex: "#0ea5e9"),
  .init(id: "blue",       label: "Blue",       hex: "#3b82f6"),
  .init(id: "indigo",     label: "Indigo",     hex: "#6366f1"),
  .init(id: "violet",     label: "Violet",     hex: "#8b5cf6"),
  .init(id: "purple",     label: "Purple",     hex: "#a855f7"),
  .init(id: "pink",       label: "Pink",       hex: "#ec4899"),
  .init(id: "rose",       label: "Rose",       hex: "#f43f5e"),
  // Earth row — Tailwind 700/800 warm hues
  .init(id: "terracotta", label: "Terracotta", hex: "#9a3412"),
  .init(id: "brown",      label: "Brown",      hex: "#b45309"),
  .init(id: "mustard",    label: "Mustard",    hex: "#854d0e"),
  .init(id: "olive",      label: "Olive",      hex: "#3f6212"),
  .init(id: "taupe",      label: "Taupe",      hex: "#78716c"),
  .init(id: "espresso",   label: "Espresso",   hex: "#44403c"),
]

private struct PaletteSwatchGrid: View {
  let selectedHex: String
  let onSelect: (String) -> Void

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(sectionPalette) { swatch in
        let color = parseHexColor(swatch.hex)
        let isSelected = selectedHex.lowercased() == swatch.hex.lowercased()
        Button {
          onSelect(swatch.hex)
        } label: {
          Circle()
            .fill(color)
            .frame(width: 28, height: 28)
            .overlay(
              Circle()
                .strokeBorder(Color.primary.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                .padding(isSelected ? -3 : 0)
            )
            .overlay(
              Circle()
              #if canImport(UIKit)
                .strokeBorder(Color(UIColor.systemBackground), lineWidth: isSelected ? 2 : 0)
              #else
                .strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: isSelected ? 2 : 0)
              #endif
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.label)
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Section detail pane

struct SectionDetailPane: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  let sectionKey: String
  @State private var showingColorPicker = false

  /// Local task prefs — only read for `sectionKey == "tasks"`, but
  /// SwiftUI requires the property be declared at view-init so the
  /// `@AppStorage` binding wires up; the Tasks-specific section in
  /// `body` is the only place these are consumed.
  @AppStorage(SettingsKey.badgeShowOverdue)    private var taskBadge: Bool = false
  @AppStorage(SettingsKey.todayShowCompleted)  private var todayShowCompleted: Bool = true
  @AppStorage(SettingsKey.taskSort)            private var taskSortRaw: String = TaskSort.dateAdded.rawValue

  private var manifest: SectionManifest? { SectionManifest.byKey[sectionKey] }
  private var server: SeptenaClient.SectionConfig? {
    store.sections.first(where: { $0.key == sectionKey })
  }
  private var label: String {
    let serverLabel = server?.label ?? ""
    if !serverLabel.isEmpty { return serverLabel }
    return manifest?.defaultLabel ?? sectionKey.capitalized
  }
  private var accent: Color {
    parseHexColor(server?.color ?? "")
  }

  var body: some View {
    Form {
      identitySection
      sectionSpecific
      // No read-only footer here: per-section pages are mostly identity
      // today; the footer made sense when this pane lived inside Server.
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var identitySection: some View {
    Section {
      HStack(spacing: 12) {
        Button {
          showingColorPicker.toggle()
        } label: {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(accent)
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingColorPicker, arrowEdge: .leading) {
          PaletteSwatchGrid(selectedHex: server?.color ?? "") { hex in
            updateColor(hex)
            showingColorPicker = false
          }
          .padding(12)
          .presentationCompactAdaptation(.popover)
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(label).foregroundStyle(.primary)
          Text(sectionKey)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
    } footer: {
      if let m = manifest, !m.shortDescription.isEmpty {
        Text(m.shortDescription)
      }
    }
  }

  private func updateColor(_ hex: String) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == sectionKey }
    )
    guard let entity = try? modelContext.fetch(descriptor).first else { return }
    entity.color = hex
    entity.updatedAt = .now
    try? modelContext.save()
    ckEngine.noteSectionChange(id: sectionKey)
    store.sections = store.sections.map { config in
      config.key == sectionKey
        ? SeptenaClient.SectionConfig(key: config.key, label: config.label, color: hex)
        : config
    }
  }

  /// Per-key content. Tasks gets local prefs; the rest pull cached
  /// catalog data from `SettingsStore`. Unknown / un-cataloged keys
  /// fall through to identity-only.
  @ViewBuilder
  private var sectionSpecific: some View {
    switch sectionKey {
    case "tasks":       tasksConfig
    case "caffeine":    caffeineConfig
    case "cannabis":    cannabisConfig
    case "training":    trainingConfig
    case "chores":      choresConfig
    case "nutrition":   nutritionConfig
    default:            EmptyView()
    }
  }

  @ViewBuilder
  private var caffeineConfig: some View {
    if let caf = store.caffeine {
      if !caf.beans.isEmpty {
        Section("Beans") {
          ForEach(caf.beans) { bean in
            HStack {
              Text(bean.name)
              Spacer()
              Text(bean.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      if let methods = caf.methods, !methods.isEmpty {
        Section("Methods") {
          ForEach(methods, id: \.self) { Text($0) }
        }
      }
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private var cannabisConfig: some View {
    if let cnb = store.cannabis {
      if !cnb.strains.isEmpty {
        Section("Strains") {
          ForEach(cnb.strains) { st in
            HStack {
              Text(st.name)
              Spacer()
              Text(st.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      Section("Dosing") {
        row("Uses per capsule", "\(cnb.usesPerCapsule)")
      }
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private var trainingConfig: some View {
    if !store.sessionTypes.isEmpty {
      Section("Session types") {
        ForEach(store.sessionTypes) { t in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              if let e = t.emoji { Text(e) }
              Text(t.label).foregroundStyle(.primary)
              Spacer()
              Text(t.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            if !t.exercises.isEmpty {
              Text(t.exercises.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 2)
        }
      }
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private var choresConfig: some View {
    if !store.chores.isEmpty {
      Section("Definitions") {
        ForEach(store.chores) { c in
          HStack {
            if let e = c.emoji { Text(e) }
            Text(c.name).foregroundStyle(.primary)
            Spacer()
            if let due = c.dueDate {
              Text(due)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private var nutritionConfig: some View {
    if let m = store.macros {
      Section("Macro ranges") {
        row("Protein", "\(Int(m.protein.min))–\(Int(m.protein.max)) g")
        row("Fat",     "\(Int(m.fat.min))–\(Int(m.fat.max)) g")
        row("Carbs",   "\(Int(m.carbs.min))–\(Int(m.carbs.max)) g")
        row("Calories","\(Int(m.kcal.min))–\(Int(m.kcal.max)) kcal")
      }
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private var tasksConfig: some View {
    Section("Badge") {
      Toggle("Show overdue indicator on app icon", isOn: $taskBadge)
    }
    Section("Today") {
      Toggle("Show completed tasks in Today", isOn: $todayShowCompleted)
    }
    Section("Task sort") {
      Picker("Sort tasks by", selection: $taskSortRaw) {
        ForEach(TaskSort.allCases) { s in
          Label(s.label, systemImage: s.icon).tag(s.rawValue)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    }
    Section {
      Text("Areas and projects are managed in the Tasks tab.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

/// Tolerant parse of "#rrggbb" hex strings. Falls back to gray for
/// hsl(...) or other formats — the server returns either, but only the
/// hex form decodes natively. A future pass can add hsl() support.
private func parseHexColor(_ s: String) -> Color {
  var hex = s.trimmingCharacters(in: .whitespacesAndNewlines)
  if hex.hasPrefix("#") { hex.removeFirst() }
  guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return .gray }
  let r = Double((v >> 16) & 0xFF) / 255
  let g = Double((v >>  8) & 0xFF) / 255
  let b = Double( v        & 0xFF) / 255
  return Color(red: r, green: g, blue: b)
}

// MARK: - Integrations
//
// Native iOS access states for the three frameworks Septena reaches
// outside the FastAPI proxy: Reminders + Calendar (EventKit) and Apple
// Health (HealthKit). The Reminders row pushes to a detail screen
// with source-list picker + auto-import controls when access is granted;
// Calendar and Health are state-only rows (no per-integration config yet).

struct IntegrationsSettingsPane: View {
  @State private var remindersBridge = RemindersBridge.shared
  @State private var calendarBridge = CalendarBridge.shared
  @State private var healthBridge = HealthKitBridge.shared
  @Environment(AranetBridge.self) private var aranetBridge

  var body: some View {
    Form {
      Section {
        NavigationLink {
          RemindersInboxDetail()
            .navigationTitle("Reminders")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Reminders",
                   systemImage: "checklist",
                   state: remindersAccessLabel,
                   isGranted: remindersBridge.access == .granted)
        }

        NavigationLink {
          CalendarDetail()
            .navigationTitle("Calendar")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Calendar",
                   systemImage: "calendar",
                   state: calendarAccessLabel,
                   isGranted: calendarBridge.access == .granted)
        }

        grantButton(
          title: "Apple Health",
          systemImage: "heart.text.square",
          state: healthAccessLabel,
          isGranted: healthBridge.access == .granted,
          canRequest: healthBridge.access == .notDetermined && healthBridge.isAvailable
        ) {
          Task { _ = await healthBridge.requestAccess() }
        }

        // Aranet4 CO2 sensor — replaces the legacy Mac-Mini-based polling
        // path. Detail pane has scan/forget controls + live status.
        NavigationLink {
          AranetIntegrationDetail()
            .navigationTitle("Aranet")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Aranet",
                   systemImage: "sensor",
                   state: aranetStateLabel,
                   isGranted: aranetBridge.state == .connected)
        }
      } footer: {
        Text("Grant access here, or manage permissions in iOS Settings → Privacy.")
      }
    }
    .formStyle(.grouped)
  }

  private var aranetStateLabel: String {
    switch aranetBridge.state {
    case .connected:    return "Connected"
    case .connecting:   return "Connecting"
    case .scanning:     return "Scanning"
    case .disconnected: return "Disconnected"
    case .bluetoothOff: return "Bluetooth off"
    case .unauthorized: return "Denied"
    case .idle:         return "Not connected"
    }
  }

  private func stateRow(title: String,
                        systemImage: String,
                        state: String,
                        isGranted: Bool) -> some View {
    HStack {
      Label(title, systemImage: systemImage)
        .foregroundStyle(.primary)
      Spacer()
      Text(state)
        .font(.subheadline)
        .foregroundStyle(isGranted ? Color.green : .secondary)
    }
  }

  @ViewBuilder
  private func grantButton(title: String,
                           systemImage: String,
                           state: String,
                           isGranted: Bool,
                           canRequest: Bool,
                           onTap: @escaping () -> Void) -> some View {
    if canRequest {
      Button(action: onTap) {
        stateRow(title: title, systemImage: systemImage, state: state, isGranted: isGranted)
      }
      .buttonStyle(.plain)
    } else {
      stateRow(title: title, systemImage: systemImage, state: state, isGranted: isGranted)
    }
  }

  private var remindersAccessLabel: String {
    switch remindersBridge.access {
    case .granted:       return "Granted"
    case .writeOnly:     return "Write-only"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
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
}

// MARK: - Reminders → Inbox detail
//
// Reached from Integrations → Reminders. Permission grant + source list
// + auto-import all live here, since this is where the user actually
// configures the Reminders → Septena Inbox bridge.

private struct RemindersInboxDetail: View {
  @State private var bridge = RemindersBridge.shared
  @State private var access: RemindersBridge.Access = .notDetermined
  @State private var lists: [EKCalendar] = []
  @State private var selectedID: String?

  var body: some View {
    Form {
      Section {
        Text("Pick a Reminders list. Its pending items show in your Inbox; tap to import (originals are removed from Reminders).")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      switch access {
      case .notDetermined:
        Section {
          Button("Grant Access to Reminders") {
            Task {
              _ = await bridge.requestAccess()
              refresh()
            }
          }
        }
      case .denied, .writeOnly:
        Section {
          Text(access == .writeOnly
               ? "Septena has write-only access. Enable Full Access in Settings → Privacy → Reminders."
               : "Reminders access is denied. Enable it in Settings → Privacy → Reminders.")
            .font(.callout)
        }
      case .granted:
        Section("Source list") {
          pickerRow(title: "None", tint: nil, id: nil)
          ForEach(lists, id: \.calendarIdentifier) { cal in
            pickerRow(title: cal.title,
                      tint: Color(cgColor: cal.cgColor),
                      id: cal.calendarIdentifier)
          }
        }

        Section {
          Toggle("Auto-import new reminders", isOn: Binding(
            get: { bridge.autoImport },
            set: { bridge.autoImport = $0 }
          ))
          .disabled(bridge.sourceListID == nil)
        } footer: {
          Text("When on, pending items in the source list import automatically and are removed from Reminders. Runs on app launch and whenever Reminders changes.")
        }

        if !bridge.recentImports.isEmpty {
          Section("Recent auto-imports") {
            ForEach(bridge.recentImports.prefix(10)) { entry in
              autoImportRow(entry)
            }
            Button("Clear log", role: .destructive) {
              bridge.recentImports = []
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
  }

  @ViewBuilder
  private func autoImportRow(_ entry: AutoImportLogEntry) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(entry.succeeded ? Color.green : Color.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .foregroundStyle(.primary)
          .lineLimit(2)
        HStack(spacing: 6) {
          Text(relativeDate(entry.importedAt))
            .font(.caption)
            .foregroundStyle(.secondary)
          if let err = entry.error {
            Text("· \(err)")
              .font(.caption)
              .foregroundStyle(.orange)
              .lineLimit(1)
          }
        }
      }
      Spacer()
    }
  }

  private func relativeDate(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
  }

  @ViewBuilder
  private func pickerRow(title: String, tint: Color?, id: String?) -> some View {
    Button {
      bridge.sourceListID = id
      selectedID = id
    } label: {
      HStack(spacing: 10) {
        if let tint {
          Circle().fill(tint).frame(width: 10, height: 10)
        } else {
          Circle().stroke(.secondary, lineWidth: 1).frame(width: 10, height: 10)
        }
        Text(title).foregroundStyle(.primary)
        Spacer()
        if selectedID == id {
          Image(systemName: "checkmark")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tint)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func refresh() {
    access = bridge.access
    if access == .granted {
      lists = bridge.reminderLists()
      selectedID = bridge.sourceListID
    }
  }
}

// MARK: - Calendar detail
//
// Reached from Integrations → Calendar. Lists every event calendar EventKit
// exposes and lets the user toggle visibility per source. Hidden calendars
// drop out of CalendarBridge's fetch helpers, so both the day timeline and
// the Next page stop showing those events.

private struct CalendarDetail: View {
  @State private var bridge = CalendarBridge.shared
  @State private var access: CalendarBridge.Access = .notDetermined
  @State private var calendars: [EKCalendar] = []

  var body: some View {
    Form {
      Section {
        Text("Pick which calendars contribute events to your day timeline and Next page. Hidden calendars stay untouched in iOS Calendar.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      switch access {
      case .notDetermined:
        Section {
          Button("Grant Access to Calendar") {
            Task {
              _ = await bridge.requestAccess()
              refresh()
            }
          }
        }
      case .denied, .writeOnly:
        Section {
          Text(access == .writeOnly
               ? "Septena has write-only access. Enable Full Access in Settings → Privacy → Calendars."
               : "Calendar access is denied. Enable it in Settings → Privacy → Calendars.")
            .font(.callout)
        }
      case .granted:
        if calendars.isEmpty {
          Section {
            Text("No calendars found.")
              .foregroundStyle(.secondary)
          }
        } else {
          Section("Calendars") {
            ForEach(calendars, id: \.calendarIdentifier) { cal in
              calendarRow(cal)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
  }

  private func calendarRow(_ cal: EKCalendar) -> some View {
    Toggle(isOn: Binding(
      get: { !bridge.isHidden(cal) },
      set: { bridge.setHidden(!$0, for: cal) }
    )) {
      HStack(spacing: 10) {
        Circle()
          .fill(Color(cgColor: cal.cgColor))
          .frame(width: 10, height: 10)
        VStack(alignment: .leading, spacing: 2) {
          Text(cal.title)
            .foregroundStyle(.primary)
          if let source = cal.source?.title, !source.isEmpty {
            Text(source)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func refresh() {
    access = bridge.access
    if access == .granted {
      calendars = bridge.allCalendars()
    }
  }
}

// MARK: - Aranet detail
//
// Reached from Integrations → Aranet. Shows live connection state +
// latest reading, scan/forget controls, and a short explanation of the
// foreground-only model. The bridge handles all CoreBluetooth state;
// this view is purely a control + status surface.

private struct AranetIntegrationDetail: View {
  @Environment(AranetBridge.self) private var bridge

  var body: some View {
    Form {
      Section {
        statusRow
      } header: {
        Text("Status")
      } footer: {
        Text("Septena connects to your Aranet4 directly over Bluetooth while the app is open. Readings live on this device only — no backend involved.")
      }

      if let snap = bridge.latest {
        Section("Latest reading") {
          readingRow("CO2", "\(snap.co2Ppm) ppm")
          readingRow("Temperature", String(format: "%.1f °C", snap.tempC))
          readingRow("Humidity", "\(snap.humidityPct)%")
          readingRow("Pressure", String(format: "%.1f hPa", snap.pressureHPa))
          readingRow("Battery", "\(snap.batteryPct)%")
        }
      }

      Section {
        switch bridge.state {
        case .idle, .disconnected, .bluetoothOff, .unauthorized:
          Button {
            bridge.start()
          } label: {
            Label("Scan for Aranet", systemImage: "magnifyingglass")
          }
          .disabled(bridge.state == .bluetoothOff || bridge.state == .unauthorized)
        case .scanning, .connecting:
          HStack {
            ProgressView()
            Text(bridge.state == .scanning ? "Scanning…" : "Connecting…")
              .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { bridge.stop() }
          }
        case .connected:
          Button(role: .destructive) {
            bridge.stop()
          } label: {
            Label("Disconnect", systemImage: "stop.circle")
          }
        }

        // "Forget device" clears the stored peripheral identifier so the
        // next scan picks a different Aranet — useful if the user
        // swapped hardware. Always available; cheap operation.
        Button(role: .destructive) {
          bridge.forget()
        } label: {
          Label("Forget device", systemImage: "trash")
        }
      } footer: {
        if let err = bridge.lastError {
          Text(err).font(.caption).foregroundStyle(.orange)
        }
      }

      Section {
        Toggle("Background capture (experimental)", isOn: Binding(
          get: { bridge.backgroundCaptureEnabled },
          set: { newValue in
            bridge.backgroundCaptureEnabled = newValue
            // Bouncing the bridge picks up the new filter mode +
            // restore-identifier choice on the next scan.
            if bridge.state != .idle { bridge.stop() }
            if newValue { bridge.start() }
          }
        ))
      } header: {
        Text("Background")
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text("When on, Septena keeps listening for Aranet broadcasts while the app is suspended. Resolution drops from one reading per minute (foreground) to roughly one reading every 15–30 minutes (iOS throttles background BLE scans), but you get overnight coverage for sleep × air quality analysis.")
          Text("Works only if your Aranet4's ad packets include a service UUID. Open Console.app, filter on com.septena.cloud, and look for a `services=[…]` value on the discovery line — if that's empty, background capture won't deliver anything.")
            .foregroundStyle(.secondary)
        }
        .font(.caption)
      }
    }
    .formStyle(.grouped)
  }

  private var statusRow: some View {
    HStack(spacing: 10) {
      Circle().fill(statusColor).frame(width: 10, height: 10)
      VStack(alignment: .leading, spacing: 2) {
        Text(statusLabel).foregroundStyle(.primary)
        if let name = bridge.deviceName {
          Text(name).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
    }
  }

  private func readingRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label).foregroundStyle(.primary)
      Spacer()
      Text(value)
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  private var statusColor: Color {
    switch bridge.state {
    case .connected:    return .green
    case .connecting,
         .scanning:     return .yellow
    case .bluetoothOff,
         .unauthorized: return .red
    case .disconnected: return .orange
    case .idle:         return .secondary
    }
  }

  private var statusLabel: String {
    switch bridge.state {
    case .connected:    return "Connected"
    case .connecting:   return "Connecting…"
    case .scanning:     return "Scanning…"
    case .disconnected: return "Disconnected"
    case .bluetoothOff: return "Bluetooth is off"
    case .unauthorized: return "Bluetooth permission denied"
    case .idle:         return "Not connected"
    }
  }
}

// MARK: - Sync

private enum MigrationDomainState {
  case cloudKit
  case legacy
  /// HealthKit / EventKit-backed sections — never migrating to CloudKit,
  /// data already lives in the native iOS framework.
  case native

  var symbol: String {
    switch self {
    case .cloudKit: return "checkmark.circle.fill"
    case .legacy: return "server.rack"
    case .native: return "applelogo"
    }
  }

  var color: Color {
    switch self {
    case .cloudKit: return .green
    case .legacy: return .secondary
    case .native: return .purple
    }
  }
}

/// Snapshot of per-domain SwiftData row counts shown next to each Sync row.
/// `fetch` is a single pass over the model container — fine to call on view
/// appear and on `.septenaDataChanged`.
private struct DomainCounts {
  var tasks: Int = 0          // tasks + areas + projects
  var habits: Int = 0
  var supplements: Int = 0
  var chores: Int = 0
  var goals: Int = 0
  var sections: Int = 0       // sections + (1 for settings if present)
  var gut: Int = 0
  var caffeine: Int = 0
  var cannabis: Int = 0
  var groceries: Int = 0
  var training: Int = 0       // entries only — the user-meaningful number

  static let empty = DomainCounts()

  @MainActor
  static func fetch(context: ModelContext) -> DomainCounts {
    func count<T: PersistentModel>(_ type: T.Type) -> Int {
      (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
    }
    var c = DomainCounts()
    c.tasks       = count(TaskEntity.self) + count(AreaEntity.self) + count(ProjectEntity.self)
    c.habits      = count(HabitDefinitionEntity.self)
    c.supplements = count(SupplementDefinitionEntity.self)
    c.chores      = count(ChoreDefinitionEntity.self)
    c.goals       = count(GoalEntity.self)
    c.sections    = count(SectionEntity.self) + count(SettingsEntity.self)
    c.gut         = count(GutEventEntity.self)
    c.caffeine    = count(CaffeineEventEntity.self)
    c.cannabis    = count(CannabisEventEntity.self)
    c.groceries   = count(GroceryItemEntity.self)
    c.training    = count(ExerciseEntryEntity.self)
    return c
  }
}

private struct MigrationDomainRow: View {
  let name: String
  let detail: String
  let state: MigrationDomainState
  /// Local SwiftData entry count. `nil` for legacy/native sections that
  /// don't have a local mirror (FastAPI/HealthKit/EventKit).
  var count: Int? = nil

  var body: some View {
    HStack {
      Image(systemName: state.symbol)
        .foregroundStyle(state.color)
      Text(name)
      Spacer()
      if let count {
        Text("\(count)")
          .monospacedDigit()
          .foregroundStyle(.secondary)
        Text("·").foregroundStyle(.tertiary)
      }
      Text(detail)
        .foregroundStyle(.secondary)
    }
  }
}

struct SyncSettingsPane: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(SettingsStore.self) private var store
  @Environment(HTTPOutbox.self) private var httpOutbox
  @Environment(\.modelContext) private var modelContext

  @State private var serverURL: String = ""
  @State private var isChecking = false
  @State private var connectionStatus: String = ""
  @State private var isSyncing = false

  @AppStorage(SettingsKey.syncLastSucceeded) private var lastSyncedAt: Double = 0
  /// CloudKit engine, injected via environment from App.swift. Used
  /// only by the DEBUG migration buttons below.
  @Environment(CKEngine.self) private var ckEngine
  @State private var migrationStatus: String = ""
  @State private var isMigrating = false
  /// Multi-line report from "Diagnose Inbox" — pasted between devices to
  /// pinpoint where the two SwiftData mirrors disagree.
  @State private var inboxDiag: String = ""
  @State private var isDiagnosing = false
  /// Per-section local entry counts shown alongside each Sync row. Refreshed
  /// on appear and whenever data changes; useful for spotting bootstrap
  /// misses (e.g. Training showing 0 after a re-import).
  @State private var domainCounts: DomainCounts = .empty
  @State private var isInspecting = false
  @State private var inspectorReport: ServerInspectorReport?

  var body: some View {
    Form {
      Section {
        HStack {
          Image(systemName: client.isOffline ? "wifi.slash" : "checkmark.circle.fill")
            .foregroundStyle(client.isOffline ? Color.red : Color.green)
          Text(client.isOffline ? "Offline" : "Connected")
            .foregroundStyle(.primary)
          Spacer()
          if lastSyncedAt > 0 {
            Text("Last sync: \(lastSyncedDescription)")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }

      Section("Legacy FastAPI URL") {
        TextField("http://100.74.150.55:7000", text: $serverURL)
          #if os(iOS)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
          .autocorrectionDisabled()
          #endif
        Button {
          Task { await testConnection() }
        } label: {
          HStack {
            if isChecking { ProgressView().controlSize(.small) }
            Text("Test Connection")
          }
        }
        .disabled(isChecking || serverURL.isEmpty)
        if !connectionStatus.isEmpty {
          Text(connectionStatus)
            .font(.callout)
            .foregroundStyle(connectionStatus.hasPrefix("✅") ? .green : .red)
        }
        Button("Save") { save() }
          .disabled(serverURL.isEmpty || serverURL == nav.serverURL)
      }

      Section {
        Button {
          Task { await syncNow() }
        } label: {
          HStack {
            if isSyncing { ProgressView().controlSize(.small) }
            Text("Pull Legacy Cache")
          }
        }
        .disabled(isSyncing)
      } footer: {
        Text("FastAPI still serves unmigrated domains. Tasks, areas, and projects sync through CloudKit.")
      }

      #if DEBUG
      // iCloud account status + recovery tools. Tasks/areas/projects
      // are CloudKit-only as of the cutover — these controls help
      // recover when the local mirror or the CK zone gets out of sync.
      Section {
        HStack {
          Image(systemName: accountStatusIcon)
            .foregroundStyle(accountStatusColor)
          Text("iCloud: \(accountStatusLabel)")
          Spacer()
          Button("Refresh") {
            Task { await ckEngine.refreshAccountStatus() }
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
        }
      } header: {
        Text("iCloud")
      } footer: {
        Text("CloudKit writes go to the Development environment in debug builds; the schema auto-creates from your first save.")
      }

      Section("Migration Status") {
        LabeledContent("CloudKit pending writes",
                       value: String(ckEngine.pendingRecordZoneChangesCount))
        LabeledContent("Legacy HTTP pending writes",
                       value: String(httpOutbox.pendingCount))
        // Per-section breakdown of current backend. Order matches
        // SectionManifest.all (catalog order) so the list lines up with
        // the sidebar above. Tasks bundles areas + projects.
        MigrationDomainRow(name: "Tasks (+ areas, projects)", detail: "CloudKit", state: .cloudKit, count: domainCounts.tasks)
        MigrationDomainRow(name: "Habits",                    detail: "CloudKit", state: .cloudKit, count: domainCounts.habits)
        MigrationDomainRow(name: "Supplements",               detail: "CloudKit", state: .cloudKit, count: domainCounts.supplements)
        MigrationDomainRow(name: "Chores",                    detail: "CloudKit", state: .cloudKit, count: domainCounts.chores)
        MigrationDomainRow(name: "Goals",                     detail: "CloudKit", state: .cloudKit, count: domainCounts.goals)
        MigrationDomainRow(name: "Settings + Sections",       detail: "CloudKit", state: .cloudKit, count: domainCounts.sections)
        MigrationDomainRow(name: "Gut",                       detail: "CloudKit", state: .cloudKit, count: domainCounts.gut)
        MigrationDomainRow(name: "Caffeine",                  detail: "CloudKit", state: .cloudKit, count: domainCounts.caffeine)
        MigrationDomainRow(name: "Cannabis",                  detail: "CloudKit", state: .cloudKit, count: domainCounts.cannabis)
        MigrationDomainRow(name: "Groceries",                 detail: "CloudKit", state: .cloudKit, count: domainCounts.groceries)
        MigrationDomainRow(name: "Training",                  detail: "CloudKit", state: .cloudKit, count: domainCounts.training)
        MigrationDomainRow(name: "Nutrition",                 detail: "FastAPI",  state: .legacy)
        MigrationDomainRow(name: "Sleep",                     detail: "FastAPI",  state: .legacy)
        MigrationDomainRow(name: "Body",                      detail: "FastAPI",  state: .legacy)
        MigrationDomainRow(name: "Air",                       detail: "FastAPI",  state: .legacy)
        MigrationDomainRow(name: "Activity",                  detail: "HealthKit", state: .native)
        MigrationDomainRow(name: "Calendar",                  detail: "EventKit", state: .native)
      }

      // Recovery tooling. Export is non-destructive — safe to run any
      // time. Re-sync re-pushes every local task/area/project into
      // CloudKit and verifies the round-trip; useful after a zone reset.
      Section {
        Button {
          runExport()
        } label: {
          Label("Export Snapshot…", systemImage: "square.and.arrow.up")
        }
        .disabled(isMigrating)
        Button(role: .destructive) {
          Task { await runReplaceLocalMirror() }
        } label: {
          HStack {
            if isMigrating { ProgressView().controlSize(.small) }
            Label("Replace Local Mirror from iCloud", systemImage: "icloud.and.arrow.down")
          }
        }
        .disabled(isMigrating || ckEngine.accountStatus != .available)
        Button {
          Task { await runInboxDiagnostic() }
        } label: {
          HStack {
            if isDiagnosing { ProgressView().controlSize(.small) }
            Label("Diagnose Inbox", systemImage: "stethoscope")
          }
        }
        .disabled(isDiagnosing)
        Button {
          Task { await runInspectServer() }
        } label: {
          HStack {
            if isInspecting { ProgressView().controlSize(.small) }
            Label("Inspect Server", systemImage: "magnifyingglass")
          }
        }
        .disabled(isInspecting || ckEngine.accountStatus != .available)
        Button {
          Task { await runReimportChecklistHistory() }
        } label: {
          HStack {
            if isMigrating { ProgressView().controlSize(.small) }
            Label("Re-import All Sections from FastAPI", systemImage: "arrow.down.doc")
          }
        }
        .disabled(isMigrating || ckEngine.accountStatus != .available)
        Button(role: .destructive) {
          Task { await runPruneOldEvents() }
        } label: {
          Label("Prune Events Older Than 30 Days", systemImage: "calendar.badge.minus")
        }
        .disabled(isMigrating || ckEngine.accountStatus != .available)
        Button(role: .destructive) {
          Task { await runResetZone() }
        } label: {
          Label("Reset CloudKit Zone", systemImage: "trash")
        }
        .disabled(isMigrating || ckEngine.accountStatus != .available)
        if !migrationStatus.isEmpty {
          Text(migrationStatus)
            .font(.callout)
            .foregroundStyle(migrationStatus.hasPrefix("✅") ? .green : .red)
            .textSelection(.enabled)
        }
        if !inboxDiag.isEmpty {
          Text(inboxDiag)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } header: {
        Text("Recovery (dev)")
      } footer: {
        Text("Export writes a JSON snapshot of migrated data to Application Support. Replace Local Mirror snapshots this device, discards migrated local state, and pulls the current CloudKit zone.")
      }
      #endif
    }
    .formStyle(.grouped)
    .onAppear {
      serverURL = nav.serverURL
      refreshDomainCounts()
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      refreshDomainCounts()
    }
    #if DEBUG
    .sheet(item: $inspectorReport) { report in
      ServerInspectorSheet(report: report, onAction: handleInspectorAction)
    }
    #endif
  }

  private func refreshDomainCounts() {
    domainCounts = DomainCounts.fetch(context: modelContext)
  }

  private var lastSyncedDescription: String {
    let date = Date(timeIntervalSince1970: lastSyncedAt)
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
  }

  private func testConnection() async {
    isChecking = true
    connectionStatus = "Testing…"
    defer { isChecking = false }
    guard let url = URL(string: serverURL) else {
      connectionStatus = "❌ Invalid URL"; return
    }
    do {
      let testClient = SeptenaClient(baseURL: url)
      let result = try await testClient.ping()
      connectionStatus = "✅ \(result)"
    } catch {
      connectionStatus = "❌ \(error.localizedDescription)"
    }
  }

  private func save() {
    guard let url = URL(string: serverURL) else { return }
    nav.serverURL = serverURL
    ClientProvider.shared.update(baseURL: url)
    Task {
      await theme.refresh(from: ClientProvider.shared.client)
      await store.refresh(from: ClientProvider.shared.client)
    }
  }

  private func syncNow() async {
    isSyncing = true
    defer { isSyncing = false }
    let syncer = Syncer(client: client, context: modelContext)
    await syncer.pullAll()
  }

  #if DEBUG
  private var accountStatusLabel: String {
    switch ckEngine.accountStatus {
    case .available:             return "Signed in"
    case .noAccount:             return "Not signed in"
    case .restricted:            return "Restricted (parental / MDM)"
    case .temporarilyUnavailable: return "Temporarily unavailable"
    case .couldNotDetermine:     return "Status unknown"
    @unknown default:            return "Unknown"
    }
  }
  private var accountStatusIcon: String {
    switch ckEngine.accountStatus {
    case .available: return "checkmark.icloud.fill"
    case .noAccount, .restricted: return "xmark.icloud.fill"
    default: return "exclamationmark.icloud.fill"
    }
  }
  private var accountStatusColor: Color {
    switch ckEngine.accountStatus {
    case .available: return .green
    case .noAccount, .restricted: return .red
    default: return .orange
    }
  }

  private func runExport() {
    let migrator = TasksMigrator(context: modelContext, engine: ckEngine)
    do {
      let url = try migrator.exportToJSON(reason: "manual")
      migrationStatus = "✅ Exported to \(url.path)"
    } catch {
      migrationStatus = "❌ Export failed: \(error.localizedDescription)"
    }
  }

  /// Delete the entire `septena-v1` zone on CloudKit, then recreate it
  /// empty. Used when local entities lost their captured system fields
  /// (e.g. SwiftData was wiped after a migration) — without a clean
  /// slate every save into the existing records would 409. Also clears
  /// any stale system fields on local entities so the next migrate
  /// writes fresh.
  @MainActor
  /// Force-re-import habits/supplements/chores history from FastAPI and
  /// push it into CloudKit. The original bootstrap heuristic
  /// (`cloudKitSystemFields == nil` on local rows) breaks the moment the
  /// user toggles a single item — that one record gets CK-stamped and the
  /// bootstrap permanently no-ops, leaving years of history unimported.
  /// This button ignores the completion flags and re-pulls from FastAPI.
  private func runReimportChecklistHistory() async {
    isMigrating = true
    defer { isMigrating = false }
    migrationStatus = "Re-importing all sections from FastAPI…"
    let bootstrapper = ChecklistCloudKitBootstrapper(
      context: modelContext,
      engine: ckEngine,
      client: client
    )
    do {
      try await bootstrapper.forceBootstrap()
      migrationStatus = "✅ Re-imported all sections. The CloudKit push continues in the background — refresh a tile to see the data."
    } catch {
      migrationStatus = "❌ Re-import failed: \(error.localizedDescription)"
    }
  }

  @MainActor
  /// Delete habit/supplement/chore event rows older than 30 days from
  /// the local SwiftData mirror, then reset the CK zone and re-queue what
  /// remains. Used to drop the decade of FastAPI history the bootstrap
  /// pulled in but the user never actually generated on this device.
  private func runPruneOldEvents() async {
    isMigrating = true
    defer { isMigrating = false }
    migrationStatus = "Pruning events older than 30 days…"
    let calendar = Calendar.current
    let cutoffDate = calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    let cutoff = formatter.string(from: cutoffDate)

    let habitStates = (try? modelContext.fetch(FetchDescriptor<HabitDayStateEntity>(
      predicate: #Predicate { $0.date < cutoff }
    ))) ?? []
    let supStates = (try? modelContext.fetch(FetchDescriptor<SupplementDayStateEntity>(
      predicate: #Predicate { $0.date < cutoff }
    ))) ?? []
    let choreEvents = (try? modelContext.fetch(FetchDescriptor<ChoreEventEntity>(
      predicate: #Predicate { $0.date < cutoff }
    ))) ?? []

    let pruned = habitStates.count + supStates.count + choreEvents.count
    for row in habitStates { modelContext.delete(row) }
    for row in supStates { modelContext.delete(row) }
    for row in choreEvents { modelContext.delete(row) }
    try? modelContext.save()

    migrationStatus = "Pruned \(pruned) old events. Resetting CloudKit zone and re-queueing…"
    await runResetZone()
    if migrationStatus.hasPrefix("✅") {
      migrationStatus = "✅ Pruned \(pruned) old events (cutoff \(cutoff)). " + migrationStatus.dropFirst(2)
    }
  }

  private func runResetZone() async {
    isMigrating = true
    defer { isMigrating = false }
    migrationStatus = "Resetting CloudKit zone…"
    do {
      try await ckEngine.resetZone()
      // Wipe stale system-fields blobs on every CK-backed entity type —
      // they all referred to records in the zone we just deleted. Then
      // re-queue each one so the freshly-restarted engine pushes the
      // current local mirror to the empty zone.
      let tasks = (try? modelContext.fetch(FetchDescriptor<TaskEntity>())) ?? []
      let areas = (try? modelContext.fetch(FetchDescriptor<AreaEntity>())) ?? []
      let projects = (try? modelContext.fetch(FetchDescriptor<ProjectEntity>())) ?? []
      let settings = (try? modelContext.fetch(FetchDescriptor<SettingsEntity>())) ?? []
      let sections = (try? modelContext.fetch(FetchDescriptor<SectionEntity>())) ?? []
      let habitDefs = (try? modelContext.fetch(FetchDescriptor<HabitDefinitionEntity>())) ?? []
      let habitStates = (try? modelContext.fetch(FetchDescriptor<HabitDayStateEntity>())) ?? []
      let supDefs = (try? modelContext.fetch(FetchDescriptor<SupplementDefinitionEntity>())) ?? []
      let supStates = (try? modelContext.fetch(FetchDescriptor<SupplementDayStateEntity>())) ?? []
      let choreDefs = (try? modelContext.fetch(FetchDescriptor<ChoreDefinitionEntity>())) ?? []
      let choreEvents = (try? modelContext.fetch(FetchDescriptor<ChoreEventEntity>())) ?? []
      let goals = (try? modelContext.fetch(FetchDescriptor<GoalEntity>())) ?? []
      let gut = (try? modelContext.fetch(FetchDescriptor<GutEventEntity>())) ?? []
      let caffeine = (try? modelContext.fetch(FetchDescriptor<CaffeineEventEntity>())) ?? []
      let beans = (try? modelContext.fetch(FetchDescriptor<CaffeineBeanEntity>())) ?? []
      let cannabis = (try? modelContext.fetch(FetchDescriptor<CannabisEventEntity>())) ?? []
      let strains = (try? modelContext.fetch(FetchDescriptor<CannabisStrainEntity>())) ?? []
      let groceries = (try? modelContext.fetch(FetchDescriptor<GroceryItemEntity>())) ?? []
      let groceryCats = (try? modelContext.fetch(FetchDescriptor<GroceryCategoryEntity>())) ?? []
      let exEntries = (try? modelContext.fetch(FetchDescriptor<ExerciseEntryEntity>())) ?? []
      let exDefs = (try? modelContext.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? []
      let sessTypes = (try? modelContext.fetch(FetchDescriptor<SessionTypeEntity>())) ?? []
      for row in tasks { row.cloudKitSystemFields = nil }
      for row in areas { row.cloudKitSystemFields = nil }
      for row in projects { row.cloudKitSystemFields = nil }
      for row in settings { row.cloudKitSystemFields = nil }
      for row in sections { row.cloudKitSystemFields = nil }
      for row in habitDefs { row.cloudKitSystemFields = nil }
      for row in habitStates { row.cloudKitSystemFields = nil }
      for row in supDefs { row.cloudKitSystemFields = nil }
      for row in supStates { row.cloudKitSystemFields = nil }
      for row in choreDefs { row.cloudKitSystemFields = nil }
      for row in choreEvents { row.cloudKitSystemFields = nil }
      for row in goals { row.cloudKitSystemFields = nil }
      for row in gut { row.cloudKitSystemFields = nil }
      for row in caffeine { row.cloudKitSystemFields = nil }
      for row in beans { row.cloudKitSystemFields = nil }
      for row in cannabis { row.cloudKitSystemFields = nil }
      for row in strains { row.cloudKitSystemFields = nil }
      for row in groceries { row.cloudKitSystemFields = nil }
      for row in groceryCats { row.cloudKitSystemFields = nil }
      for row in exEntries { row.cloudKitSystemFields = nil }
      for row in exDefs { row.cloudKitSystemFields = nil }
      for row in sessTypes { row.cloudKitSystemFields = nil }
      try? modelContext.save()
      for row in tasks { ckEngine.noteTaskChange(id: row.id) }
      for row in areas { ckEngine.noteAreaChange(id: row.id) }
      for row in projects { ckEngine.noteProjectChange(id: row.id) }
      if !settings.isEmpty { ckEngine.noteSettingsChange() }
      for row in sections { ckEngine.noteSectionChange(id: row.id) }
      for row in habitDefs { ckEngine.noteHabitDefinitionChange(id: row.id) }
      for row in habitStates { ckEngine.noteHabitEventChange(id: row.id) }
      for row in supDefs { ckEngine.noteSupplementDefinitionChange(id: row.id) }
      for row in supStates { ckEngine.noteSupplementEventChange(id: row.id) }
      for row in choreDefs { ckEngine.noteChoreDefinitionChange(id: row.id) }
      for row in choreEvents { ckEngine.noteChoreEventChange(id: row.id) }
      for row in goals { ckEngine.noteGoalChange(id: row.id) }
      for row in gut { ckEngine.noteGutEventChange(id: row.id) }
      for row in caffeine { ckEngine.noteCaffeineEventChange(id: row.id) }
      for row in beans { ckEngine.noteCaffeineBeanChange(id: row.id) }
      for row in cannabis { ckEngine.noteCannabisEventChange(id: row.id) }
      for row in strains { ckEngine.noteCannabisStrainChange(id: row.id) }
      for row in groceries { ckEngine.noteGroceryItemChange(id: row.id) }
      for row in groceryCats { ckEngine.noteGroceryCategoryChange(id: row.id) }
      for row in exEntries { ckEngine.noteExerciseEntryChange(id: row.id) }
      for row in exDefs { ckEngine.noteExerciseDefinitionChange(id: row.id) }
      for row in sessTypes { ckEngine.noteSessionTypeChange(id: row.id) }
      let coreCount = tasks.count + areas.count + projects.count + settings.count + sections.count
      let checklistCount = habitDefs.count + habitStates.count + supDefs.count + supStates.count
        + choreDefs.count + choreEvents.count + goals.count
      let logCount = gut.count + caffeine.count + beans.count + cannabis.count + strains.count
      let groceryCount = groceries.count + groceryCats.count
      let trainingCount = exEntries.count + exDefs.count + sessTypes.count
      let total = coreCount + checklistCount + logCount + groceryCount + trainingCount
      migrationStatus = "✅ Zone reset and \(total) entities re-queued for upload."
    } catch {
      migrationStatus = "❌ Zone reset failed: \(error.localizedDescription)"
    }
  }

  @MainActor
  private func runReplaceLocalMirror() async {
    isMigrating = true
    defer { isMigrating = false }
    migrationStatus = "Replacing local mirror from CloudKit…"
    let migrator = TasksMigrator(context: modelContext, engine: ckEngine)
    do {
      let result = try await migrator.replaceLocalMirrorFromCloudKit()
      migrationStatus = "✅ Local mirror replaced. Removed local: \(result.deletedTasksCount) tasks, \(result.deletedAreasCount) areas, \(result.deletedProjectsCount) projects. Loaded from CloudKit: \(result.cloudTasksCount) tasks, \(result.cloudAreasCount) areas, \(result.cloudProjectsCount) projects. Snapshot: \(result.snapshotURL.lastPathComponent)."
    } catch {
      migrationStatus = "❌ Replace local mirror failed: \(error.localizedDescription)"
    }
  }

  /// Forces a CK fetch, then prints a per-row report of why each task
  /// is or isn't inbox-eligible. Run on both devices and diff the
  /// outputs to find the 2 rows that disagree.
  @MainActor
  private func handleInspectorAction(_ action: InspectorAction) async {
    let services = SeptenaServices.shared
    do {
      switch action {
      case .createArea(let id, let title):
        _ = try await services.areasMutator.createWithExplicitID(id: id, title: title)
        migrationStatus = "✅ Created Area id=\(id)"
      case .createProject(let id, let title, let area):
        _ = try await services.projectsMutator.createWithExplicitID(id: id, title: title, area: area)
        migrationStatus = "✅ Created Project id=\(id)"
      case .clearAreaFromTasks(let areaId):
        let descriptor = FetchDescriptor<TaskEntity>(
          predicate: #Predicate { $0.area == areaId }
        )
        let matches = (try? modelContext.fetch(descriptor)) ?? []
        var moved = 0
        for entity in matches {
          services.taskMutator.moveToArea(id: entity.id, area: nil)
          moved += 1
        }
        migrationStatus = "✅ Moved \(moved) task\(moved == 1 ? "" : "s") from area=\(areaId) to Inbox"
      }
      // Refresh the inspector report so the change is reflected.
      await runInspectServer()
    } catch {
      migrationStatus = "❌ \(error.localizedDescription)"
    }
  }

  private func runInspectServer() async {
    isInspecting = true
    defer { isInspecting = false }
    do {
      let records = try await ckEngine.fetchAllRecords(recordTypes: [
        TaskCloudKitSchema.recordType,
        AreaCloudKitSchema.recordType,
        ProjectCloudKitSchema.recordType,
      ])
      inspectorReport = ServerInspectorReport.build(from: records)
    } catch {
      migrationStatus = "❌ Inspect Server failed: \(error.localizedDescription)"
    }
  }

  private func runInboxDiagnostic() async {
    isDiagnosing = true
    defer { isDiagnosing = false }
    inboxDiag = "Diagnosing…"

    // 1. Pull the latest from CK first so the local mirror is as
    //    fresh as possible before we count. If CK is unreachable
    //    we still continue with whatever the mirror has.
    var fetchNote = ""
    do {
      try await ckEngine.fetchChanges()
      fetchNote = "fetchChanges OK"
    } catch {
      fetchNote = "fetchChanges FAILED: \(error.localizedDescription)"
    }

    // 2. Walk every TaskEntity once. Inbox criteria mirror
    //    LocalCache.tasks(filter: .inbox) exactly — keep them in lockstep.
    let rows = (try? modelContext.fetch(FetchDescriptor<TaskEntity>())) ?? []
    var inboxRows: [TaskEntity] = []
    var ghostRows: [TaskEntity] = []
    var missingCK = 0
    var excluded: [String: Int] = [:]
    for e in rows {
      if e.cloudKitSystemFields == nil { missingCK += 1 }
      if e.pendingDeletion {
        ghostRows.append(e)
        excluded["pendingDeletion", default: 0] += 1
        continue
      }
      if e.status != .open {
        excluded["status=\(e.statusRaw)", default: 0] += 1
        continue
      }
      if e.today {
        excluded["today=true", default: 0] += 1
        continue
      }
      if e.project != nil {
        excluded["hasProject", default: 0] += 1
        continue
      }
      if e.area != nil {
        excluded["hasArea", default: 0] += 1
        continue
      }
      if e.scheduled != nil {
        excluded["hasScheduled", default: 0] += 1
        continue
      }
      if e.due != nil {
        excluded["hasDue", default: 0] += 1
        continue
      }
      inboxRows.append(e)
    }

    // 3. iCloud identity — both devices must report the same userRecordID
    //    or they're hitting different private databases entirely.
    var userID = "unknown"
    if let id = try? await ckEngine.container.userRecordID() {
      userID = id.recordName
    }

    // 4. Pending engine state — non-zero means the engine has writes
    //    queued that haven't been sent yet (or fetches it hasn't applied).
    let pendingRecord = ckEngine.pendingRecordZoneChangesCount
    let pendingDatabase = ckEngine.pendingDatabaseChangesCount

    // 5. Build the report. Sort inbox rows by id for a stable diff
    //    between devices — sortIndex is local-only and may differ.
    let sortedInbox = inboxRows.sorted { $0.id < $1.id }
    let sortedGhosts = ghostRows.sorted { $0.id < $1.id }

    var lines: [String] = []
    lines.append("== Inbox Diagnostic ==")
    lines.append("device: \(deviceLabel())")
    lines.append("iCloudUser: \(userID)")
    lines.append("backend: cloudKit")
    lines.append("fetch: \(fetchNote)")
    lines.append("pending: record=\(pendingRecord) db=\(pendingDatabase)")
    lines.append("totals: tasks=\(rows.count) inbox=\(inboxRows.count) ghosts=\(ghostRows.count) missingCKFields=\(missingCK)")
    if !excluded.isEmpty {
      let pairs = excluded.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: " ")
      lines.append("excluded: \(pairs)")
    }
    lines.append("-- inbox ids --")
    for e in sortedInbox {
      let title = e.title.isEmpty ? "(untitled)" : e.title
      let ck = e.cloudKitSystemFields == nil ? " !noCK" : ""
      lines.append("• \(e.id)  \(title)\(ck)")
    }
    if !sortedGhosts.isEmpty {
      lines.append("-- pendingDeletion ghosts --")
      for e in sortedGhosts {
        let title = e.title.isEmpty ? "(untitled)" : e.title
        lines.append("• \(e.id)  \(title)")
      }
    }
    let report = lines.joined(separator: "\n")
    inboxDiag = report

    // Console echo so the user can grep across both devices.
    for line in lines {
      SeptenaLog.info("[InboxDiag] \(line)")
    }
  }

  private func deviceLabel() -> String {
    #if os(macOS)
    return "macOS"
    #elseif os(iOS)
    return "iOS"
    #else
    return "unknown"
    #endif
  }
  #endif
}

// MARK: - About

struct AboutSettingsPane: View {
  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
  }
  private var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
  }

  var body: some View {
    Form {
      Section {
        VStack(alignment: .center, spacing: 8) {
          ColoredGlyph(icon: "circle.grid.cross.fill", color: .blue, size: 56)
            .opacity(0.0) // placeholder slot; brand glyph below
          Text("Septena")
            .font(.title2.bold())
          Text("Version \(version) (\(build))")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .listRowBackground(Color.clear)
      }
      Section("Links") {
        Link("Source", destination: URL(string: "https://github.com/")!)
        Link("Feedback", destination: URL(string: "mailto:mz@envisioning.com")!)
        Link("License", destination: URL(string: "https://opensource.org/licenses/MIT")!)
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Shared pane helpers

private func row(_ label: String, _ value: String) -> some View {
  HStack {
    Text(label)
    Spacer()
    Text(value)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.trailing)
  }
}
