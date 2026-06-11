import SwiftUI

// Insights — the dedicated destination the Correlations engine graduated
// into (from a homepage *layout mode* to its own surface). Hosts the full
// correlation explorer (`CorrelationsHomepageView`) inside the standard
// section chrome, behind the Septena+ gate. The homepage keeps only a
// single glance tile (the strongest trusted signal) that deep-links here.
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

  @AppStorage(SettingsKey.plusUnlocked) private var plusUnlocked: Bool = false
  @State private var showPaywall = false
  /// The Insights tuning pane (window, section filter), presented over the
  /// drawer. Its canonical home is Customize → Insights; this leading-edge
  /// shortcut opens the same page without leaving the explorer.
  @State private var showSettings = false

  var body: some View {
    SectionDrawer(sectionKey: "insights", title: "Insights",
                  accent: Self.accent, showsSettingsLink: false) {
      if plusUnlocked {
        CorrelationsHomepageView()
      } else {
        InsightsLockedView { showPaywall = true }
      }
    }
    // Tuning only matters once the explorer is live — gate the shortcut on
    // the same unlock as the content.
    .toolbar {
      if plusUnlocked {
        #if os(iOS)
        let placement: ToolbarItemPlacement = .topBarLeading
        #else
        let placement: ToolbarItemPlacement = .navigation
        #endif
        ToolbarItem(placement: placement) {
          Button {
            showSettings = true
          } label: {
            Label("Insights Settings", systemImage: "slider.horizontal.3")
          }
        }
      }
    }
    .sheet(isPresented: $showSettings) {
      SettingsView(initialDestination: .correlations)
    }
    .sheet(isPresented: $showPaywall) {
      SeptenaPlusPaywall { plusUnlocked = true; showPaywall = false }
    }
  }
}

/// Upsell shown in the Insights destination when Septena+ is locked. The
/// homepage glance tile always deep-links here; the gate lives in one place.
private struct InsightsLockedView: View {
  let onUnlock: () -> Void
  private let accent = InsightsDestinationView.accent

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "chart.dots.scatter")
        .font(.system(size: 40, weight: .semibold))
        .foregroundStyle(accent)
      Text("Insights")
        .font(.title2.weight(.semibold))
      Text("Find what actually moves your day — which habits, inputs, and routines track with better sleep, mood, recovery, and more. Real correlations across everything you log, computed privately on-device.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 8)
      Button(action: onUnlock) {
        Text("Unlock with Septena+")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(accent)
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }
}
