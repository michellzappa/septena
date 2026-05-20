import SwiftUI
import SwiftData
import EventKit
import CloudKit

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
    if let v = ResponseCache.load(AppSettings.self, forKey: CacheKey.serverSettings) { serverSettings = v }
    if let v = ResponseCache.load([SeptenaClient.SectionConfig].self, forKey: CacheKey.sections) { sections = v }
    if let v = ResponseCache.load(CaffeineConfig.self, forKey: CacheKey.caffeine) { caffeine = v }
    if let v = ResponseCache.load(CannabisConfig.self, forKey: CacheKey.cannabis) { cannabis = v }
    if let v = ResponseCache.load(MacrosConfig.self, forKey: CacheKey.macros) { macros = v }
    if let v = ResponseCache.load([SessionTypeConfig].self, forKey: CacheKey.sessionTypes) { sessionTypes = v }
    if let v = ResponseCache.load([ChoreItem].self, forKey: CacheKey.chores) { chores = v }
  }

  func refresh(from client: SeptenaClient) async {
    serverLoading = true
    defer { serverLoading = false }
    async let s     = try? await client.settings()
    async let secs  = try? await client.sections()
    async let caf   = try? await client.caffeineConfig()
    async let cnb   = try? await client.cannabisConfig()
    async let macs  = try? await client.nutritionMacrosConfig()
    async let sess  = try? await client.sessionTypes()
    async let chrs  = try? await client.chores()
    let (sv, sc, cf, cn) = await (s, secs, caf, cnb)
    let (mc, st, ch) = await (macs, sess, chrs)
    // Only overwrite + cache the values where the network actually
    // returned something — failed fetches leave the (cache-primed)
    // values alone instead of wiping them to nil / empty.
    if let sv { serverSettings = sv; ResponseCache.save(sv, forKey: CacheKey.serverSettings) }
    if let sc { sections = sc; ResponseCache.save(sc, forKey: CacheKey.sections) }
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
  var body: some View {
    Form {
      Section {
        Text("App-wide settings will appear here.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Section detail
//
// One pane per section, addressed by stable key. Identity (icon, label,
// color, description) comes from the local `SectionManifest`; the server
// label/color override the defaults when present. Per-key content below
// uses cached catalog data from `SettingsStore` — caffeine beans,
// cannabis strains, etc. Sections without catalog data show identity
// only. Tasks is special-cased to host the local task prefs (badge,
// today, sort) that used to live in a top-level Tasks pane.

struct SectionDetailPane: View {
  @Environment(SettingsStore.self) private var store
  let sectionKey: String

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
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(accent)
          .frame(width: 28, height: 28)
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
      } footer: {
        Text("Grant access here, or manage permissions in iOS Settings → Privacy.")
      }
    }
    .formStyle(.grouped)
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

// MARK: - Sync

struct SyncSettingsPane: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(SettingsStore.self) private var store
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

      Section("Server URL") {
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
            Text("Sync Now")
          }
        }
        .disabled(isSyncing)
      } footer: {
        Text("No auth — Septena is reachable on the tailnet.")
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
        Button {
          Task { await runMigration() }
        } label: {
          HStack {
            if isMigrating { ProgressView().controlSize(.small) }
            Label("Re-sync to iCloud", systemImage: "icloud.and.arrow.up")
          }
        }
        // Block when iCloud isn't ready — pushing into CloudKit without
        // an account would either silently fail or create records under
        // a stale identity. Same gate the engine would hit anyway.
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
        Text("Export writes a JSON snapshot (tasks + areas + projects) to Application Support. Re-sync exports first, then re-uploads everything to CloudKit and verifies the count.")
      }
      #endif
    }
    .formStyle(.grouped)
    .onAppear { serverURL = nav.serverURL }
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
  private func runResetZone() async {
    isMigrating = true
    defer { isMigrating = false }
    migrationStatus = "Resetting CloudKit zone…"
    do {
      try await ckEngine.resetZone()
      // Wipe any system-fields blobs on local entities — they referred
      // to records in the zone we just deleted. Next migrate will
      // recapture fresh tags via applyFetchedRecord. Covers tasks,
      // areas, and projects (all three now live in CloudKit).
      let tasks = (try? modelContext.fetch(FetchDescriptor<TaskEntity>())) ?? []
      let areas = (try? modelContext.fetch(FetchDescriptor<AreaEntity>())) ?? []
      let projects = (try? modelContext.fetch(FetchDescriptor<ProjectEntity>())) ?? []
      for row in tasks { row.cloudKitSystemFields = nil }
      for row in areas { row.cloudKitSystemFields = nil }
      for row in projects { row.cloudKitSystemFields = nil }
      try? modelContext.save()
      let total = tasks.count + areas.count + projects.count
      migrationStatus = "✅ Zone reset (\(total) entities cleared). Now run Migrate to push local state fresh."
    } catch {
      migrationStatus = "❌ Zone reset failed: \(error.localizedDescription)"
    }
  }

  @MainActor
  private func runMigration() async {
    isMigrating = true
    defer { isMigrating = false }
    migrationStatus = "Re-syncing…"
    // Pass the client so the migrator can hydrate FastAPI areas/projects
    // into the local mirror before pushing — without this, a fresh
    // install with no Syncer pull yet would push zero areas/projects to
    // CloudKit, then have task.area / task.project links pointing at
    // records that don't exist.
    let migrator = TasksMigrator(context: modelContext, engine: ckEngine, client: client)
    do {
      let result = try await migrator.migrateToCloudKit()
      migrationStatus = "✅ Re-sync complete: \(result.tasksCount) tasks, \(result.areasCount) areas, \(result.projectsCount) projects. Snapshot: \(result.snapshotURL.lastPathComponent)."
    } catch {
      migrationStatus = "❌ \(error.localizedDescription)"
    }
  }

  /// Forces a CK fetch, then prints a per-row report of why each task
  /// is or isn't inbox-eligible. Run on both devices and diff the
  /// outputs to find the 2 rows that disagree.
  @MainActor
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
