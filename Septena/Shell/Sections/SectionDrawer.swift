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
/// - `.glass` — clear background + clear cards so content sits directly on a
///   translucent presentation (the iPhone sheet). Injected by
///   `sectionDrawerPresentation()`, never set by hand in a destination view.
enum DrawerSurfaceStyle {
  case solid
  case glass

  /// Fill for a card surface (`DrawerSection`, `StatTile`).
  var cardFill: Color {
    switch self {
    case .solid: return Theme.secondaryGroupedBackground
    case .glass: return .clear
    }
  }

  /// Fill behind the drawer's scroll content.
  var scrollFill: Color {
    switch self {
    case .solid: return Theme.groupedBackground
    case .glass: return .clear
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
  /// Invoked with the tapped `LogAction.id` when the drawer's "+"
  /// affordance fires. Required for + to appear — if `nil`, no button
  /// is rendered even if the plugin declares `logActions`.
  var onLog: ((String) -> Void)? = nil
  /// Dynamic, destination-supplied quick-log actions rendered *above* the
  /// plugin's static `logActions` in the "+" menu — e.g. a smart
  /// "Repeat: <bean>" or "Continue · Hit N" row that depends on the current
  /// day's entries. Dispatched through the same `onLog(id)`. Empty by default.
  var leadingLogActions: [LogAction] = []
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
  /// Whether to render the subtle "Customize <Section>" footer that
  /// deep-links into this section's Settings pane. Default on; the footer
  /// also self-hides for utility drawers (empty `title` or a `sectionKey`
  /// with no `SectionManifest`) and while time-traveling.
  var showsSettingsLink: Bool = true
  @ViewBuilder var content: () -> Content

  @Environment(SectionTheme.self) private var theme
  /// Solid (default) vs glass surfaces, injected by the presentation host
  /// (`sectionDrawerPresentation()`) so the iPhone sheet reads `.glass` while
  /// the iPad/macOS pane stays `.solid`.
  @Environment(\.drawerSurfaceStyle) private var surfaceStyle

  /// Whether the goals strip is currently revealed. Collapsed by default —
  /// the goals live behind the `target` toolbar toggle and appear on cue,
  /// so the daily logging content owns the top of the drawer.
  @State private var goalsExpanded = false

  /// Whether the time-travel date picker sheet is open. The picker lives
  /// behind a calendar toolbar button (mirroring the goals + log buttons)
  /// rather than an always-visible strip, so today's logging owns the top
  /// of the drawer.
  @State private var showingTimeTravel = false

  /// Whether the deep-linked Settings sheet (this section's pane) is open.
  /// Presented over the drawer so closing it returns the user here.
  @State private var showingSettings = false

  private var resolvedAccent: Color {
    accent ?? theme.color(for: sectionKey)
  }

  /// Title shown in the nav bar. Falls back to the manifest's default label so
  /// call sites can omit `title:` for any catalogued section.
  private var resolvedTitle: String {
    title ?? SectionManifest.byKey[sectionKey]?.defaultLabel ?? ""
  }

  private var actions: [LogAction] {
    leadingLogActions + (SectionRegistry.plugin(forKey: sectionKey)?.logActions ?? [])
  }

  /// True when the destination has a date strip pointing at a past day.
  /// Hides the goals strip and signals to destinations (via the shared
  /// `SeptenaDate.today` comparison they can do themselves) that
  /// histograms / heatmaps should also be hidden — past days are a
  /// read-only log review, not a dashboard.
  private var isTimeTraveling: Bool {
    guard let currentDate else { return false }
    return currentDate.wrappedValue != SeptenaDate.today
  }

  var body: some View {
    ScrollView {
      // Spacing/margins tuned to match insetGrouped List: ~20pt screen
      // inset and ~28pt between sections so the page breathes the same
      // way the old List did.
      // The chrome (time-travel pill, goals strip, settings footer, failure
      // state) stays full-width; only the destination's section cards flow
      // into columns via `DrawerColumns`. A plain VStack here — the lazy,
      // column-aware stacking now lives inside `DrawerColumns`.
      VStack(spacing: Theme.Spacing.xxl) {
        // While viewing a past day, surface a slim pill under the title so
        // the time-travel context is never invisible — tap it to reopen the
        // picker or jump back to today. On today the drawer stays clean and
        // the calendar lives only in the toolbar.
        if isTimeTraveling, let currentDate {
          TimeTravelPill(date: currentDate.wrappedValue) { showingTimeTravel = true }
        }
        if !isTimeTraveling && goalsExpanded {
          SectionGoalsStrip(sectionKey: sectionKey)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        if case .failed(let message) = loadState {
          failedView(message)
        } else {
          // On a regular-width pane (iPad / Mac) the section cards spread
          // across up to two columns; on iPhone (and any narrow pane) they
          // stay a single lazy column, exactly as before.
          DrawerColumns(spacing: Theme.Spacing.xxl) {
            content()
          }
          if showsSettingsLink, !isTimeTraveling,
             !resolvedTitle.isEmpty, SectionManifest.byKey[sectionKey] != nil {
            SectionSettingsLink(sectionTitle: resolvedTitle) { showingSettings = true }
          }
        }
      }
      .padding(.horizontal, Theme.pageGutter)
      .padding(.top, Theme.Spacing.sm)
      .padding(.bottom, 24)
    }
    // Surface fill driven by the injected style: opaque grouped background on
    // a solid host, clear on the glass (translucent-sheet) host.
    .background(surfaceStyle.scrollFill)
    // Time-travel picker. Attached to the body (not the toolbar item) so
    // presentation is stable on iOS; gated on `currentDate` so non
    // day-scoped drawers never build it.
    .modifier(TimeTravelPresenter(isPresented: $showingTimeTravel, date: currentDate))
    // Conditional `.searchable` — present only when the destination
    // passes a binding so non-search drawers don't render an empty
    // input. We use a switch over the Optional so SwiftUI's view
    // identity stays stable per branch.
    .modifier(OptionalSearchable(text: searchText, prompt: searchPrompt))
    // Deep-linked section Settings, presented over the drawer so closing it
    // returns the user here (the chosen "keep drawer underneath" behavior).
    .sheet(isPresented: $showingSettings) {
      SettingsView(initialDestination: .section(sectionKey))
    }
    // The section name is the standard inline nav-bar title — plain text in
    // the system's default place, identical on every drawer. Kept inline
    // (not a big editorial heading) so the drawer top stays compact.
    .navigationTitle(resolvedTitle)
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .tint(resolvedAccent)
    // Screen analytics keyed by the section — internalized here so no drawer
    // hand-passes a `.trackScreen("key")` that always equals `sectionKey`.
    .trackScreen(sectionKey)
    .toolbar {
      if loadState == .loading {
        // Subtle inline activity indicator next to the title slot so
        // background fetches surface without blocking the cached
        // content underneath.
        ToolbarItem(placement: .primaryAction) {
          ProgressView()
            .controlSize(.small)
        }
      }
      // Calendar / time-travel button — leftmost of the trailing cluster,
      // present only when the destination is day-scoped. Tints accent and
      // gains a clock badge while viewing a past day. The system supplies the
      // glass background for standard toolbar buttons.
      if currentDate != nil {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showingTimeTravel = true
          } label: {
            Label("Time Travel",
                  systemImage: isTimeTraveling ? "calendar.badge.clock" : "calendar")
          }
          .tint(isTimeTraveling ? resolvedAccent : nil)
        }
      }
      // Goals toggle sits just left of the "+" affordance. Hidden while
      // time-traveling (the strip itself is suppressed on past days) and
      // when the section has no tagged goals (the button view self-hides).
      if !isTimeTraveling {
        ToolbarItem(placement: .primaryAction) {
          SectionGoalsToggleButton(
            sectionKey: sectionKey,
            isExpanded: $goalsExpanded,
            accent: resolvedAccent
          )
        }
      }
      // Log/action button — ONE component (`DrawerActionButton`) so its
      // appearance is defined in a single place for both single- and
      // multi-action sections. A fixed spacer keeps it in its own glass group,
      // separated from the calendar + goals cluster, on every drawer.
      // No ToolbarSpacer: it wraps the action in its own glass group, which
      // renders as a capsule AROUND the button. The system already places the
      // primaryAction "+" as a standalone prominent control.
      if let onLog, !actions.isEmpty {
        ToolbarItem(placement: .primaryAction) {
          DrawerActionButton(actions: actions, accent: resolvedAccent, onLog: onLog)
        }
      }
    }
  }
}

/// The drawer's log/action toolbar control, centralized in ONE component so
/// every drawer's action button is identical. A single action fires on one tap
/// (a plain `Button` the system draws as the prominent accent circle); multiple
/// actions open an inline dropdown `Menu` — the consolidated quick-add list,
/// each row carrying its section icon, the first row bound to ⌘N. We let the
/// system render the toolbar control (no `.glassProminent`, which nests a circle
/// inside the toolbar's own capsule and renders the Menu as a pill) and only
/// carry the section tint.
struct DrawerActionButton: View {
  let actions: [LogAction]
  let accent: Color
  let onLog: (String) -> Void

  var body: some View {
    Group {
      if actions.count == 1, let only = actions.first {
        Button { onLog(only.id) } label: {
          Image(systemName: only.systemImage ?? "plus")
            .accessibilityLabel(only.title)
        }
        .keyboardShortcut("n", modifiers: .command)
      } else {
        // Multi-action: an inline dropdown listing every quick-add option with
        // its icon — the quick-menu style. First row carries ⌘N.
        Menu {
          ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
            Button {
              onLog(action.id)
            } label: {
              if let img = action.systemImage {
                Label(action.title, systemImage: img)
              } else {
                Text(action.title)
              }
            }
            .keyboardShortcut(idx == 0 ? KeyboardShortcut("n", modifiers: .command) : nil)
          }
        } label: {
          Image(systemName: "plus")
            .accessibilityLabel("Log")
        }
      }
    }
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
  func sectionDrawerPresentation() -> some View {
    #if os(iOS)
    self
      .presentationDetents([.medium, .large])
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
  /// Standard section data lifecycle in one wire. `perform` runs:
  ///   • on appear,
  ///   • whenever `value` changes (e.g. the viewing date) — `.task(id:)` both
  ///     starts on appear and restarts on change, replacing a separate
  ///     `.onChange(of:)`, and cancels any in-flight load on a date switch,
  ///   • on `.septenaDataChanged` when `onDataChange` is true (log drawers that
  ///     should refresh after a write elsewhere).
  /// Collapses the `.task` + `.onChange` + `.onReceive` trio every drawer
  /// repeated. Accepts an `async` closure so both sync `reload()` and
  /// `paintFromCache(); await load()` shapes fit.
  func sectionReload<V: Equatable>(
    on value: V,
    onDataChange: Bool = false,
    perform: @escaping () async -> Void
  ) -> some View {
    self
      .task(id: value) { await perform() }
      .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
        if onDataChange { Task { @MainActor in await perform() } }
      }
  }

  /// Lifecycle variant for drawers with no observed value (no time travel).
  func sectionReload(
    onDataChange: Bool = false,
    perform: @escaping () async -> Void
  ) -> some View {
    sectionReload(on: 0, onDataChange: onDataChange, perform: perform)
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
        .background(Theme.secondaryGroupedBackground, in: Capsule())
      }
      .buttonStyle(.plain)
      Spacer()
    }
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
  /// Tints just the Cancel/Save controls. The form content stays neutral; pass
  /// a section color when you want the confirm/cancel affordances accented
  /// without coloring the whole form.
  var accent: Color? = nil
  /// Disables the confirmation control (e.g. while a required field is
  /// empty). The form owns the validation; the scaffold owns the affordance.
  var canSave: Bool = true
  /// The save action. The scaffold runs it, then closes — forms must NOT
  /// call dismiss/close themselves (that's what produced the double-close
  /// and dismiss-no-op bugs the inspector exposed).
  let onSave: () -> Void
  @ViewBuilder var content: () -> FormContent

  @Environment(\.dismiss) private var dismiss
  @Environment(\.adaptiveDetailClose) private var adaptiveClose

  private var isInspector: Bool { adaptiveClose != nil }
  private func close() { (adaptiveClose ?? { dismiss() })() }
  private func confirm() { onSave(); close() }

  var body: some View {
    if isInspector {
      content()
        .safeAreaInset(edge: .top, spacing: 0) {
          AdaptiveEditHeader(
            title: title,
            cancelTitle: cancelTitle,
            saveTitle: saveTitle,
            canSave: canSave,
            accent: accent,
            onCancel: close,
            onSave: confirm
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
              Button(cancelTitle, action: close)
                .tint(accent)
                .keyboardShortcut(.cancelAction) // Esc
            }
            ToolbarItem(placement: .confirmationAction) {
              Button(saveTitle, action: confirm)
                .tint(accent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction) // Return / ⌘Return
            }
          }
      }
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
  let canSave: Bool
  var accent: Color? = nil
  let onCancel: () -> Void
  let onSave: () -> Void

  var body: some View {
    HStack {
      Button(cancelTitle, action: onCancel)
        .keyboardShortcut(.cancelAction) // Esc
      Spacer()
      Text(title).font(.headline)
      Spacer()
      Button(saveTitle, action: onSave)
        .fontWeight(.semibold)
        .disabled(!canSave)
        .keyboardShortcut(.defaultAction) // Return / ⌘Return
    }
    .tint(accent)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }
}

/// True when detail content should dock as an inspector rather than present
/// as a sheet. On regular width a section opens as a pushed full pane
/// (WeekDashboardView.usesPushNavigation), so an inspector has room to dock
/// and a nav bar to host its close affordance. On compact the section is a
/// bottom sheet, so edits stay sheets too.
private func adaptiveUseInspector(hSizeIsRegular: Bool) -> Bool {
  #if os(macOS)
  return true
  #else
  return hSizeIsRegular
  #endif
}

private struct AdaptiveDetailItem<Item: Identifiable, DetailContent: View>: ViewModifier {
  @Binding var item: Item?
  let onDismiss: (() -> Void)?
  @ViewBuilder let detail: (Item) -> DetailContent

  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  private var useInspector: Bool {
    #if os(iOS)
    return adaptiveUseInspector(hSizeIsRegular: hSize == .regular)
    #else
    return adaptiveUseInspector(hSizeIsRegular: true)
    #endif
  }

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

  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  private var useInspector: Bool {
    #if os(iOS)
    return adaptiveUseInspector(hSizeIsRegular: hSize == .regular)
    #else
    return adaptiveUseInspector(hSizeIsRegular: true)
    #endif
  }

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

private struct RowHInsetKey: EnvironmentKey {
  static let defaultValue: CGFloat = Theme.hPadding
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
}

struct DrawerSection<Content: View>: View {
  let title: String?
  let spacing: CGFloat
  let padding: DrawerPadding
  @ViewBuilder var content: () -> Content

  @Environment(\.drawerSurfaceStyle) private var surfaceStyle

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
        // Surface fill from the injected style — opaque card on a solid host,
        // clear on the glass (translucent-sheet) host. One decision, one place.
        .background(
          RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .fill(surfaceStyle.cardFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
  }

  @ViewBuilder
  private var paddedStack: some View {
    let stack = VStack(spacing: spacing) { content() }
    switch padding {
    case .standard: stack.padding(.horizontal, Theme.Spacing.lg)
                         .padding(.vertical, Theme.Spacing.md)
    case .tight:    stack.padding(.horizontal, Theme.Spacing.md)
                         .padding(.vertical, Theme.Spacing.sm)
    case .none:     stack
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
    #if os(macOS)
    // macOS has no compact width; always offer the width-driven board.
    masonry
    #else
    if hSize == .regular {
      masonry
    } else {
      // iPhone path — untouched: lazy single column.
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
