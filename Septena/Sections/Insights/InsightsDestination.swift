import SwiftUI

// Insights — the dedicated destination the Correlations engine graduated
// into (from a homepage *layout mode* to its own surface). Hosts the full
// correlation explorer (`CorrelationsHomepageView`) inside the standard
// section chrome. Free for everyone — the correlation engine runs entirely
// on-device, so there's nothing to gate.
//
// Why a destination, not a layout mode: tiles/dense/heatmap are renderings
// of *today's sections*; Insights is a derived analysis of your *history*
// with its own depth (and a roadmap toward hypothesis tracking + N-of-1
// experiments) that a single homepage layout can't hold. Its homepage
// entry point is a toolbar button on the Week dashboard (it has no per-day
// series of its own, so it isn't a tile or a body card).
//
// Insights is deliberately NOT a Manage-Sections catalog entry — it owns no
// data and isn't a life domain. It therefore carries its own identity here
// (title + accent) instead of reading them from the section manifest/theme.

struct InsightsDestinationView: View {
  /// Insights has no SectionEntity accent of its own. Its identity (title,
  /// icon, tint) is defined here — a fixed violet that reads as "analysis",
  /// distinct from the life-domain section colors.
  static let accent = Color(red: 0.486, green: 0.227, blue: 0.929) // #7c3aed

  /// The Insights tuning pane (window, section filter). Its canonical home
  /// is Customize → Insights; this leading-edge shortcut opens the same page
  /// without leaving the explorer. iOS presents it as a sheet over the
  /// drawer; macOS routes through the shared Settings window.
  #if os(macOS)
  @Environment(NavigationState.self) private var nav
  #else
  @State private var showSettings = false
  #endif

  var body: some View {
    SectionDrawer(sectionKey: "insights", title: "Insights",
                  accent: Self.accent, showsSettingsLink: false) {
      CorrelationsHomepageView()
    }
    .onAppear {
      log("destination appeared")
    }
    .toolbar {
      #if os(iOS)
      let placement: ToolbarItemPlacement = .topBarLeading
      #else
      let placement: ToolbarItemPlacement = .navigation
      #endif
      ToolbarItem(placement: placement) {
        Button {
          #if os(macOS)
          nav.settingsDestination = .correlations
          nav.showSettings = true
          #else
          showSettings = true
          #endif
        } label: {
          Label("Insights Settings", systemImage: "slider.horizontal.3")
        }
      }
    }
    #if os(iOS)
    .sheet(isPresented: $showSettings) {
      SettingsView(initialDestination: .correlations)
    }
    #endif
  }

  private func log(_ message: String) {
    let line = "[Insights] \(message)"
    SeptenaLog.info(line)
    #if DEBUG
    print(line)
    #endif
  }
}
