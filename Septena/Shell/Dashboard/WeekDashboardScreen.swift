import SwiftUI
import EventKit

/// Empty-state shown when the user has selected a layout mode whose
/// renderer hasn't been built yet. Mirrors the system
/// `ContentUnavailableView` shape but stays plain `VStack` so the same
/// view renders cleanly inside the existing `LazyVGrid`'s parent stack
/// without an iOS-version gate.
struct ComingSoonLayoutPlaceholder: View {
  let mode: HomepageLayoutMode
  let onUseTiles: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: mode.icon)
        .scaledFont(size: 44, weight: .regular, relativeTo: .largeTitle)
        .foregroundStyle(.secondary)
      Text("\(mode.title) layout — coming soon")
        .font(.septenaCardTitle)
      Text(mode.summary)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
      Button("Use Tiles", action: onUseTiles)
        .buttonStyle(.bordered)
        .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 48)
  }
}

struct WeekDashboardScreen<CurrentDay: Equatable, MenuExtra: View, Content: View>: View {
  let currentDay: CurrentDay
  let onInitialLoad: () async -> Void
  let onTaskChange: () -> Void
  let onDayChange: () -> Void
  /// Receives the `.septenaDataChanged` notification itself so the owner
  /// can scope the reload to `note.changedSections` (nil = refresh all).
  let onDataChange: (Notification) -> Void
  let onTileChange: (AddInfoSection) -> Void
  /// Week's tab-specific rows for the shared "…" home menu.
  @ViewBuilder let menuExtra: () -> MenuExtra
  @ViewBuilder let content: () -> Content

  var body: some View {
    NavigationStack {
      ScrollView {
        content()
      }
      // Grouped-gray canvas with the current sky FIXED across the top: tied
      // to the top of the screen (bleeds behind the status / nav bar via
      // `.ignoresSafeArea`) and not scrolling — ambient light on the page,
      // not a scrolling header. Contained to the top ~third so it's a wash
      // over the greeting that fades to clear into the gray around the top of
      // the dial. Fixed-behind-content, so the cards scroll over it.
      .background {
        GeometryReader { geo in
          ZStack(alignment: .top) {
            Theme.groupedBackground
            SkyTopWash()
              // Taller band than the dial needs: SkyTopWash's curved fade
              // completes ~15% above its own foot, so the extra height is the
              // room the horizon needs to melt out softly instead of clipping.
              .frame(height: geo.size.height * 0.44, alignment: .top)
          }
          // Contain SkyTopWash's dark-mode `plusLighter` blend to the canvas
          // below it (not whatever sits behind the whole background).
          .compositingGroup()
        }
        .ignoresSafeArea()
      }
      // Tab bar already labels this view. Keep the nav bar present so
      // iOS's default scroll-edge effect kicks in (content fades to bg
      // material as it scrolls under the top — same shape as the
      // bottom tab bar). No .toolbarBackground override — the default
      // transparent-until-scrolled state is exactly what we want.
      .navigationTitle("")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      // Shared home-landing chrome across Week / Next / Coach: the top-left
      // "…" menu, with Week's dashboard-layout switcher + Insights injected
      // above the shared Settings row. See HomeChrome.swift.
      .homeChrome { menuExtra() }
      // iOS: float the "keep Claude connected" cue as a glass pill in the top
      // bar's TRAILING corner — opposite the leading "…" menu, so the system
      // doesn't fold the two into one shared glass bar. Renders nothing unless
      // the token is stale (see ClaudeReconnectCue). macOS shows it inline.
      #if os(iOS)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          ClaudeReconnectCue(.pill)
        }
      }
      #endif
      // Two-phase load: paint cached blobs synchronously so tiles +
      // histograms appear immediately on cold launch, then kick off the
      // network refresh in the background.
      .task {
        await onInitialLoad()
      }
      // CK fetch landed (push or foreground refresh) — repaint so today's
      // task counts reflect mutations from other devices.
      .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
        onTaskChange()
      }
      // CK fetch batch landed for any non-task domain (push, periodic
      // fetch, or a write on another device). Refresh every CK-backed
      // tile from its SwiftData mirror. Without this, the dashboard
      // stays stuck on whatever `loadAll` saw at cold launch — entries
      // logged on another device never repaint until the user visits
      // the section.
      .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
        onDataChange(note)
      }
      // Day rollover: the dashboard is the most date-sensitive surface
      // (today's timeline, today's totals, 7-day windows ending today).
      // Refetch everything when `clock.today` flips.
      .onChange(of: currentDay) { _, _ in
        onDayChange()
      }
      // Quick-add finished — repaint just that tile from cache (instant,
      // for sections that wrote optimistic state) and refetch its
      // endpoints in the background to reconcile with the server. Scoped
      // to the touched section so the rest of the dashboard stays put.
      .onReceive(NotificationCenter.default.publisher(for: .tilesDidChange)) { note in
        guard let key = note.userInfo?[TileChangeKey.section] as? String,
              let section = AddInfoSection(rawValue: key) else { return }
        onTileChange(section)
      }
    }
  }
}

struct WeekDashboardTimelineCard: View {
  let date: String
  let oura: OuraNight?
  let nutrition: [NutritionEntry]
  let gut: [GutEntry]
  let mood: [MoodEntry]
  let habits: [HabitDayItem]
  let supplements: [SupplementDayItem]
  let chores: [ChoreItem]
  let training: [ExerciseEntry]
  let tasks: [SeptenaTask]
  let extras: [DayTimelineExtraEvent]
  let calendar: [EKEvent]
  let macroColors: MacroColors?
  var fullDay: Bool = false

  var body: some View {
    DayTimelineView(
      date: date,
      oura: oura,
      nutrition: nutrition,
      gut: gut,
      mood: mood,
      habits: habits,
      supplements: supplements,
      chores: chores,
      training: training,
      tasks: tasks,
      extras: extras,
      calendar: calendar,
      macroColors: macroColors,
      fullDay: fullDay
    )
    // Skip the body (day re-clustering) when none of the inputs changed —
    // the dashboard re-renders far more often than the timeline data moves.
    .equatable()
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.secondaryGroupedBackground)
    )
  }
}
