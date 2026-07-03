import SwiftUI
import SwiftData
import EventKit
import CloudKit
import CoreLocation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

// Settings — the single unified surface for everything user-configurable.
// One sheet, one store, one entry point (sidebar row + ⌘,).
//
// Layout (Apple-style: app-wide rows on top, per-section rows below):
//   • Customize       — app-wide preferences (homepage layout, icon, quick actions)
//   • Integrations    — Reminders / Calendar / HealthKit permissions
//   • Sync            — server URL + manual sync
//   • Privacy         — analytics consent
//   • About           — version / links
//   ── Sections ────────────────────────────
//   • Tasks           — badge, today toggle, task sort + identity
//   • Training, Nutrition, Sleep, Habits, Intake, …
//                     — identity + (where applicable) catalog data
//
// Per-section rows are driven by `SectionManifest.all` filtered against
// the user's installed `SectionEntity` set (CloudKit-mirrored via
// CKEngine). Each row pushes to `SectionDetailPane(key:)` which composes
// identity + section-specific content.

/// Where a homepage tap on the Tasks tile lands. `drawer` shows today's
/// tasks as a bottom-sheet (matches every other section); `tab` switches
/// the tab bar to the full Tasks surface.
enum TasksOpenMode: String, CaseIterable, Identifiable {
  case drawer, tab
  var id: String { rawValue }
  var label: String {
    switch self {
    case .drawer: return String(localized: "Drawer", comment: "Tasks-tile open mode")
    case .tab:    return String(localized: "Tasks tab", comment: "Tasks-tile open mode")
    }
  }
}

enum NutritionHeatmapMetric: String, CaseIterable, Identifiable {
  case protein, fasting
  var id: String { rawValue }
  var label: String { self == .protein ? String(localized: "Protein", comment: "Nutrition heatmap metric") : String(localized: "Fasting hours", comment: "Nutrition heatmap metric") }
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
    case .default: return String(localized: "Default", comment: "App icon color")
    case .red:     return String(localized: "Red", comment: "App icon color")
    case .orange:  return String(localized: "Orange", comment: "App icon color")
    case .yellow:  return String(localized: "Yellow", comment: "App icon color")
    case .green:   return String(localized: "Green", comment: "App icon color")
    case .cyan:    return String(localized: "Cyan", comment: "App icon color")
    case .blue:    return String(localized: "Blue", comment: "App icon color")
    case .purple:  return String(localized: "Purple", comment: "App icon color")
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

// SettingsStore moved to Shell/Settings/SettingsStore.swift (shared with Septask).


// MARK: - Sheet root

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  // `store` resolves section titles for the navigation bar; section reorder and
  // writes now live in the leaf panes (SectionsSettingsPane / SectionDetailPane),
  // so SettingsView no longer needs modelContext or the CK engine directly.
  @Environment(SettingsStore.self) private var store
  #if os(macOS)
  // Settings runs in its own (reused) window on macOS; this drives the
  // deep-link → pane sync in the macOS branch of `body`.
  @Environment(NavigationState.self) private var nav
  #endif
  @State private var selection: SettingsDestination?
  /// iPhone-only navigation path. Seeded from `initialDestination` so the
  /// sheet can open already pushed to a specific pane (e.g. a section's
  /// settings, deep-linked from its drawer) with a back-chevron to the
  /// settings list. Unused on macOS/iPad, which deep-link via `selection`.
  @State private var path: [SettingsDestination]
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail

  /// Open straight to a destination, or `nil` for the historical default
  /// (sidebar list on iPhone, `.general` detail on macOS/iPad). The
  /// "Customize <Section>" footer in `SectionDrawer` passes `.section(key)`.
  init(initialDestination: SettingsDestination? = nil) {
    _selection = State(initialValue: initialDestination ?? .sections)
    _path = State(initialValue: initialDestination.map { [$0] } ?? [])
  }

  /// Sidebar entries. Static cases for app-wide settings; `section(key)`
  /// for per-section rows resolved against `SectionManifest` + the live
  /// `store.sections` list.
  enum SettingsDestination: Hashable {
    case account
    // Root rows (Apple-style intent groups), in sidebar order.
    case sections        // collapsed per-section list (absorbs Manage Sections)
    case home            // homepage: layout, timeline, welcome, insights
    case notifications   // promoted to root
    case connectionsAI   // AI reach + Claude/MCP + app/service integrations
    case sharingData     // practitioner reports + import/export
    case privacy
    case feedback        // roadmap + community profile + testimonial
    case about
    case whatsNew        // release notes, reached from About
    case advanced        // dev + diagnostics, reached from About
    // Sub-panes reached from the hubs above.
    case general         // time of day, app icon, quick actions, animations
    case claudeAI        // unified AI reach + Claude gateway + local MCP + skills
    case connections     // Apple + service integrations (was Integrations)
    case data            // import / export (was Import & Export)
    case reports         // practitioner reports — scoped shareable section bundles
    case layout, correlations, timeOfDay
    case nextFeed        // Next list: suggestions, carry-over, per-section visibility
    case quickActions, appIcon
    case skills, localMcp, motionGallery, dataTools
    case support
    case communityProfile   // public username / display name / bio (community Worker)
    case communityRoadmap   // feature-request board (community Worker)
    case communityTestimonial // one-per-user testimonial (community Worker)
    case milestonePreview   // DEBUG bench: fire each milestone celebration
    case siriShortcuts
    case section(String)
  }

  var body: some View {
    #if os(iOS)
    // Presented as a drawer: a grab handle on top, swipe-down to dismiss, no
    // explicit close button (the user prefers the tab-on-top affordance over a
    // "Done" toolbar item). The drag indicator lives here so every call site
    // that presents SettingsView in a sheet gets it for free.
    NavigationStack(path: $path) {
      sidebarList
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsDestination.self) { dest in
          pane(for: dest)
            .navigationTitle(title(for: dest))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    .presentationDragIndicator(.visible)
    #else
    NavigationSplitView(columnVisibility: $columnVisibility,
                        preferredCompactColumn: $preferredCompactColumn) {
      sidebarList(selection: $selection)
        .navigationTitle("Settings")
        // The sidebar is always shown — Settings is a fixed-size window with
        // only seven root rows, so the collapse affordance just invited an
        // awkward detail-only state. Drop the toolbar toggle entirely.
        .toolbar(removing: .sidebarToggle)
        // ...and pin the column so the divider can't be dragged at all: the
        // window is a fixed 820×600, so a resizable/collapsible sidebar only
        // let the user throw the proportions off. min == ideal == max leaves
        // the divider no range to drag, which also blocks the fold-away.
        .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
    } detail: {
      NavigationStack {
        let dest = selection ?? .sections
        pane(for: dest)
          .navigationTitle(title(for: dest))
          // The hub panes (Home, Sections, Connections & AI, …) push their
          // sub-panes via `NavigationLink(value:)`; the detail column needs
          // its own resolver for those to open (the sidebar only drives the
          // root `selection`).
          .navigationDestination(for: SettingsDestination.self) { sub in
            pane(for: sub)
              .navigationTitle(title(for: sub))
          }
      }
    }
    // Fixed sheet size on macOS. With only minimums the sheet grew and
    // shrank to fit each pane's intrinsic content height, so navigating
    // between a short pane (Privacy) and a tall one (App Icon grid) made
    // the whole window jump. A stable frame lets the Form/List scroll
    // internally instead — matching the fixed-frame QuickFind / AddInfo
    // sheets.
    .frame(width: 820, height: 600)
    // No "Done" button on macOS: Settings is its own window (see App.swift),
    // so the split view fills the whole frame and the window's traffic
    // lights close it. Escape closes it too. A `.toolbar` confirmationAction
    // would instead render a detached button band below the split view,
    // rounding the columns off above it and leaving a dead gap.
    .onExitCommand { dismiss() }
    // The window is reused across opens, so seed the pane from the contextual
    // deep-link target ("Customize <Section>", the Insights gear) and clear
    // it when the window closes so the next plain open lands on the root.
    .onChange(of: nav.settingsDestination) { _, dest in
      if let dest { selection = dest }
    }
    .onDisappear { nav.settingsDestination = nil }
    #endif
  }

  // The root sidebar is a short, fixed list of intent groups (Apple's iOS-18
  // model). Per-section rows and intake trackers no longer live here — they
  // moved one level down into the Sections pane (and, for trackers, the Intake
  // section's own detail), so the root stays scannable regardless of how many
  // sections the user has enabled.
  #if os(iOS)
  @ViewBuilder
  private var sidebarList: some View {
    List {
      SwiftUI.Section {
        NavigationLink(value: SettingsDestination.account) {
          IdentityHeaderRow()
        }
      }
      SwiftUI.Section {
        ForEach(staticDestinations, id: \.self) { dest in
          NavigationLink(value: dest) { staticRow(dest) }
        }
      }
      // About sits on its own, below Feedback — a utility row (gray disc
      // tile) set apart by the section break, not mixed in with the
      // accent-colored intent groups.
      SwiftUI.Section {
        NavigationLink(value: SettingsDestination.about) { aboutRow }
      }
    }
    .scrollContentBackground(.hidden)
    .background(SettingsTopGradient())
  }
  #else
  @ViewBuilder
  private func sidebarList(selection: Binding<SettingsDestination?>) -> some View {
    List(selection: selection) {
      SwiftUI.Section {
        IdentityHeaderRow().tag(SettingsDestination.account)
      }
      SwiftUI.Section {
        ForEach(staticDestinations, id: \.self) { dest in
          staticRow(dest).tag(dest)
        }
      }
      // About on its own, below Feedback — gray disc tile, set apart.
      SwiftUI.Section {
        aboutRow.tag(SettingsDestination.about)
      }
    }
  }
  #endif

  private var staticDestinations: [SettingsDestination] {
    // Seven intent groups. The profile card above this list is destination 0;
    // About/Advanced live under Account so utility pages don't consume root
    // slots, and the former General controls sit inside Home.
    [.sections, .home, .notifications, .connectionsAI,
     .sharingData, .privacy, .feedback]
  }

  private func staticRow(_ dest: SettingsDestination) -> some View {
    Label {
      Text(title(for: dest))
    } icon: {
      #if os(macOS)
      ColoredGlyph(icon: icon(for: dest), color: tint(for: dest), size: 20, glyphRatio: 0.48)
      #else
      ColoredGlyph(icon: icon(for: dest), color: tint(for: dest), size: 29, glyphRatio: 0.38)
      #endif
    }
  }

  /// The About row, shared by both sidebars: the Septena disc tile (gray,
  /// utility) plus the "About" label. Sized to match the platform's static
  /// rows (29pt on iOS, 20pt on macOS).
  private var aboutRow: some View {
    Label {
      Text(title(for: .about))
    } icon: {
      #if os(macOS)
      SeptenaDiscTile(size: 20)
      #else
      SeptenaDiscTile(size: 29)
      #endif
    }
  }

  private func sectionIcon(for key: String) -> String {
    if let m = SectionManifest.byKey[key] { return m.iconSymbol }
    return "circle.fill"
  }

  private func title(for dest: SettingsDestination) -> String {
    switch dest {
    case .account:      return "Account"
    case .sections:     return "Sections"
    case .home:         return "Home"
    case .connectionsAI: return "Connections & AI"
    case .sharingData:  return "Sharing & Data"
    case .general:      return "General"
    case .claudeAI:     return "AI"
    case .quickActions: return "Quick Actions"
    case .appIcon:      return "App Icon"
    case .layout:       return "Layout"
    case .correlations: return "Insights"
    case .timeOfDay:    return "Time of Day"
    case .nextFeed:     return "Next"
    case .notifications: return "Notifications"
    case .connections:  return "Connected Apps"
    case .data:         return "Import & Export"
    case .reports:      return "Practitioner Reports"
    case .support:      return "Support"
    case .communityProfile: return "Public Profile"
    case .communityRoadmap: return "Roadmap"
    case .communityTestimonial: return "Testimonial"
    case .skills:       return "MCP Skills"
    case .siriShortcuts: return "Siri & Shortcuts"
    case .privacy:      return "Privacy"
    case .feedback:     return "Feedback"
    case .about:        return "About"
    case .whatsNew:     return "What's New"
    case .advanced:     return "Advanced"
    case .dataTools:    return "Data Tools"
    case .motionGallery: return "Motion Gallery"
    case .milestonePreview: return "Milestones (preview)"
    case .localMcp:     return "MCP Server"
    case .section(let key):
      return SectionManifest.displayLabel(
        key: key,
        stored: store.sections.first(where: { $0.key == key })?.label ?? "")
    }
  }

  // Icon + tint helpers feed the root sidebar rows; sub-panes carry their
  // own Label glyphs at their navigation links.
  private func icon(for dest: SettingsDestination) -> String {
    switch dest {
    case .account:      return "person.crop.circle"
    case .sections:     return "square.grid.2x2"
    case .home:         return "house"
    case .connectionsAI: return "brain.head.profile"
    case .sharingData:  return "square.and.arrow.up"
    case .general:      return "slider.horizontal.3"
    case .claudeAI:     return "brain.head.profile"
    case .quickActions: return "bolt"
    case .appIcon:      return "app.badge"
    case .layout:       return "square.grid.2x2"
    case .correlations: return "chart.dots.scatter"
    case .timeOfDay:    return "clock"
    case .nextFeed:     return "arrow.forward.circle"
    case .notifications: return "bell.badge"
    case .connections:  return "app.connected.to.app.below.fill"
    case .data:         return "externaldrive"
    case .reports:      return "chart.bar.doc.horizontal"
    case .support:      return "lifepreserver"
    case .communityProfile: return "person.text.rectangle"
    case .communityRoadmap: return "map"
    case .communityTestimonial: return "quote.bubble"
    case .skills:       return "book.closed"
    case .siriShortcuts: return "mic"
    case .privacy:      return "hand.raised"
    case .feedback:     return "bubble.left.and.bubble.right"
    case .about:        return "info.circle"
    case .whatsNew:     return "megaphone"
    case .advanced:     return "wrench.and.screwdriver"
    case .dataTools:    return "stethoscope"
    case .motionGallery: return "wand.and.rays"
    case .milestonePreview: return "flag.checkered"
    case .localMcp:     return "server.rack"
    case .section:      return "circle.fill"
    }
  }

  /// The app's 7 accent colors — the Septena app-icon rainbow (same set
  /// as `AppIconOption`'s discs). The app-wide settings rows cycle
  /// through these in `staticDestinations` order instead of carrying
  /// ad-hoc per-row tints, so the palette stays on-brand and consistent.
  private static let accentPalette: [Color] = SettingsAccentPalette.colors

  private func tint(for dest: SettingsDestination) -> Color {
    guard let idx = staticDestinations.firstIndex(of: dest) else { return .gray }
    return Self.accentPalette[idx % Self.accentPalette.count]
  }

  @ViewBuilder
  private func pane(for dest: SettingsDestination) -> some View {
    switch dest {
    case .account:           AccountSettingsPane()
    case .sections:          SectionsSettingsPane()
    case .home:              HomeSettingsPane()
    case .connectionsAI:     ConnectionsAISettingsPane()
    case .sharingData:       SharingDataSettingsPane()
    case .general:           GeneralSettingsPane()
    case .claudeAI:          ClaudeAISettingsPane()
    case .quickActions:      QuickActionsSettingsPane()
    case .appIcon:           AppIconSettingsPane()
    case .layout:            LayoutSettingsPane()
    case .correlations:      CorrelationsSettingsPane()
    case .timeOfDay:         TimeOfDaySettingsPane()
    case .nextFeed:          NextSettingsPane()
    case .notifications:     NotificationsOverviewPane()
    case .connections:       IntegrationsSettingsPane()
    case .data:              ImportExportSettingsPane(mode: .full)
    case .reports:           ReportsSettingsPane()
    case .support:           SupportSettingsPane()
    case .communityProfile:  CommunityProfilePane()
    case .communityRoadmap:  CommunityRoadmapPane()
    case .communityTestimonial: CommunityTestimonialPane()
    case .dataTools:         ImportExportSettingsPane(mode: .dataTools)
    case .skills:            SkillsSettingsPane()
    case .siriShortcuts:     SiriShortcutsSettingsPane()
    case .privacy:           PrivacySettingsPane()
    case .feedback:          FeedbackSettingsPane()
    case .about:             AboutSettingsPane()
    case .whatsNew:          ChangelogList()
    case .advanced:          AdvancedSettingsPane()
    case .motionGallery:     MotionGalleryPane()
    case .milestonePreview:  MilestonePreviewPane()
    #if os(macOS)
    case .localMcp:          LocalMCPSettingsPane()
    #else
    case .localMcp:          MCPServerUnavailablePane()
    #endif
    case .section(let key):  SectionDetailPane(sectionKey: key)
    }
  }
}

/// Resolved sidebar row for a section — combines the static manifest
/// (icon, defaults) with the live server overrides (label, accent).
struct SectionEntry: Identifiable, Hashable {
  let manifest: SectionManifest
  let server: SectionConfig
  var id: String { manifest.key }
  var key: String { manifest.key }
  /// Installed `SectionEntity.title` wins; manifest default is the
  /// fallback when the user hasn't customized the label (or the local
  /// mirror hasn't hydrated yet).
  var label: String {
    SectionManifest.displayLabel(key: manifest.key, stored: server.label)
  }
  /// Accent comes from the user's `SectionEntity.color`. No catalog
  /// default — `parseHexColor` already returns neutral gray for empty
  /// or unparseable strings, which is the right fallback when the user
  /// hasn't picked a color yet.
  var accent: Color { parseHexColor(server.color) }
  /// User has turned this section off. The row stays in the sidebar but
  /// renders muted so it's clear the section isn't active.
  var isEnabled: Bool { server.isEnabled }
}

