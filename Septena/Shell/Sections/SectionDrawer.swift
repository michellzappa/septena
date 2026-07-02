import SwiftUI

// SectionDrawer — the standard outer container for every section's
// destination view. One pattern replaces the per-section List/ScrollView
// drift: ScrollView + LazyVStack, grouped background, the goals strip
// always pinned at the top, consistent padding.
//
// Destination views supply only their section-specific content via the
// trailing closure. Group content into `DrawerSection`s the same way you
// previously used List `Section("Title") { ... }`.

/// Cross-cutting load lifecycle a destination can hand to its drawer.
/// `.idle` is the no-op default (drawer renders the content as-is);
/// `.loading` surfaces a subtle inline spinner in the toolbar so the
/// user knows a fetch is in flight without blocking what's already on
/// screen (most destinations cache via `paintFromCache`); `.failed`
/// replaces `content()` with a standardized retry affordance.
enum DrawerLoadState: Equatable {
  case idle
  case loading
  case failed(String)
}

/// How a section drawer paints its surfaces (the scroll background and the
/// `DrawerSection` / `StatTile` cards). One enum is the single source of truth
/// so the solid-vs-glass decision lives in exactly one place instead of being
/// hand-applied per card.
///
/// - `.solid` — opaque grouped background + opaque cards (default; the
///   iPad/macOS pushed pane and any opaque host).
/// - `.glass` — clear background + Liquid Glass cards so the cards float on the
///   translucent presentation (the iPhone sheet) instead of dissolving into it.
///   Injected by `sectionDrawerPresentation()`, never set by hand in a
///   destination view. Apply the card surface via `.drawerCardSurface()`.
enum DrawerSurfaceStyle {
  case solid
  case glass

  /// Fill behind the drawer's scroll content.
  var scrollFill: Color {
    switch self {
    case .solid: return Theme.groupedBackground
    case .glass: return .clear
    }
  }
}

extension View {
  /// Paints the rounded card surface shared by `DrawerSection` and `StatTile`,
  /// picking solid vs. glass from the injected `\.drawerSurfaceStyle` so the two
  /// card types can't drift. `.solid` lays the opaque secondary-grouped card
  /// (iPad / macOS pane, any opaque host). `.glass` floats the content on a
  /// Liquid Glass panel — the same `glassCard()` treatment the dashboard tiles
  /// use (see `ModuleTile`) — so cards lift off the translucent iPhone sheet
  /// while staying translucent. Clip follows the glass, matching `ModuleTile`,
  /// so any full-bleed row highlight stays inside the rounded corners.
  /// `cornerRadius` defaults to the full-width card radius (`Theme.cornerRadius`)
  /// used by `DrawerSection` / `StatTile`; pass a smaller value for compact
  /// surfaces (grid tiles, inline rows) so they keep their own radius while
  /// still picking solid-vs-glass from the injected style.
  func drawerCardSurface(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
    modifier(DrawerCardSurface(cornerRadius: cornerRadius))
  }
}

private struct DrawerCardSurface: ViewModifier {
  var cornerRadius: CGFloat = Theme.cornerRadius
  @Environment(\.drawerSurfaceStyle) private var surfaceStyle

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    switch surfaceStyle {
    case .solid:
      content
        .background(shape.fill(Theme.secondaryGroupedBackground))
        .clipShape(shape)
    case .glass:
      // Float on neutral Liquid Glass (the dashboard-tile helper) with a faint
      // neutral hairline rim. The rim is what keeps the card from dissolving
      // into the translucent sheet — it lifts as a crisp, defined pane — while
      // accent stays off the chrome (it lives on the controls + tint). Clip
      // before the rim so the stroke isn't half-cut by the clip.
      content
        .glassCard(cornerRadius: cornerRadius)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.border, lineWidth: 0.5))
    }
  }
}

private struct DrawerSurfaceStyleKey: EnvironmentKey {
  static let defaultValue: DrawerSurfaceStyle = .solid
}

extension EnvironmentValues {
  var drawerSurfaceStyle: DrawerSurfaceStyle {
    get { self[DrawerSurfaceStyleKey.self] }
    set { self[DrawerSurfaceStyleKey.self] = newValue }
  }
}

private struct UsesPushNavigationKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// True when section / coach destinations should open as a pushed full pane
  /// (with room to dock an inspector, and room for a side-by-side dual-mode
  /// drawer) rather than a modal bottom sheet. This is the single source of
  /// truth for that rule — the Week dashboard, the Coach tab, the section-drawer
  /// inspector decision, and the drawer column layout all read it instead of
  /// recomputing from the size class, so they can never drift. True only on a
  /// dual-regular canvas (regular width AND height): iPad full-screen, an
  /// unfolded foldable, macOS. A landscape iPhone is regular-width but
  /// compact-height, so it reads false here and gets the bottom-sheet drawer.
  /// Published once at the app root by `.resolvesAdaptiveNavigation()`.
  var usesPushNavigation: Bool {
    get { self[UsesPushNavigationKey.self] }
    set { self[UsesPushNavigationKey.self] = newValue }
  }
}

extension View {
  /// Resolves the adaptive-navigation rule from the current size classes and
  /// publishes it into the environment as `\.usesPushNavigation`. macOS always
  /// pushes; iOS pushes only when BOTH size classes are regular (iPad
  /// full-screen / large multitasking / unfolded foldable), so a compact iPad
  /// window AND a landscape iPhone (regular width, compact height) both fall
  /// back to bottom sheets. Apply once near the app root.
  func resolvesAdaptiveNavigation() -> some View {
    modifier(ResolveAdaptiveNavigation())
  }
}

private struct ResolveAdaptiveNavigation: ViewModifier {
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  @Environment(\.verticalSizeClass) private var vSize
  #endif

  private var usesPush: Bool {
    #if os(macOS)
    return true
    #else
    // A pushed pane / side-by-side drawer wants a genuinely large canvas —
    // regular in BOTH dimensions (iPad full-screen, an unfolded foldable, a
    // wide Mac window). A landscape iPhone reports a regular *width* but a
    // compact *height*: it's short and notch-asymmetric, so the iPad pushed-
    // pane treatment looks broken there. Gating on height too sends it down
    // the bottom-sheet path (the polished portrait drawer) instead, while
    // staying size-class-driven — never an idiom check — so a foldable still
    // gets the full treatment when unfolded.
    return hSize == .regular && vSize == .regular
    #endif
  }

  func body(content: Content) -> some View {
    content.environment(\.usesPushNavigation, usesPush)
  }
}

// MARK: - Drawer mode (Log / Patterns)
//
// A section drawer presents one of two modes, switched by the top-left glass
// toggle the scaffold renders when a `mode` binding is supplied:
//   • .log      — the records list + point-in-time readouts (a single day;
//                 editable + time-travel for user-authored sections).
//   • .patterns — charts / heatmaps / rhythm wheels / trends (range-windowed,
//                 read-only).
// Only sections that have BOTH modes pass a binding; single-mode drawers leave
// it nil and no toggle appears. The destination owns the `@State` and switches
// its own `content`; the choice is remembered per section. See
// docs/DRAWER_MODES_SPEC.md.
enum DrawerMode: String, Hashable {
  case log, patterns

  /// The per-section remembered mode, or `fallback` if the user never toggled.
  ///
  /// FORCED to `fallback` for now: every drawer should open in Log regardless of
  /// any previously-toggled choice (the default is `.log` everywhere). The toggle
  /// still flips the mode for the current visit and `remember(for:)` still writes
  /// the stored value, so re-enabling persistence is a one-line revert — just
  /// restore the UserDefaults read below.
  static func remembered(for sectionKey: String, default fallback: DrawerMode) -> DrawerMode {
    return fallback
  }

  /// Persist this mode as the section's remembered choice.
  func remember(for sectionKey: String) {
    UserDefaults.standard.set(rawValue, forKey: Self.storageKey(sectionKey))
  }

  private static func storageKey(_ sectionKey: String) -> String { "drawerMode.\(sectionKey)" }

  /// One-shot empty-day nudge for editable dual sections: if still in `.log` and
  /// the day you're viewing is today with nothing logged, swing to `.patterns`
  /// so an empty log greets you with the pattern view instead of a dead end (the
  /// global "+" stays one tap away). Never persisted — only a deliberate toggle
  /// sticks. Call from a section's reload once data has loaded; `didNudge` guards
  /// it to a single fire per appearance. Centralized here so every section that
  /// wants it shares the exact same rule.
  ///
  /// DISABLED for now: drawers should always start in Log — opening into Patterns
  /// just because today's log is empty proved more confusing than helpful. The
  /// call sites stay wired (and `didNudge` still consumes) so this is a one-line
  /// revert if we want the nudge back; the default mode is `.log` everywhere, so
  /// short-circuiting here means every section reliably lands on the log.
  static func nudgeEmptyDayToPatterns(mode: Binding<DrawerMode>,
                                      didNudge: Binding<Bool>,
                                      isViewingToday: Bool,
                                      isEmpty: Bool) {
    didNudge.wrappedValue = true
  }
}

/// The top-left control that flips a drawer between Log and Patterns — the
/// leading-edge twin of the trailing "+": the same prominent accent-filled round
/// glass button, so the drawer is bookended by two big round buttons (switch on
/// the left, add on the right). Rendered by `SectionDrawer` whenever a `mode`
/// binding is present, and now the *only* leading control — time travel moved to
/// a footer "previous days" link.
struct DrawerModeToggle: View {
  @Binding var mode: DrawerMode
  /// Key the toggled choice is remembered under. Usually the section key, but
  /// can be a finer key (e.g. per Intake kind) so sibling pages remember apart.
  let storageKey: String
  /// Accent the prominent glass circle is washed with — matches the trailing "+".
  let accent: Color

  var body: some View {
    Button {
      let next: DrawerMode = (mode == .log) ? .patterns : .log
      withAnimation(.snappy) { mode = next }
      // Persist ONLY on an explicit user toggle. Programmatic mode changes
      // (the empty-state nudge, day-step-forces-Log) deliberately route around
      // this so they never overwrite the remembered choice.
      next.remember(for: storageKey)
    } label: {
      // The glyph shows what tapping switches TO: a chart while in Log, a list
      // while in Patterns.
      Image(systemName: mode == .log ? "chart.xyaxis.line" : "list.bullet")
        .accessibilityLabel(mode == .log ? "Show patterns" : "Show log")
    }
    // Identical to the trailing "+" (`DrawerActionButton`): the toolbar floats a
    // bare `.glassProminent` circle, the full accent `.tint` fills it, and the
    // style auto-contrasts the glyph to white. The drawer is bookended by two
    // matching accent circles — switch on the left, add on the right. (A neutral
    // circle with a colored glyph isn't reachable through the toolbar's glass
    // styles, so we mirror the "+" rather than fight it.)
    .buttonStyle(.glassProminent)
    .tint(accent)
  }
}

// MARK: - Patterns range picker
//
// One segmented window control for every Patterns chart that's range-windowed
// (Training progression, Activity history, …). The section declares which
// windows it supports and binds the chosen trailing-day count; the labels and
// segmented styling live here so they can't drift between sections.

/// A standard trailing-day window for a Patterns chart. Raw value = days.
enum DrawerRange: Int, CaseIterable, Identifiable {
  case week = 7
  case month = 30
  case sixty = 60
  case ninety = 90
  case year = 365

  var id: Int { rawValue }

  var label: String {
    switch self {
    case .week:   return "7d"
    case .month:  return "30d"
    case .sixty:  return "60d"
    case .ninety: return "90d"
    case .year:   return "1y"
    }
  }
}

/// Shared segmented range control. The section passes the windows it supports;
/// the picker binds the chosen day count (so call sites keep a plain `Int`).
struct DrawerRangePicker: View {
  @Binding var days: Int
  var options: [DrawerRange]

  var body: some View {
    Picker("Range", selection: $days) {
      ForEach(options) { Text($0.label).tag($0.rawValue) }
    }
    .pickerStyle(.segmented)
  }
}

struct SectionDrawer<Content: View>: View {
  let sectionKey: String
  /// Section name shown as the inline nav-bar title. Optional — when omitted,
  /// the drawer derives it from the section manifest (`defaultLabel`), so call
  /// sites don't hand-pass a title that's already in the catalog. Pass an empty
  /// string to explicitly suppress it (utility drawers with no heading).
  var title: String? = nil
  /// Tint used for the "+" toolbar affordance (and inherited by sheets
  /// presented from this drawer). Defaults to the section's theme color
  /// if the destination doesn't override.
  var accent: Color? = nil
  /// The drawer's single quick-add affordance — the prominent accent "+" in the
  /// trailing toolbar slot. Required for the "+" to appear; `nil` renders none.
  /// One spec (title + icon + action) declared at the call site — the single
  /// source of truth per section.
  var quickAdd: DrawerQuickAdd? = nil
  /// Drawer-level load lifecycle. `.idle` is the no-op default. When
  /// the destination knows about its own fetch state, surface it here
  /// so the toolbar spinner / failure-state UI stays consistent.
  var loadState: DrawerLoadState = .idle
  /// Invoked when the user taps "Try again" on the failed-state UI.
  /// Required only when `loadState` can become `.failed`.
  var onRetry: (() -> Void)? = nil
  /// Binding to a destination's search query. Non-nil installs the
  /// system `.searchable` field on the drawer (sheet-style pull-down on
  /// iOS, leading-edge field on macOS). The destination consumes the
  /// string to filter its content; the drawer just hosts the input.
  var searchText: Binding<String>? = nil
  /// Optional search-field placeholder. Defaults to "Search".
  var searchPrompt: String = "Search"
  /// Binding to the YYYY-MM-DD date the destination is currently
  /// viewing. Non-nil installs a calendar "time travel" button in the
  /// toolbar (and a context pill under the title while viewing a past
  /// day) so the user can open the `TimeTravelSheet` picker, jump to a
  /// recent day, or pick an older date without leaving the drawer. The
  /// destination reads the same binding to fetch its day-scoped data,
  /// replacing per-section `BrowseXDaySheet` detours.
  var currentDate: Binding<String>? = nil
  /// Binding to the section's current Log/Patterns mode. Non-nil renders the
  /// top-left glass mode toggle and hides the calendar/time-travel control while
  /// viewing Patterns (Patterns is range-windowed, never date-stepped). The
  /// destination owns the mode `@State` + persistence and switches its own
  /// `content` on the value; the drawer just hosts the toggle. nil for
  /// single-mode sections.
  var mode: Binding<DrawerMode>? = nil
  /// Storage key for the remembered mode when it must differ from `sectionKey`
  /// — e.g. Intake's per-kind pages all share `sectionKey` "intake" but each
  /// kind remembers its own mode. Defaults to `sectionKey`.
  var modeStorageKey: String? = nil
  /// Whether to render the subtle "Customize <Section>" footer that
  /// deep-links into this section's Settings pane. Default on; the footer
  /// also self-hides for utility drawers (empty `title` or a `sectionKey`
  /// with no `SectionManifest`) and while time-traveling.
  var showsSettingsLink: Bool = true
  /// Optional override for the footer link's tap. When set, the "Customize
  /// <Section>" link runs this instead of deep-linking into the section's
  /// Settings pane — for drawers whose real settings live elsewhere (e.g.
  /// Intake's per-kind pages, where each kind's settings is its own Manage
  /// sheet rather than the section-wide pane).
  var settingsAction: (() -> Void)? = nil
  /// Whether to flow `content()` through `DrawerColumns` (the 1-vs-2 column
  /// masonry). Default on. Set `false` for destinations that are a *single*
  /// monolithic view doing their own internal width-responsive layout (e.g.
  /// Insights) — the masonry would otherwise place that one subview into one
  /// half-width column and leave the other empty, collapsing a wide pane into
  /// a thin column. Full-width hands the destination the entire content width.
  var usesColumns: Bool = true
  @ViewBuilder var content: () -> Content

  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  /// Solid (default) vs glass surfaces, injected by the presentation host
  /// (`sectionDrawerPresentation()`) so the iPhone sheet reads `.glass` while
  /// the iPad/macOS pane stays `.solid`.
  @Environment(\.drawerSurfaceStyle) private var surfaceStyle
  /// True on the pushed-pane surfaces (macOS always, iPad regular width) where a
  /// hardware keyboard is the norm — gates the ←/→ day-stepping shortcut.
  @Environment(\.usesPushNavigation) private var usesPushNavigation

  /// Holds keyboard focus on the drawer body so ←/→ step the viewed day even
  /// with Full Keyboard Access off (programmatic focus, per the keyboard-nav
  /// convention — a plain `.focusable()` wouldn't receive keys without FKA).
  @FocusState private var dayNavFocused: Bool

  /// Whether the time-travel date picker sheet is open. The picker lives
  /// behind a calendar toolbar button rather than an always-visible strip,
  /// so today's logging owns the top of the drawer.
  @State private var showingTimeTravel = false

  /// True once a dual-mode body has gone side-by-side (Log + Patterns shown
  /// together on a wide pane). Raised by `DrawerModeColumns` through
  /// `DrawerSideBySideKey`; the toolbar drops the now-meaningless Log/Patterns
  /// toggle while it's set, and the day controls stay visible even when the
  /// remembered mode is Patterns (the Log half still wants its calendar).
  @State private var modeShowsBoth = false

  /// Whether the deep-linked Settings sheet (this section's pane) is open.
  /// Presented over the drawer so closing it returns the user here.
  #if os(macOS)
  // macOS opens the deep-linked section Settings in the shared Settings
  // window (traffic-lit) rather than a chrome-less sheet over the drawer.
  @Environment(NavigationState.self) private var nav
  #else
  @State private var showingSettings = false
  #endif

  private var resolvedAccent: Color {
    accent ?? theme.color(for: sectionKey)
  }

  /// Title shown in the nav bar. Falls back to the manifest's default label so
  /// call sites can omit `title:` for any catalogued section.
  private var resolvedTitle: String {
    title ?? SectionManifest.byKey[sectionKey]?.defaultLabel ?? ""
  }

  /// True when the destination has a date strip pointing at a past day.
  /// Signals to destinations (via the shared `clock.today` comparison
  /// they can do themselves) that histograms / heatmaps should be hidden —
  /// past days are a read-only log review, not a dashboard.
  private var isTimeTraveling: Bool {
    guard let currentDate else { return false }
    return currentDate.wrappedValue != clock.today
  }

  /// True while the drawer is showing its Patterns (visualization) mode, when a
  /// mode binding is present. Single-mode drawers are never in Patterns. The
  /// calendar/time-travel control hides here — Patterns is range-windowed, never
  /// stepped to a single past day.
  private var inPatterns: Bool { mode?.wrappedValue == .patterns }

  /// Whether the day-scoped controls (calendar button, "viewing past day" pill)
  /// should show. They hide in a pure Patterns view (range-windowed, never
  /// date-stepped) but stay when the drawer is side-by-side, since the Log half
  /// is on screen and still wants its day controls regardless of `mode`.
  private var showsDayControls: Bool { !inPatterns || modeShowsBoth }

  /// Whether ←/→ day-stepping is live: a day-scoped drawer on a pushed pane
  /// (Mac / iPad regular width). Compact iPhone sheets keep the tap-only
  /// time-travel picker.
  private var dayKeyNavEnabled: Bool {
    currentDate != nil && usesPushNavigation
  }

  /// Step the viewed day by `delta` days, clamping the forward edge at today —
  /// time travel reviews the past, never the future. ← goes back, → forward.
  /// Stepping the day is a Log action, so it pulls a dual section out of
  /// Patterns first (Patterns is cross-day and never date-stepped).
  private func stepDay(_ delta: Int) {
    if let mode, mode.wrappedValue == .patterns { mode.wrappedValue = .log }
    guard let currentDate,
          let day = SeptenaDate.parse(currentDate.wrappedValue),
          let moved = Calendar.current.date(byAdding: .day, value: delta, to: day)
    else { return }
    let today = Calendar.current.startOfDay(for: clock.now)
    let clamped = min(Calendar.current.startOfDay(for: moved), today)
    if let str = SeptenaDate.format(clamped), str != currentDate.wrappedValue {
      withAnimation(.snappy) { currentDate.wrappedValue = str }
    }
  }

  /// Snap the viewed day back to today from a past day — the footer "Back to
  /// today" affordance while time-traveling. Like `stepDay`, it's a Log action,
  /// so it also pulls a dual section out of Patterns first.
  private func backToToday() {
    if let mode, mode.wrappedValue == .patterns { mode.wrappedValue = .log }
    guard let currentDate, currentDate.wrappedValue != clock.today else { return }
    withAnimation(.snappy) { currentDate.wrappedValue = clock.today }
  }

  #if os(iOS)
  /// Touch twin of the ←/→ keys: a horizontal swipe steps the viewed day on a
  /// day-scoped Log drawer. Swipe right (content slides right) → previous day;
  /// swipe left → forward, clamped at today by `stepDay`. Gated on the same
  /// `showsDayControls` rule as the rest of time travel, so it's inert in
  /// Patterns. A `.simultaneousGesture` with a horizontal-dominance check so it
  /// rides alongside — never steals — the vertical scroll, and its 24pt minimum
  /// keeps taps on rows/buttons untouched.
  private var daySwipe: some Gesture {
    DragGesture(minimumDistance: 24)
      .onEnded { value in
        guard currentDate != nil, showsDayControls else { return }
        let dx = value.translation.width
        let dy = value.translation.height
        guard abs(dx) > 64, abs(dx) > abs(dy) * 1.5 else { return }
        stepDay(dx > 0 ? -1 : 1)
      }
  }
  #endif

  var body: some View {
    ScrollView {
      // Spacing/margins tuned to match insetGrouped List: ~20pt screen
      // inset and ~28pt between sections so the page breathes the same
      // way the old List did.
      // The chrome (time-travel pill, settings footer, failure state) stays
      // full-width; only the destination's section cards flow
      // into columns via `DrawerColumns`. A plain VStack here — the lazy,
      // column-aware stacking now lives inside `DrawerColumns`.
      VStack(spacing: Theme.Spacing.xxl) {
        // While viewing a past day, surface a slim pill under the title so
        // the time-travel context is never invisible — tap it to reopen the
        // picker or jump back to today. On today the drawer stays clean and
        // the calendar lives only in the toolbar.
        if isTimeTraveling, showsDayControls, let currentDate {
          TimeTravelPill(date: currentDate.wrappedValue) { showingTimeTravel = true }
        }
        if case .failed(let message) = loadState {
          failedView(message)
        } else {
          // On a regular-width pane (iPad / Mac) the section cards spread
          // across up to two columns; on iPhone (and any narrow pane) they
          // stay a single lazy column, exactly as before. Destinations that
          // own their internal responsive layout opt out (`usesColumns:
          // false`) and get the full content width.
          if usesColumns {
            DrawerColumns(spacing: Theme.Spacing.xxl) {
              content()
            }
          } else {
            content()
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          // Quiet footer links, grouped tight at the very bottom: a day-travel
          // affordance (day-scoped drawers only — this is where the former
          // top-left calendar button moved to) sitting just above the
          // "Customize <Section>" settings link. On today it opens the picker
          // ("View previous days"); while time-traveling it flips to a "Back to
          // today" shortcut. The settings link stays hidden while traveling.
          let showsHistory = currentDate != nil && showsDayControls
          let showsSettings = showsSettingsLink && !isTimeTraveling
            && !resolvedTitle.isEmpty && SectionManifest.byKey[sectionKey] != nil
          if showsHistory || showsSettings {
            VStack(spacing: Theme.Spacing.md) {
              if showsHistory {
                DrawerHistoryLink(isTimeTraveling: isTimeTraveling,
                                  onPrevious: { showingTimeTravel = true },
                                  onToday: { backToToday() })
              }
              if showsSettings {
                SectionSettingsLink(sectionTitle: resolvedTitle) {
                  if let settingsAction {
                    settingsAction()
                  } else {
                    #if os(macOS) && !SEPTASK
                    nav.settingsDestination = .section(sectionKey)
                    nav.showSettings = true
                    #elseif os(macOS)
                    // Septask compiles no Settings surface until P3 (and
                    // mounts no drawers) — inert by design.
                    #else
                    showingSettings = true
                    #endif
                  }
                }
              }
            }
          }
        }
      }
      .padding(.horizontal, Theme.pageGutter)
      .padding(.top, Theme.Spacing.sm)
      .padding(.bottom, 24)
    }
    // Surface fill driven by the injected style: opaque grouped background on
    // a solid host, clear on the glass (translucent-sheet) host. Over that base
    // we bleed a barely-there wash of the section's accent down from the top
    // edge (~5.5% peak, gone by a third of the way down) so each section's
    // drawer feels faintly lit by its own color without ever competing with
    // content. Pinned to the viewport (not the content), so it stays at the top
    // as you scroll; ignores the safe area so it reaches under the nav bar.
    .background {
      surfaceStyle.scrollFill
      LinearGradient(
        stops: [
          .init(color: resolvedAccent.opacity(0.055), location: 0),
          .init(color: .clear, location: 0.32),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
      .allowsHitTesting(false)
    }
    // A dual-mode body raises this once it splits Log + Patterns side-by-side, so
    // the toolbar can drop the Log/Patterns toggle (nothing left to switch).
    .onPreferenceChange(DrawerSideBySideKey.self) { value in
      modeShowsBoth = value
    }
    // ←/→ step the viewed day back / forward on the pushed panes (Mac, iPad
    // regular width). Programmatic focus (not a bare `.focusable`) so the keys
    // land with Full Keyboard Access off; we draw no chrome, so suppress the
    // focus halo. A focused TextField (e.g. the search field) consumes ←/→ for
    // its cursor first, so day-stepping never fights text editing.
    .focusable(dayKeyNavEnabled)
    .focusEffectDisabled()
    .focused($dayNavFocused)
    .task(id: dayKeyNavEnabled) { if dayKeyNavEnabled { dayNavFocused = true } }
    .onKeyPress(.leftArrow) {
      guard dayKeyNavEnabled else { return .ignored }
      stepDay(-1); return .handled
    }
    .onKeyPress(.rightArrow) {
      guard dayKeyNavEnabled else { return .ignored }
      stepDay(1); return .handled
    }
    // Swipe horizontally to step the viewed day (touch twin of ←/→). iOS only —
    // Mac/iPad keep the keys; a click-drag on the desktop would fight selection.
    #if os(iOS)
    .simultaneousGesture(daySwipe)
    #endif
    // Time-travel picker. Attached to the body (not the toolbar item) so
    // presentation is stable on iOS; gated on `currentDate` so non
    // day-scoped drawers never build it.
    .modifier(TimeTravelPresenter(isPresented: $showingTimeTravel, date: currentDate))
    // Conditional `.searchable` — present only when the destination
    // passes a binding so non-search drawers don't render an empty
    // input. We use a switch over the Optional so SwiftUI's view
    // identity stays stable per branch.
    .modifier(OptionalSearchable(text: searchText, prompt: searchPrompt))
    // Deep-linked section Settings. iOS presents it over the drawer so
    // closing returns the user here; macOS routes to the shared Settings
    // window (see the SectionSettingsLink action above). Septask compiles
    // no SettingsView (its own settings shell is P3 — docs/SEPTASK.md).
    #if os(iOS) && !SEPTASK
    .sheet(isPresented: $showingSettings) {
      SettingsView(initialDestination: .section(sectionKey))
    }
    #endif
    // The section name is the standard inline nav-bar title — plain text in
    // the system's default place, identical on every drawer. Kept inline
    // (not a big editorial heading) so the drawer top stays compact.
    .navigationTitle(resolvedTitle)
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .tint(resolvedAccent)
    // Screen telemetry keyed by the section — internalized here so no drawer
    // hand-passes a `.trackScreen("key")` that always equals `sectionKey`.
    .trackScreen(sectionKey)
    .trackSectionUsage(sectionKey)
    .toolbar {
      // Time travel sits on the LEADING edge; the quick-add "+" stays trailing.
      // `.topBarLeading` is the iOS leading slot; macOS uses `.navigation` (the
      // window-toolbar leading group) — same split the Insights destination uses.
      #if os(iOS)
      let leadingPlacement: ToolbarItemPlacement = .topBarLeading
      #else
      let leadingPlacement: ToolbarItemPlacement = .navigation
      #endif
      if loadState == .loading {
        // Subtle inline activity indicator next to the title slot so
        // background fetches surface without blocking the cached
        // content underneath.
        ToolbarItem(placement: .primaryAction) {
          ProgressView()
            .controlSize(.small)
        }
      }
      // Mode toggle — the sole leading control, present only for dual-mode
      // (Log + Patterns) sections, and only while a single mode is shown. When
      // the drawer is wide enough to show both side-by-side there's nothing to
      // switch, so the toggle drops out. Time travel is no longer a sibling
      // button here — it lives as the footer "previous days" link.
      if let mode, !modeShowsBoth {
        ToolbarItem(placement: leadingPlacement) {
          DrawerModeToggle(mode: mode, storageKey: modeStorageKey ?? sectionKey,
                           accent: resolvedAccent)
        }
      }
      // Quick-add "+" — ONE component (`DrawerActionButton`), one style, one
      // shape, for every section. Lives alone in the trailing primaryAction slot;
      // the system places the prominent glass "+" as a standalone control there.
      if let quickAdd {
        ToolbarItem(placement: .primaryAction) {
          DrawerActionButton(quickAdd: quickAdd, accent: resolvedAccent)
        }
      }
    }
  }
}

/// A drawer's single quick-add affordance — title (for the accessibility label),
/// icon, and the action to run on tap. Declared once at the `SectionDrawer` call
/// site, so each section has exactly one source of truth for its "+". Sections
/// with several quick options point `action` at a chooser SHEET rather than a
/// menu (see NutritionDestinationView / IntakeQuickLogSheet) — `.glassProminent`
/// only *fills* a `Button`, so the single-button form is the only one that reads
/// as the prominent accent circle.
struct DrawerQuickAdd {
  let title: String
  let systemImage: String
  let action: () -> Void

  init(_ title: String, systemImage: String = "plus", action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }
}

/// The drawer's quick-add toolbar control, centralized in ONE component so every
/// "+" is identical: a plain `Button` the system draws as the prominent
/// accent-filled circle via `.glassProminent` (`.tint` washes the glass with the
/// section accent; the style auto-contrasts the glyph to white). Bound to ⌘N.
struct DrawerActionButton: View {
  let quickAdd: DrawerQuickAdd
  let accent: Color

  var body: some View {
    Button { quickAdd.action() } label: {
      Image(systemName: quickAdd.systemImage)
        .accessibilityLabel(quickAdd.title)
    }
    .keyboardShortcut("n", modifiers: .command)
    .buttonStyle(.glassProminent)
    .tint(accent)
  }
}

extension View {
  /// The single owner of a section drawer's *presentation* look. Applied to the
  /// content presented in a sheet, it sets the detents and the translucent
  /// background, and injects the `.glass` surface style so the drawer's cards go
  /// clear to match. iPad/macOS (non-sheet hosts) get sized framing and keep the
  /// default `.solid` surface. Keeping all of this in one modifier is what
  /// prevents the drawer look from drifting between the drawer and its presenter.
  /// `shortInDemo` keeps a content-light section (gut, caffeine, nutrition) at
  /// the medium detent in screenshot builds, where full-height would just be
  /// empty space below the content.
  func sectionDrawerPresentation(shortInDemo: Bool = false) -> some View {
    #if os(iOS)
    self
      // Screenshot/UI-test builds open every drawer full-height so captures show
      // the whole section, not a half-sheet — except content-light ones, which
      // stay medium. Real builds keep the medium↔large resize.
      .presentationDetents(
        DemoSeedMode.isOn ? (shortInDemo ? [.medium] : [.large]) : [.medium, .large])
      .presentationDragIndicator(.visible)
      // Translucent COLOR, not a Material: a floating sheet with background
      // interaction enabled gives a Material no backdrop to blur, so it would
      // render opaque. A color blends by alpha regardless. Interaction-enabled
      // also suppresses the dimming scrim so content shows through.
      .presentationBackground(Color(.systemBackground).opacity(0.55))
      .presentationBackgroundInteraction(.enabled(upThrough: .large))
      .environment(\.drawerSurfaceStyle, .glass)
    #else
    self
      .frame(width: 560, height: 600)
    #endif
  }
}

extension View {
  /// macOS sheets size to their content's *ideal* height, and List/Form/
  /// NavigationStack-backed content has none — the sheet collapses to zero.
  /// Apply this to any sheet content compiled for macOS that isn't already
  /// framed (or wrapped in `sectionDrawerPresentation()`); it's a no-op on iOS,
  /// where detents own the sheet size.
  func macSheetFrame(width: CGFloat = 560, height: CGFloat = 600) -> some View {
    #if os(macOS)
    return frame(width: width, height: height)
    #else
    return self
    #endif
  }
}

extension View {
  /// Standard section data lifecycle in one wire. `perform` runs:
  ///   • on appear,
  ///   • whenever `value` changes (e.g. the viewing date) — `.task(id:)` both
  ///     starts on appear and restarts on change, replacing a separate
  ///     `.onChange(of:)`, and cancels any in-flight load on a date switch,
  ///   • on `.septenaDataChanged` when `onDataChange` is true (log drawers that
  ///     should refresh after a write elsewhere). Pass the view's section
  ///     key(s) via `forSections` so scoped posts from *other* sections skip
  ///     the reload; nil reloads on every data change (pre-scoping behavior).
  ///   • `mirrorReload` — optional full mirror re-read (e.g. `NextItemsModel.load()`)
  ///     that runs only on inbound CloudKit batches. Scoped local writes already
  ///     updated the UI optimistically; re-reading the mirror mid-settle would
  ///     cancel linger/fade beats. Drawers whose `perform` already re-reads the
  ///     mirror (nutrition, mood, …) can omit this.
  /// Collapses the `.task` + `.onChange` + `.onReceive` trio every drawer
  /// repeated. Accepts an `async` closure so both sync `reload()` and
  /// `paintFromCache(); await load()` shapes fit.
  func sectionReload<V: Equatable>(
    on value: V,
    onDataChange: Bool = false,
    forSections: Set<String>? = nil,
    mirrorReload: (() async -> Void)? = nil,
    perform: @escaping () async -> Void
  ) -> some View {
    self
      .task(id: value) { await perform() }
      .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
        if onDataChange, note.affectsAnySection(of: forSections) {
          Task { @MainActor in
            if note.isCloudKitBatch { await mirrorReload?() }
            await perform()
          }
        }
      }
  }

  /// Lifecycle variant for drawers with no observed value (no time travel).
  func sectionReload(
    onDataChange: Bool = false,
    forSections: Set<String>? = nil,
    mirrorReload: (() async -> Void)? = nil,
    perform: @escaping () async -> Void
  ) -> some View {
    sectionReload(on: 0, onDataChange: onDataChange, forSections: forSections,
                  mirrorReload: mirrorReload, perform: perform)
  }
}

extension SectionDrawer {
  /// Standardized failed-state placeholder. Renders as a centered
  /// `ContentUnavailableView` with the destination's error message and
  /// a "Try again" button bound to `onRetry`. Drops in cleanly inside
  /// the drawer's LazyVStack so the goals strip + nav chrome stay
  /// untouched while the body recovers.
  @ViewBuilder
  fileprivate func failedView(_ message: String) -> some View {
    ContentUnavailableView {
      Label("Couldn't load", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      if let onRetry {
        Button("Try again") { onRetry() }
          .buttonStyle(.borderedProminent)
      }
    }
  }
}

#Preview("DrawerSection — padding modes") {
  ScrollView {
    VStack(spacing: 24) {
      DrawerSection("Standard") {
        VStack(alignment: .leading, spacing: 4) {
          Text("Free-form content").font(.septenaCardTitle)
          Text("Inset 14h / 12v from the rounded edge.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      DrawerSection("Tight (charts)", padding: .tight) {
        Rectangle().fill(.blue.opacity(0.35)).frame(height: 80)
      }
      DrawerSection("None (LogRow rows)", padding: .none) {
        ForEach(0..<3) { i in
          LogRow(title: "Row \(i + 1)", trailing: "0\(i):0\(i)")
        }
      }
    }
    .padding()
  }
  .background(Theme.groupedBackground)
}

/// Applies `.searchable` only when a binding is provided. SwiftUI
/// modifiers can't be applied conditionally inline without rebuilding
/// view identity on every render; this modifier branches once at
/// composition time and stays stable thereafter.
private struct OptionalSearchable: ViewModifier {
  let text: Binding<String>?
  let prompt: String

  func body(content: Content) -> some View {
    if let text {
      content.searchable(text: text, prompt: prompt)
    } else {
      content
    }
  }
}

/// Presents the `TimeTravelSheet` only when the drawer is day-scoped.
/// Branches once at composition time (like `OptionalSearchable`) so view
/// identity stays stable and non-dated drawers never build the sheet.
private struct TimeTravelPresenter: ViewModifier {
  @Binding var isPresented: Bool
  let date: Binding<String>?

  func body(content: Content) -> some View {
    if let date {
      content.sheet(isPresented: $isPresented) {
        TimeTravelSheet(date: date)
          .presentationDetents([.height(TimeTravelSheet.sheetHeight), .large])
          .presentationDragIndicator(.visible)
      }
    } else {
      content
    }
  }
}

/// Slim "you're viewing a past day" pill rendered under the drawer title
/// while time-traveling. Tapping reopens the picker. Mirrors the muted
/// capsule look of the former `DrawerDateStrip` date label.
private struct TimeTravelPill: View {
  /// The viewed day as YYYY-MM-DD.
  let date: String
  let onTap: () -> Void

  private static let isoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.calendar = Calendar(identifier: .iso8601)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    return f
  }()

  private var label: String {
    let cal = Calendar.current
    let day = Self.isoFormatter.date(from: date) ?? .now
    if cal.isDateInYesterday(day) { return "Viewing Yesterday" }
    let days = cal.dateComponents([.day], from: day, to: .now).day ?? 0
    let f = DateFormatter()
    f.dateFormat = days < 7 ? "EEEE" : "EEEE · MMM d"
    return "Viewing \(f.string(from: day))"
  }

  var body: some View {
    HStack {
      Button(action: onTap) {
        HStack(spacing: 6) {
          Image(systemName: "calendar.badge.clock")
            .font(.caption)
          Text(label)
            .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(Theme.inkPrimary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 6)
        .glassCapsule()
      }
      .buttonStyle(.plain)
      Spacer()
    }
  }
}

/// Quiet day-travel link at the bottom of a day-scoped drawer, just above the
/// "Customize <Section>" link. This is where the former top-left calendar button
/// moved to, freeing the top-left edge for the Log/Patterns toggle alone. On
/// today it opens the `TimeTravelSheet` picker ("View previous days"); while
/// viewing a past day it flips to a "Back to today" shortcut. Tertiary,
/// footnote-weight, centered, to match the settings link below it.
private struct DrawerHistoryLink: View {
  let isTimeTraveling: Bool
  let onPrevious: () -> Void
  let onToday: () -> Void

  var body: some View {
    Button(action: isTimeTraveling ? onToday : onPrevious) {
      HStack(spacing: 5) {
        Image(systemName: isTimeTraveling ? "arrow.uturn.backward" : "calendar")
        Text(isTimeTraveling ? "Back to today" : "View previous days")
      }
      .font(.footnote)
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// Subtle "Customize <Section>" link at the very bottom of every section
/// drawer. Tapping deep-links into this section's Settings pane (presented
/// as a sheet over the drawer, so closing it returns here). Tertiary,
/// footnote-weight, centered — quiet enough to stay clear of the logging
/// content above it. The drawer's LazyVStack supplies the gap above.
private struct SectionSettingsLink: View {
  let sectionTitle: String
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 5) {
        Image(systemName: "gearshape")
        Text("Customize \(sectionTitle)")
      }
      .font(.footnote)
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Adaptive detail presentation
//
// One primitive for "open a record's detail / edit form" that resolves to
// the right idiom per surface:
//
//   • compact width (iPhone)        → modal `.sheet` (unchanged native idiom)
//   • regular width (iPad / macOS)  → docked `.inspector` trailing pane, so
//     the list/log stays visible and editing a record never covers the
//     context the user was just looking at.
//
// Convert a section's `.sheet(item:)` / `.sheet(isPresented:)` to the
// matching `.adaptiveDetail(...)` and it inherits coherent behavior on all
// three surfaces — no per-section size-class branching.
//
// Dismissal: a docked inspector is NOT a "presentation," so the inner
// form's `@Environment(\.dismiss)` is a no-op there. The primitive injects
// `\.adaptiveDetailClose`; edit forms should close through that (it falls
// back to `dismiss()` when absent, so a form still works if presented as a
// plain sheet elsewhere). See `EditGutEntrySheet` for the reference adoption.

private struct AdaptiveDetailCloseKey: EnvironmentKey {
  static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
  /// Closes the enclosing adaptive detail presentation (sheet or docked
  /// inspector). `nil` when the view isn't hosted by `.adaptiveDetail` —
  /// callers should fall back to `@Environment(\.dismiss)`.
  var adaptiveDetailClose: (() -> Void)? {
    get { self[AdaptiveDetailCloseKey.self] }
    set { self[AdaptiveDetailCloseKey.self] = newValue }
  }
}

extension View {
  /// Item-driven adaptive detail. Drop-in replacement for `.sheet(item:)`.
  func adaptiveDetail<Item: Identifiable, DetailContent: View>(
    item: Binding<Item?>,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping (Item) -> DetailContent
  ) -> some View {
    modifier(AdaptiveDetailItem(item: item, onDismiss: onDismiss, detail: content))
  }

  /// Flag-driven adaptive detail. Drop-in replacement for
  /// `.sheet(isPresented:)`.
  func adaptiveDetail<DetailContent: View>(
    isPresented: Binding<Bool>,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> DetailContent
  ) -> some View {
    modifier(AdaptiveDetailFlag(isPresented: isPresented, onDismiss: onDismiss, detail: content))
  }

  /// Standard edit/create detail pair for a log drawer. Both surfaces use the
  /// SAME form, differing only by whether an item is present (edit) or `nil`
  /// (create) — so the form is written once and `content` receives an optional.
  /// Collapses the two near-identical `.adaptiveDetail` calls every log drawer
  /// repeated into one.
  func drawerDetail<Item: Identifiable, DetailContent: View>(
    edit: Binding<Item?>,
    create: Binding<Bool>,
    @ViewBuilder content: @escaping (Item?) -> DetailContent
  ) -> some View {
    adaptiveDetail(item: edit) { content($0) }
      .adaptiveDetail(isPresented: create) { content(nil) }
  }
}

// MARK: - AdaptiveEditScaffold
//
// The standard chrome for an edit/create form hosted by `.adaptiveDetail`.
// Absorbs the two cross-surface rules so no individual form repeats them:
//
//   1. Close through `\.adaptiveDetailClose` (docked inspector) with a
//      `dismiss()` fallback (plain sheet). Save closes after the action runs.
//   2. Pick chrome by host: a docked inspector gets an inline header (a
//      nested NavigationStack would double-render its toolbar in the macOS
//      title bar); a bottom sheet gets a NavigationStack + nav-bar toolbar.
//
// A form supplies only what's genuinely its own — a title, the save action,
// optional labels / save-enabled flag — and its fields via the trailing
// closure. There are no per-form layout constants to copy.
//
//   var body: some View {
//     AdaptiveEditScaffold(title: navTitle, onSave: save) {
//       Form { … }.onAppear { seed() }
//     }
//   }
struct AdaptiveEditScaffold<FormContent: View>: View {
  let title: String
  /// Confirmation label. Defaults to "Save"; pass "Add", "Done", etc.
  var saveTitle: String = "Save"
  var cancelTitle: String = "Cancel"
  /// Hides the confirmation control entirely. Use when the close control already
  /// persists (autosave-on-close) so a separate Save would be redundant — the
  /// left control alone ("Done") both saves and closes.
  var showsSave: Bool = true
  /// Tints just the Cancel/Save controls. The form content stays neutral; pass
  /// a section color when you want the confirm/cancel affordances accented
  /// without coloring the whole form.
  var accent: Color? = nil
  /// Disables the confirmation control (e.g. while a required field is
  /// empty). The form owns the validation; the scaffold owns the affordance.
  var canSave: Bool = true
  /// Opt-in: there are unsaved changes. When an `onDiscard` is supplied, this
  /// turns Cancel into a guarded discard — Cancel/Esc on a dirty form prompts
  /// before dropping the work, and the interactive swipe-to-dismiss is blocked
  /// so an accidental gesture can never discard. Forms without `onDiscard` (the
  /// autosave-on-close ones) ignore this and Cancel just closes, as before.
  var isDirty: Bool = false
  /// Prompt shown in the discard confirmation (e.g. "Discard new task?").
  var discardTitle: String = "Discard changes?"
  /// The save action. The scaffold runs it, then closes — forms must NOT
  /// call dismiss/close themselves (that's what produced the double-close
  /// and dismiss-no-op bugs the inspector exposed).
  let onSave: () -> Void
  /// Opt-in discard action: run when the user explicitly confirms Cancel →
  /// Discard. Supply it to get the dirty-aware Cancel guard above (the form
  /// uses it to suppress any autosave-on-close so the draft is truly dropped).
  /// When nil, Cancel is a plain close.
  var onDiscard: (() -> Void)? = nil
  /// Optional trailing control in the header (e.g. a ⋯ overflow menu of
  /// contextual actions). Sits where Save would be when `showsSave` is false.
  var trailing: AnyView? = nil
  @ViewBuilder var content: () -> FormContent

  @Environment(\.dismiss) private var dismiss
  @Environment(\.adaptiveDetailClose) private var adaptiveClose
  @State private var showDiscardConfirm = false

  private var isInspector: Bool { adaptiveClose != nil }
  private func close() { (adaptiveClose ?? { dismiss() })() }
  private func confirm() { onSave(); close() }

  /// The leading control's action. Without discard semantics it's a plain close
  /// (the autosave-on-close forms persist via their own `.onDisappear`). With an
  /// `onDiscard`, a dirty form prompts first; a clean one just closes.
  private func requestCancel() {
    guard onDiscard != nil else { close(); return }
    if isDirty { showDiscardConfirm = true } else { discard() }
  }
  private func discard() { onDiscard?(); close() }

  var body: some View {
    Group {
      if isInspector {
        content()
          .safeAreaInset(edge: .top, spacing: 0) {
            AdaptiveEditHeader(
              title: title,
              cancelTitle: cancelTitle,
              saveTitle: saveTitle,
              showsSave: showsSave,
              canSave: canSave,
              accent: accent,
              onCancel: requestCancel,
              onSave: confirm,
              trailing: trailing
            )
          }
      } else {
        NavigationStack {
          content()
            // A default-styled macOS `Form` reports no flexible height, so in
            // this sheet branch it collapses to no apparent height. Grouped (the
            // app's house style, and already the iOS Form default) scrolls and
            // fills the sheet. Centralized here so no individual form repeats it.
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button(cancelTitle, action: requestCancel)
                  .tint(accent)
                  .keyboardShortcut(.cancelAction) // Esc
              }
              if showsSave {
                ToolbarItem(placement: .confirmationAction) {
                  Button(saveTitle, action: confirm)
                    .tint(accent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction) // Return / ⌘Return
                }
              }
              if let trailing {
                ToolbarItem(placement: .primaryAction) { trailing }
              }
            }
        }
      }
    }
    // A dirty form with discard semantics can't be swiped/clicked away — the
    // only exits are Save (commit) or Cancel (confirmed discard), so an
    // accidental gesture can never drop the work.
    .interactiveDismissDisabled(onDiscard != nil && isDirty)
    .confirmationDialog(discardTitle, isPresented: $showDiscardConfirm, titleVisibility: .visible) {
      Button("Discard", role: .destructive, action: discard)
      Button("Keep Editing", role: .cancel) {}
    }
  }
}

/// The inline header used by `AdaptiveEditScaffold` in its docked-inspector
/// mode: Cancel · title · Save, on a material bar. Kept private — forms only
/// ever go through the scaffold.
private struct AdaptiveEditHeader: View {
  let title: String
  let cancelTitle: String
  let saveTitle: String
  var showsSave: Bool = true
  let canSave: Bool
  var accent: Color? = nil
  let onCancel: () -> Void
  let onSave: () -> Void
  var trailing: AnyView? = nil

  var body: some View {
    HStack(spacing: 12) {
      Button(cancelTitle, action: onCancel)
        .keyboardShortcut(.cancelAction) // Esc
      Spacer()
      Text(title).font(.headline)
      Spacer()
      if showsSave {
        Button(saveTitle, action: onSave)
          .fontWeight(.semibold)
          .disabled(!canSave)
          .keyboardShortcut(.defaultAction) // Return / ⌘Return
      }
      if let trailing { trailing }
    }
    .tint(accent)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }
}

private struct AdaptiveDetailItem<Item: Identifiable, DetailContent: View>: ViewModifier {
  @Binding var item: Item?
  let onDismiss: (() -> Void)?
  @ViewBuilder let detail: (Item) -> DetailContent

  // Detail content docks as an inspector exactly where sections push as a
  // full pane (regular width / macOS), so it shares the one push-navigation
  // rule rather than recomputing from the size class. On compact the section
  // is a bottom sheet, so edits stay sheets too.
  @Environment(\.usesPushNavigation) private var useInspector

  func body(content: Content) -> some View {
    if useInspector {
      content.inspector(isPresented: presented) {
        // `item` may briefly be nil during dismissal animation; guard so
        // the inspector empties cleanly instead of force-unwrapping.
        if let item {
          detail(item)
            .environment(\.adaptiveDetailClose, close)
            .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
      }
    } else {
      content.sheet(item: $item, onDismiss: onDismiss, content: detail)
    }
  }

  /// Bridges the optional item to the inspector's `isPresented` binding.
  /// Clearing it (swipe-away / toolbar toggle) routes through `close` so
  /// `onDismiss` fires exactly once on every dismissal path.
  private var presented: Binding<Bool> {
    Binding(get: { item != nil }, set: { if !$0 { close() } })
  }

  private func close() {
    item = nil
    onDismiss?()
  }
}

private struct AdaptiveDetailFlag<DetailContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  let onDismiss: (() -> Void)?
  @ViewBuilder let detail: () -> DetailContent

  @Environment(\.usesPushNavigation) private var useInspector

  func body(content: Content) -> some View {
    if useInspector {
      content
        .inspector(isPresented: $isPresented) {
          detail()
            .environment(\.adaptiveDetailClose, close)
            .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
        // Fire onDismiss when the inspector is toggled shut by the system.
        .onChange(of: isPresented) { _, now in if !now { onDismiss?() } }
    } else {
      content.sheet(isPresented: $isPresented, onDismiss: onDismiss, content: detail)
    }
  }

  private func close() {
    isPresented = false
  }
}

// DrawerSection — titled, rounded, grouped block. Visual analogue of an
// insetGrouped List `Section("Title")`: secondary-grouped fill, rounded
// corners, an uppercase footnote header. Content is laid out as a VStack;
// inner views render at their natural height (no row insets to fight).

/// How a `DrawerSection` should inset its content from the rounded
/// card's edges. Most free-form content wants the `.standard` h14/v12
/// padding; row-stacks built from `LogEntryRow` (which carries its own
/// padding) use `.none`; charts use `.tight`.
enum DrawerPadding {
  case standard, tight, none
}

/// The single placeholder for an empty day-log, so every section's empty state
/// reads identically: "Nothing logged yet." while viewing today, "Nothing logged
/// on this day." while reviewing a past day. Carries the row-aligned 14/12 inset
/// so it drops straight into a `DrawerSection(padding: .none)` exactly where the
/// log rows would sit — one wording, one style, every section.
struct DrawerEmptyLogLine: View {
  /// True when the drawer is showing today (vs. a past day via time travel).
  let isToday: Bool

  var body: some View {
    Text(isToday ? "Nothing logged yet." : "Nothing logged on this day.")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
  }
}

private struct RowHInsetKey: EnvironmentKey {
  static let defaultValue: CGFloat = Theme.hPadding
}

private struct RowVInsetKey: EnvironmentKey {
  static let defaultValue: CGFloat = Theme.rowVPadding
}

extension EnvironmentValues {
  /// Horizontal inset a checkable / log row applies between its own edge and
  /// its content. Defaults to `Theme.hPadding` (20pt) — the value a row needs
  /// when it's the only frame around its content. A `DrawerSection` card lowers
  /// it to `Theme.Spacing.xl`: the card already sits 20pt off the screen edge,
  /// so the full 20pt row inset would stack into a visible double margin. At the
  /// card's value the row content lines up with the section title instead.
  var rowHInset: CGFloat {
    get { self[RowHInsetKey.self] }
    set { self[RowHInsetKey.self] = newValue }
  }

  /// Vertical padding a checkable / task row applies top and bottom. Defaults to
  /// `Theme.rowVPadding` — the airier rhythm the drawer's log/task rows keep.
  /// The deep task-list surfaces override it to `Theme.rowVPaddingTight` for a
  /// denser list without affecting drawer density.
  var rowVInset: CGFloat {
    get { self[RowVInsetKey.self] }
    set { self[RowVInsetKey.self] = newValue }
  }
}

struct DrawerSection<Content: View>: View {
  let title: String?
  let spacing: CGFloat
  let padding: DrawerPadding
  @ViewBuilder var content: () -> Content

  init(_ title: String? = nil,
       spacing: CGFloat = Theme.Spacing.xs,
       padding: DrawerPadding = .standard,
       @ViewBuilder content: @escaping () -> Content) {
    // Default xs gap between rows so adjacent items breathe inside the
    // drawer card. Pass `spacing: 0` for tightly-packed stacks (charts,
    // dense stat grids) where the rounded card itself is the only frame
    // the contents need.
    self.title = title
    self.spacing = spacing
    self.padding = padding
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      if let title, !title.isEmpty {
        // Title-case subheadline with a soft secondary tint — matches
        // the look of the original Caffeine destination's section labels.
        Text(title)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.horizontal, Theme.Spacing.xl)
      }
      paddedStack
        // Rows dropped into this card (DrawerPadding.none) read this for their
        // own horizontal inset so they align with the title above instead of
        // stacking a second 20pt margin inside the already-inset card.
        .environment(\.rowHInset, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Surface from the injected style — opaque card on a solid host, a
        // floating Liquid Glass panel on the glass (translucent-sheet) host so
        // the card lifts off the drawer instead of dissolving into it. One place
        // owns the decision (`drawerCardSurface`).
        .drawerCardSurface()
    }
  }

  @ViewBuilder
  private var paddedStack: some View {
    switch padding {
    case .standard:
      VStack(spacing: spacing) { content() }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    case .tight:
      VStack(spacing: spacing) { content() }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    case .none:
      // Grouped-list rows: no inter-row gap, an accent hairline between each
      // adjacent pair. The separators are interleaved through `_VariadicView`
      // so every `padding: .none` call site keeps its plain `ForEach { row }`
      // and gains separators here, in one place. A lone child (e.g. an
      // empty-state label) gets none.
      VStack(spacing: 0) {
        _VariadicView.Tree(SeparatedRows()) { content() }
      }
    }
  }
}

/// `_VariadicView` root that drops a `DrawerRowSeparator` between each pair of
/// adjacent rows in a `DrawerSection(padding: .none)` card — the grouped-list
/// separator, themed to the section accent. Working at the variadic level is
/// what lets the ~two-dozen call sites stay a plain `ForEach { row }` while the
/// separators live in exactly one place (§8 centralization).
private struct SeparatedRows: _VariadicView.MultiViewRoot {
  func body(children: _VariadicView.Children) -> some View {
    let lastID = children.last?.id
    ForEach(children) { child in
      child
      if child.id != lastID {
        DrawerRowSeparator()
      }
    }
  }
}

/// Hairline row separator: a true 1px system separator inset to align with the
/// row title column, full-bleed to the card's trailing edge — the standard
/// inset-grouped look. Neutral by design; accent stays off the drawer chrome.
/// Reads `rowHInset` from the environment the enclosing `DrawerSection` set.
private struct DrawerRowSeparator: View {
  @Environment(\.rowHInset) private var inset
  @Environment(\.displayScale) private var scale

  var body: some View {
    Theme.divider
      .frame(height: 1 / max(scale, 1))
      .padding(.leading, inset)
  }
}

// MARK: - Dual-mode side-by-side

/// Preference a dual-mode body raises once it has split Log + Patterns
/// side-by-side on a wide pane, so `SectionDrawer` can hide the now-meaningless
/// Log/Patterns toggle and keep the day controls visible. Default false —
/// single-mode drawers and narrow dual drawers never raise it.
private struct DrawerSideBySideKey: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

/// The dual-mode (Log + Patterns) body, with one width-driven rule shared by
/// every section so they can't drift:
///   • **Narrow** (compact iPhone, a slide-over, a small window): show only the
///     active `mode`, flowed through `DrawerColumns` exactly as a single-mode
///     drawer — so a wide-enough single mode still goes two-up. The toolbar
///     toggle flips which one is shown. This path is byte-for-byte today's
///     behavior.
///   • **Wide enough for both** (an unfolded foldable iPhone, iPad at regular
///     width, a wide Mac window): drop the mode entirely and lay Log on the
///     left, Patterns on the right, each a single column. The toggle disappears.
///
/// The decision is measured from the *actual* available width (not the size
/// class) so it tracks live window resizing and unfold, and it's raised via
/// `DrawerSideBySideKey` so the drawer chrome reads the same single source
/// rather than recomputing the threshold a second time.
struct DrawerModeColumns<Log: View, Patterns: View>: View {
  @Binding var mode: DrawerMode
  /// Gap between the two columns and between stacked cards. Matches the drawer's
  /// between-section spacing so the split reads as one rhythm.
  var spacing: CGFloat = Theme.Spacing.xxl
  /// Minimum width each half needs before the drawer splits. Matches
  /// `DrawerColumns.minColumnWidth` so the split kicks in just past the point a
  /// single mode would itself have gone two-up — the next step in the same
  /// width progression rather than a competing threshold.
  var minHalfWidth: CGFloat = 330
  @ViewBuilder var log: () -> Log
  @ViewBuilder var patterns: () -> Patterns

  @State private var sideBySide = false

  private var splitThreshold: CGFloat { minHalfWidth * 2 + spacing }

  var body: some View {
    layout
      // Measured from the ACTUAL available width, not the presentation mode —
      // so a wide bottom sheet on a landscape iPhone splits Log + Patterns
      // side-by-side just like the iPad pushed pane, while a narrow portrait
      // sheet stays single-mode with the toggle.
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.width
      } action: { width in
        let wide = width >= splitThreshold
        if wide != sideBySide { sideBySide = wide }
      }
      .preference(key: DrawerSideBySideKey.self, value: sideBySide)
  }

  @ViewBuilder
  private var layout: some View {
    if sideBySide {
      HStack(alignment: .top, spacing: spacing) {
        column { log() }
        column { patterns() }
      }
    } else {
      DrawerColumns(spacing: spacing) {
        switch mode {
        case .log: log()
        case .patterns: patterns()
        }
      }
    }
  }

  /// One half of the side-by-side split — a single column that fills its share
  /// of the width and top-aligns so the two halves start level.
  private func column<C: View>(@ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: spacing) { content() }
      .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

extension SectionDrawer {
  /// Dual-mode (Log + Patterns) drawer. Instead of switching on `mode` itself,
  /// the section hands its two halves as `log:` / `patterns:` builders and the
  /// drawer owns the wide/narrow rule: one mode at a time on a narrow pane
  /// (toggled), both side-by-side on a wide one. This is the single place that
  /// rule lives, so every dual section behaves identically. `mode` is
  /// non-optional here — supplying it is what makes a drawer dual.
  init<Log: View, Patterns: View>(
    sectionKey: String,
    title: String? = nil,
    accent: Color? = nil,
    quickAdd: DrawerQuickAdd? = nil,
    loadState: DrawerLoadState = .idle,
    onRetry: (() -> Void)? = nil,
    currentDate: Binding<String>? = nil,
    mode: Binding<DrawerMode>,
    modeStorageKey: String? = nil,
    showsSettingsLink: Bool = true,
    settingsAction: (() -> Void)? = nil,
    @ViewBuilder log: @escaping () -> Log,
    @ViewBuilder patterns: @escaping () -> Patterns
  ) where Content == DrawerModeColumns<Log, Patterns> {
    self.init(
      sectionKey: sectionKey,
      title: title,
      accent: accent,
      quickAdd: quickAdd,
      loadState: loadState,
      onRetry: onRetry,
      currentDate: currentDate,
      mode: mode,
      modeStorageKey: modeStorageKey,
      showsSettingsLink: showsSettingsLink,
      settingsAction: settingsAction,
      // The dual body runs its own column layout (single mode → masonry; both
      // → two halves), so the drawer hands it the full content width rather
      // than wrapping it in the standard `DrawerColumns` masonry.
      usesColumns: false
    ) {
      DrawerModeColumns(mode: mode, log: log, patterns: patterns)
    }
  }
}

/// Lays the drawer's section cards out in one column on a narrow pane and up
/// to two on a wide one (iPad / Mac). On compact width (iPhone) it stays the
/// original lazy single column so the phone layout is byte-for-byte unchanged;
/// on regular width it hands the cards to `MasonryLayout`, which itself decides
/// 1-vs-2 columns from the *actual* available width. That width gate — not the
/// size class alone — is what keeps the narrow 560pt Mac sheet and iPad
/// slide-over single-column while a full-width pane goes two-up.
struct DrawerColumns<Content: View>: View {
  /// Gap between stacked cards and between the two columns. Matches the
  /// drawer's between-section spacing so the board reads as one rhythm.
  var spacing: CGFloat
  /// Cards narrower than this never get a second column — below `2 × min +
  /// spacing` of available width the layout collapses to a single column.
  var minColumnWidth: CGFloat = 330
  @ViewBuilder var content: () -> Content

  #if !os(macOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  var body: some View {
    // Width-driven (via MasonryLayout), gated only by horizontal size class so
    // a portrait iPhone stays a single lazy column. A landscape iPhone reports
    // regular width, so its (now bottom-sheet) drawer still gets the masonry
    // board — the same 1-vs-2 column decision the iPad pane makes from width.
    #if os(macOS)
    masonry
    #else
    if hSize == .regular {
      masonry
    } else {
      LazyVStack(spacing: spacing) { content() }
    }
    #endif
  }

  private var masonry: some View {
    MasonryLayout(spacing: spacing, minColumnWidth: minColumnWidth, maxColumns: 2) {
      content()
    }
  }
}

/// A balanced masonry `Layout`: each subview is placed into the currently
/// shortest column, so variable-height cards pack tightly instead of leaving
/// the per-row gaps a `LazyVGrid` would. The column count is derived from the
/// proposed width (`minColumnWidth`, capped at `maxColumns`), so the same
/// layout renders one column on a narrow pane and two on a wide one without a
/// size-class branch at the call site.
struct MasonryLayout: Layout {
  var spacing: CGFloat
  var minColumnWidth: CGFloat
  var maxColumns: Int

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
    let width = proposal.replacingUnspecifiedDimensions().width
    let cols = columnCount(for: width)
    let colWidth = columnWidth(for: width, columns: cols)
    var heights = Array(repeating: CGFloat.zero, count: cols)
    for subview in subviews {
      let h = subview.sizeThatFits(.init(width: colWidth, height: nil)).height
      let c = shortestIndex(heights)
      heights[c] += h + spacing
    }
    // Each column accumulated one trailing `spacing` too many; drop it.
    let tallest = heights.map { max($0 - spacing, 0) }.max() ?? 0
    return CGSize(width: width, height: tallest)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
    let cols = columnCount(for: bounds.width)
    let colWidth = columnWidth(for: bounds.width, columns: cols)
    var heights = Array(repeating: CGFloat.zero, count: cols)
    for subview in subviews {
      let size = subview.sizeThatFits(.init(width: colWidth, height: nil))
      let c = shortestIndex(heights)
      let x = bounds.minX + CGFloat(c) * (colWidth + spacing)
      let y = bounds.minY + heights[c]
      subview.place(at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: .init(width: colWidth, height: size.height))
      heights[c] += size.height + spacing
    }
  }

  private func columnCount(for width: CGFloat) -> Int {
    // SwiftUI can propose an infinite width (e.g. inside a ScrollView), which
    // `width > 0` happily passes — `Int(floor(.infinity))` then traps. Bail out
    // for any non-finite width, and guard the divisor against zero.
    guard width.isFinite, width > 0 else { return 1 }
    let denominator = minColumnWidth + spacing
    guard denominator > 0 else { return 1 }
    let fit = Int(floor((width + spacing) / denominator))
    return max(1, min(maxColumns, fit))
  }

  private func columnWidth(for width: CGFloat, columns: Int) -> CGFloat {
    let n = CGFloat(max(columns, 1))
    return (width - spacing * (n - 1)) / n
  }

  private func shortestIndex(_ heights: [CGFloat]) -> Int {
    var best = 0
    for i in heights.indices where heights[i] < heights[best] { best = i }
    return best
  }
}
