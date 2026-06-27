import SwiftUI
import WatchKit

private extension View {
  func watchPageTitle(_ title: String, count: Int) -> some View {
    navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
              .foregroundStyle(.white)
            Text("\(count)")
              .foregroundStyle(.white.opacity(0.58))
          }
          .font(.headline)
          .fontWeight(.semibold)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isHeader)
        }
      }
  }
}

struct NextWatchView: View {
  @State private var conn = WatchConnectivity.shared
  @State private var quickLogItem: NextItem?
  @State private var capturing = false
  /// The push stack — set by the foot-of-feed summary links and by the macro /
  /// training complication deep links (`onOpenURL`).
  @State private var path: [WatchPage] = []
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack(path: $path) {
      content
        .navigationTitle(conn.bucket.isEmpty ? "Next" : DayBucket.label(forKey: conn.bucket))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: WatchPage.self) { page in
          switch page {
          case .nutrition: NutritionDetailView(conn: conn)
          case .training:  TrainingDetailView(conn: conn)
          case .intake:    IntakeDetailView(conn: conn)
          }
        }
        .toolbar {
          // Capture a loggable (intake / mood) on demand, not just
          // when its suggestion happens to lead the feed.
          ToolbarItem(placement: .topBarTrailing) {
            Button { capturing = true } label: {
              Image(systemName: "plus")
            }
          }
        }
        // The time-of-day sky is the canvas behind the whole stack (feed +
        // pushed summary pages), so the feed's glass rows float on the real
        // current sky instead of a flat black.
        .background(WatchSkyWash())
    }
    .sheet(item: $quickLogItem) { item in
      QuickLogSheet(item: item, conn: conn) { quickLogItem = nil }
    }
    .sheet(isPresented: $capturing) {
      CaptureSheet(conn: conn) { capturing = false }
    }
    // Complication tap targets: the macro / training rings carry a `widgetURL`,
    // which the system delivers here. Route it to the matching summary page.
    .onOpenURL { url in
      guard url.scheme == "septena" else { return }
      switch url.host {
      case "nutrition": path = [.nutrition]
      case "training":  path = [.training]
      default:          break
      }
    }
    .task { conn.fetchNext() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { conn.fetchNext() }
    }
    // Day rollover: refetch the moment the calendar day flips so a watch left
    // awake across midnight doesn't keep showing yesterday's Next. The phone
    // does this through `DayClock`'s `.NSCalendarDayChanged` observer; the watch
    // has no DayClock, so we listen for the same system notification directly.
    // (Crossing midnight while backgrounded is already covered by the
    // scenePhase-active refetch on the next foreground.)
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
      conn.fetchNext()
    }
    // Foreground poll: with no push entitlement on the watch, a wrist left open
    // can't otherwise hear about a change made on the phone. One O(1) snapshot
    // read a minute while actively on screen keeps an open watch from nagging to
    // do something already logged elsewhere. Gated to `.active` so it never runs
    // backgrounded (where the 15-min background refresh takes over).
    .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
      if scenePhase == .active { conn.fetchNext() }
    }
  }

  @ViewBuilder
  private var content: some View {
    if conn.isLoading && conn.items.isEmpty {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let err = conn.errorMessage {
      VStack(spacing: 6) {
        Image(systemName: "iphone.slash")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text(err)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding()
    } else if conn.items.isEmpty {
      // Nothing left to do — still surface the summary pages so the macro /
      // training rings stay reachable in-app when the feed is clear.
      if hasSummaries {
        List {
          allDoneHero
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 14, leading: 6, bottom: 8, trailing: 6))
            .listRowBackground(Color.clear)
          summaryLinkRows
        }
        .listStyle(.plain)
        .watchSkyList()
        .environment(\.defaultMinListRowHeight, 0)
      } else {
        allDoneHero
      }
    } else {
      // Each section is its own full-screen page in a vertically-paginated
      // TabView — the Weather-app affordance: the Digital Crown snaps page to
      // page with a detent haptic at every section boundary, and watchOS swaps
      // the navigation title to the focused page's section as you scroll. A
      // "list of lists" that reads haptically and navigationally, not one long
      // scroll. The Summaries page rides last, matching Apple's guidance to keep
      // the longest freely-scrolling content in the final tab so its inner
      // scroll never fights the page snap. The sky canvas behind the whole
      // NavigationStack shows through every page's hidden list background.
      TabView {
        // Group ids are array offsets, not the section key: should a key ever
        // recur (two non-adjacent runs of the same kind) the offsets stay unique
        // where the keys wouldn't, so the pages never collapse into one.
        ForEach(Array(groupedItems.enumerated()), id: \.offset) { _, group in
          sectionPage(key: group.key, items: group.items)
        }
        if hasSummaries {
          summariesPage
        }
      }
      .tabViewStyle(.verticalPage)
    }
  }

  /// The Next feed split into contiguous runs by section key — one run per
  /// page. Built by walking the phone-ordered `conn.items` (already grouped
  /// upstream) into value-type arrays, so a row closure never indexes the live,
  /// mutating `conn.items`: rapid wrist taps remove completed rows mid-render,
  /// and these captured arrays stay consistent for the page's lifetime.
  private var groupedItems: [(key: String, items: [NextItem])] {
    var groups: [(key: String, items: [NextItem])] = []
    for item in conn.items {
      let key = WatchSectionTint.key(for: item)
      if let last = groups.last, last.key == key {
        groups[groups.count - 1].items.append(item)
      } else {
        groups.append((key: key, items: [item]))
      }
    }
    return groups
  }

  /// One section's page: the group's rows over a faint top-edge wash of the
  /// section's accent — the same treatment the phone's `SectionDrawer` uses (a
  /// barely-there gradient that makes each section "feel lit by its own color"
  /// without coloring the content). It sits between the rows and the time-of-day
  /// sky, so the glyphs stay white and the sky still shows through below the
  /// wash. Titled with the section noun so the paged title bar names where you
  /// are; the page boundary does the separating the old inline rule used to.
  private func sectionPage(key: String, items: [NextItem]) -> some View {
    // Real section colors only — suggestions aren't a section, and a key with no
    // published color washes nothing (`.clear`), leaving just the sky.
    let accent: Color = (key != "suggestion" && conn.sectionColors[key] != nil)
      ? WatchSectionTint.color(forSectionKey: key, colors: conn.sectionColors)
      : .clear
    return List {
      ForEach(items, id: \.id) { item in
        NextItemRow(item: item,
                    done: conn.completedIDs.contains(item.id),
                    onComplete: { conn.complete(item) },
                    onQuickLog: { quickLogItem = item },
                    onOffToday: { conn.offTodayTask(item) },
                    onCancel: { conn.cancelTask(item) },
                    onSkip: {
                      // Suggestions skip via the synced Settings blob; daily
                      // members skip via their day-event record.
                      if item.kind == "suggestion" { conn.skipSuggestion(item) }
                      else { conn.skipItem(item) }
                    })
        .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        .watchSkyRow()
      }
      pagerBottomSpacer
    }
    .listStyle(.plain)
    .watchSkyList()
    .environment(\.defaultMinListRowHeight, 0)
    // The drawer's top-edge accent wash, over the sky. Pitched a touch stronger
    // than the phone's 0.055 peak because it sits on the dark sky (where 5.5%
    // would vanish) rather than a light grouped background. Tunable — this is
    // the value to dial if it reads too strong / too faint on the wrist.
    .background {
      LinearGradient(
        stops: [
          .init(color: accent.opacity(0.20), location: 0),
          .init(color: .clear, location: 0.45),
        ],
        startPoint: .top, endPoint: .bottom
      )
      .ignoresSafeArea()
      .allowsHitTesting(false)
    }
    .watchPageTitle(WatchSectionTint.pageTitle(forKey: key), count: items.count)
  }

  /// The final page: the macro / training / intake summary tiles, titled
  /// "Summaries" so the paged title bar names it (the inline "Summaries" caption
  /// the empty state uses would be redundant here).
  private var summariesPage: some View {
    List {
      summaryTiles
      pagerBottomSpacer
    }
    .listStyle(.plain)
    .watchSkyList()
    .environment(\.defaultMinListRowHeight, 0)
    .watchPageTitle("Summaries", count: summaryTileCount)
  }

  private var summaryTileCount: Int {
    (hasNutrition ? 1 : 0)
      + (hasTraining ? 1 : 0)
      + (hasIntake ? intakeSummaryRows.count : 0)
  }

  /// The vertical pager takes over as the list reaches its bottom edge, which
  /// can hide the last real row of a bucket behind the next page snap. Keep a
  /// little inert scroll room after the content so the final item can settle
  /// fully into view before watchOS starts paging.
  private var pagerBottomSpacer: some View {
    Color.clear
      .frame(height: 32)
      .listRowInsets(EdgeInsets())
      .listRowBackground(Color.clear)
      .allowsHitTesting(false)
  }

  private var allDoneHero: some View {
    VStack(spacing: 6) {
      Image(systemName: "checkmark.circle.fill")
        .font(.title2)
        .foregroundStyle(.green)
      Text("All done")
        .foregroundStyle(.secondary)
    }
  }

  // The Macros / Training summary links are stable navigation affordances — their
  // pages handle the empty case — so they should only ever hide when the phone
  // *explicitly* says the section is off. If the snapshot carries the enabled set,
  // respect it; otherwise (older / stale snapshot with no enabled set) show the
  // link rather than guessing from whether today's ring data rode along. This is
  // what keeps Training from silently vanishing against a stale snapshot.
  private var hasNutrition: Bool { sectionAvailable("nutrition") }
  private var hasTraining: Bool { sectionAvailable("training") }
  // Also reveal Intakes whenever the snapshot carries trackers — having intake
  // kinds means the section is on, so a stale/empty `enabledSections` (the only
  // thing `sectionAvailable` keys off) can't silently hide the link.
  private var hasIntake: Bool { sectionAvailable("intake") || !conn.intakeKinds.isEmpty }
  private var hasSummaries: Bool { hasNutrition || hasTraining || hasIntake }

  private func sectionAvailable(_ key: String) -> Bool {
    if !conn.enabledSections.isEmpty { return conn.enabledSections.contains(key) }
    return true
  }

  /// Foot-of-feed links to the macro / training summary pages — the same pages
  /// the complications open. Shown only for sections the snapshot has data for,
  /// under a quiet header so they read as a footer, not another task group.
  @ViewBuilder
  private var summaryLinkRows: some View {
    if hasSummaries {
      Text("Summaries")
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .listRowInsets(EdgeInsets(top: 10, leading: 6, bottom: 2, trailing: 6))
        .listRowBackground(Color.clear)
      summaryTiles
    }
  }

  /// The summary rows themselves (nutrition / training / per-intake tiles),
  /// without the "Summaries" caption — so the empty-state footer can keep its
  /// inline header while the paged Summaries page leans on its title bar instead.
  @ViewBuilder
  private var summaryTiles: some View {
    if hasSummaries {
      if hasNutrition {
        summaryLink(.nutrition, title: "Nutrition", systemImage: "fork.knife",
                    color: WatchSectionTint.color(forSectionKey: "nutrition", colors: conn.sectionColors))
      }
      if hasTraining {
        summaryLink(.training, title: "Training", systemImage: "figure.strengthtraining.traditional",
                    color: WatchSectionTint.color(forSectionKey: "training", colors: conn.sectionColors))
      }
      // Each intake tracker as its own top-level tile (Caffeine, Cannabis, …),
      // sitting beside Nutrition / Training — the trackers + today's tally are
      // visible here directly, no "Intakes" sub-page to drill into.
      if hasIntake {
        ForEach(intakeSummaryRows) { row in
          intakeTile(row)
        }
      }
      #if DEBUG
      // TEMP: which intake trackers the fetched snapshot actually carries —
      // `k` = kinds list, `t` = today's tally. If caffeine is absent from `k`,
      // it's missing from the publish, not the watch UI. Remove once resolved.
      Text("dbg k:[\(conn.intakeKinds.map(\.name).joined(separator: ","))] t:[\(conn.intakeToday.map(\.name).joined(separator: ","))]")
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.orange)
        .listRowInsets(EdgeInsets(top: 8, leading: 6, bottom: 6, trailing: 6))
        .listRowBackground(Color.clear)
      #endif
    }
  }

  /// One row per enabled intake tracker, each carrying today's tally (×0 before
  /// anything's logged) — so the Summaries footer shows every tracker, not just
  /// the ones with an event today. Mirrors `IntakeDetailView.rows`: backfill the
  /// kinds list with their today count, falling back to the today-only tally if
  /// the kind list hasn't synced (older snapshot).
  private var intakeSummaryRows: [IntakeTodayWire] {
    let logged = Dictionary(conn.intakeToday.map { ($0.id, $0) },
                            uniquingKeysWith: { a, _ in a })
    // Every enabled tracker, backfilled with today's tally (×0 before anything's
    // logged)…
    var seen = Set<String>()
    var rows = conn.intakeKinds.map { k -> IntakeTodayWire in
      seen.insert(k.id)
      return logged[k.id] ?? IntakeTodayWire(id: k.id, name: k.name, symbol: k.symbol,
                                             color: k.color, count: 0, detail: nil)
    }
    // …plus any tracker that has a tally today but didn't ride along in the kinds
    // list, so a logged tracker is never hidden by a partial snapshot.
    for t in conn.intakeToday where !seen.contains(t.id) { rows.append(t) }
    return rows
  }

  /// A single intake-tracker tile: tinted glyph + name on the left, today's tally
  /// (the wire's noun line, else "×N") on the right. A terminal info tile — unlike
  /// the Nutrition / Training rows it doesn't drill in (intake is a tally, not a
  /// ring set), but it matches their glyph alignment and row padding.
  private func intakeTile(_ row: IntakeTodayWire) -> some View {
    let tint = WatchSectionTint.color(forSectionKey: row.id,
                                      colors: row.color.map { [row.id: $0] } ?? [:])
    return HStack(spacing: 9) {
      Image(systemName: row.symbol ?? "circle.fill")
        .font(.body)
        .foregroundStyle(tint)
        .frame(width: 18)
      Text(row.name).font(.body)
      Spacer(minLength: 4)
      Text(row.detail ?? "×\(row.count)")
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .padding(.vertical, 4)
    .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
    .watchSkyRow()
  }

  private func summaryLink(_ page: WatchPage, title: String,
                           systemImage: String, color: Color) -> some View {
    NavigationLink(value: page) {
      HStack(spacing: 9) {
        Image(systemName: systemImage)
          .font(.body)
          .foregroundStyle(color)
          .frame(width: 18)
        Text(title).font(.body)
        Spacer(minLength: 0)
      }
      // Match the standard task rows above, which carry an inner vertical pad on
      // top of the row insets — without it these links read a touch shorter.
      .padding(.vertical, 4)
    }
    .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
    .watchSkyRow()
  }
}

// MARK: - Section accent palette (watch)

/// Resolves a Next row to its section's accent for the group rule. The watch
/// has no `SectionTheme` (that's phone/Mac, CloudKit-backed), so the *actual*
/// per-section colors ride in on the snapshot (`NextItemsResponse.sectionColors`)
/// and are parsed here. A row whose section has no color — or a section we
/// can't resolve — gets a neutral rule rather than a guessed tint. All
/// suggestions share one band, like the phone's single `NextSuggestionsSection`.
enum WatchSectionTint {
  /// Group key — the unit the list draws a rule between. Suggestions collapse
  /// to one group regardless of their `logKind` (intake / mood).
  static func key(for item: NextItem) -> String {
    switch item.kind {
    case "suggestion": return "suggestion"
    case "task":       return "tasks"
    case "habit":      return "habits"
    case "supplement": return "supplements"
    case "chore":      return "chores"
    default:           return item.kind
    }
  }

  /// The header noun for a group key, singular/plural by count ("task" / "tasks").
  static func noun(forKey key: String, count: Int) -> String {
    let singular: String
    switch key {
    case "tasks":       singular = "task"
    case "habits":      singular = "habit"
    case "supplements": singular = "supplement"
    case "chores":      singular = "chore"
    case "suggestion":  singular = "suggestion"
    default:            singular = key
    }
    return count == 1 ? singular : singular + "s"
  }

  /// The paged title-bar label for a group key — the section name watchOS shows
  /// as you snap to that page. Capitalized plural noun ("Tasks", "Habits"),
  /// except suggestions, which read "Suggested" to match the phone's group.
  static func pageTitle(forKey key: String) -> String {
    if key == "suggestion" { return "Suggested" }
    let plural = noun(forKey: key, count: 2)
    return plural.prefix(1).uppercased() + plural.dropFirst()
  }

  /// Resolve a section's accent straight from its key (e.g. the Capture sheet's
  /// intake / mood rows). Neutral when the section has no color.
  static func color(forSectionKey key: String, colors: [String: String]) -> Color {
    guard let token = colors[key], let c = parse(token) else { return .secondary }
    return c
  }

  // MARK: - Color token parsing
  //
  // A trimmed port of the phone's `AdaptiveColor` (which can't compile on the
  // watch — it leans on dynamic UIColor). Parses "#rrggbb" / "rgb(...)" /
  // "hsl(...)" and lifts low-lightness tokens toward a floor so they stay
  // legible on the always-dark watch canvas, matching the phone's dark mode.

  private static let darkFloor = 0.50

  private static func parse(_ token: String) -> Color? {
    guard let rgb = components(token) else { return nil }
    let lifted = liftedForDark(rgb)
    return Color(red: lifted.0, green: lifted.1, blue: lifted.2)
  }

  private static func components(_ raw: String) -> (Double, Double, Double)? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if s.hasPrefix("hsl") { return hslComponents(s) }
    if s.hasPrefix("rgb") { return rgbComponents(s) }
    return hexComponents(s.hasPrefix("#") ? s : "#" + s)
  }

  private static func hexComponents(_ s: String) -> (Double, Double, Double)? {
    let hex = s.replacingOccurrences(of: "#", with: "")
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return (Double((v >> 16) & 0xff) / 255,
            Double((v >> 8) & 0xff) / 255,
            Double(v & 0xff) / 255)
  }

  private static func rgbComponents(_ s: String) -> (Double, Double, Double)? {
    let nums = numbers(in: s, stripping: ["rgba", "rgb"])
    guard nums.count >= 3 else { return nil }
    return (nums[0] / 255, nums[1] / 255, nums[2] / 255)
  }

  private static func hslComponents(_ s: String) -> (Double, Double, Double)? {
    let nums = numbers(in: s, stripping: ["hsl"])
    guard nums.count >= 3 else { return nil }
    return hslToRGB(nums[0], nums[1] / 100, nums[2] / 100)
  }

  private static func numbers(in s: String, stripping tokens: [String]) -> [Double] {
    var t = s
    for token in tokens { t = t.replacingOccurrences(of: token, with: "") }
    return t
      .replacingOccurrences(of: "(", with: "")
      .replacingOccurrences(of: ")", with: "")
      .replacingOccurrences(of: "%", with: "")
      .split(whereSeparator: { ", ".contains($0) })
      .compactMap { Double($0) }
  }

  /// Lift a dark token up to `darkFloor`, trimming a little saturation so the
  /// brighter swatch reads clean. No-op at/above the floor.
  private static func liftedForDark(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
    var (h, sat, l) = rgbToHSL(c)
    guard l < darkFloor else { return c }
    let lift = darkFloor - l
    l = darkFloor
    sat = max(0, sat - lift * 0.35)
    return hslToRGB(h, sat, l)
  }

  private static func rgbToHSL(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
    let (r, g, b) = c
    let maxV = max(r, g, b), minV = min(r, g, b)
    let l = (maxV + minV) / 2
    let delta = maxV - minV
    guard delta > 0 else { return (0, 0, l) }
    let s = delta / (1 - abs(2 * l - 1))
    var h: Double
    if maxV == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
    else if maxV == g { h = (b - r) / delta + 2 }
    else { h = (r - g) / delta + 4 }
    h *= 60
    if h < 0 { h += 360 }
    return (h, s, l)
  }

  private static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
    let chroma = (1 - abs(2 * l - 1)) * s
    let hPrime = h.truncatingRemainder(dividingBy: 360) / 60
    let x = chroma * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
    let m = l - chroma / 2
    let (r1, g1, b1): (Double, Double, Double)
    switch hPrime {
    case 0..<1: (r1, g1, b1) = (chroma, x, 0)
    case 1..<2: (r1, g1, b1) = (x, chroma, 0)
    case 2..<3: (r1, g1, b1) = (0, chroma, x)
    case 3..<4: (r1, g1, b1) = (0, x, chroma)
    case 4..<5: (r1, g1, b1) = (x, 0, chroma)
    default:    (r1, g1, b1) = (chroma, 0, x)
    }
    return (r1 + m, g1 + m, b1 + m)
  }
}

struct NextItemRow: View {
  let item: NextItem
  let done: Bool
  let onComplete: () -> Void
  var onQuickLog: (() -> Void)? = nil
  // Secondary actions surfaced in the long-press drawer. Which ones show is
  // per-kind (see RowActionDrawer): tasks get off-today / cancel, habits and
  // supplements get skip; every completable row gets complete.
  var onOffToday: (() -> Void)? = nil
  var onCancel: (() -> Void)? = nil
  var onSkip: (() -> Void)? = nil

  @State private var showActions = false
  @State private var isPressing = false

  private var isSuggestion: Bool { item.kind == "suggestion" }
  /// A suggestion that can be logged from a tap (carries a `SuggestionBlocks`
  /// kind in `logKind`). Other suggestions stay read-only nudges.
  private var isActionableSuggestion: Bool { isSuggestion && item.logKind != nil }

  var body: some View {
    // Every row gets the long-press action drawer (watchOS doesn't render
    // `.contextMenu` reliably since Force Touch was removed, so this is the
    // standard long-press → sheet equivalent). Only the *tap* differs by kind:
    // a suggestion logs (actionable) or does nothing (read-only); a completable
    // member completes. Separate tap / long-press gestures on a plain row (not a
    // Button) so SwiftUI disambiguates them — a recognized long press won't also
    // fire the tap, so the drawer never acts by accident.
    if isSuggestion {
      actionRow(onTap: { if isActionableSuggestion { onQuickLog?() } })
    } else {
      actionRow(onTap: { onComplete() })
    }
  }

  /// The interactive row: rowBody + the highlight + tap / long-press gestures +
  /// the action sheet, shared across all kinds so the press feedback and drawer
  /// stay identical. `onTap` is the only per-kind difference.
  private func actionRow(onTap: @escaping () -> Void) -> some View {
    rowBody
      // Span the full row width so the highlight (and the tap target) cover the
      // whole row, not just the label — otherwise a short title only lights up
      // the few points of text.
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      // Press feedback: the row lights while the finger is down (so a hold reads
      // as "registering" before the drawer opens) and stays lit once tapped —
      // `done` holds the highlight through the ~1.1s settle before the row fades.
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(Color.white.opacity(highlightOpacity))
      )
      .scaleEffect(isPressing ? 0.98 : 1)
      .animation(.easeOut(duration: 0.14), value: isPressing)
      .animation(.easeOut(duration: 0.14), value: done)
      .onTapGesture { onTap() }
      .onLongPressGesture(minimumDuration: 0.4, pressing: { pressing in
        isPressing = pressing
      }, perform: {
        // A light blip confirms the deep-press registered before the drawer
        // slides up — the wrist's stand-in for a context-menu reveal.
        WKInterfaceDevice.current().play(.click)
        showActions = true
      })
      .sheet(isPresented: $showActions) {
        RowActionDrawer(
          item: item,
          onComplete: onComplete,
          onOffToday: { onOffToday?() },
          onCancel: { onCancel?() },
          onSkip: { onSkip?() })
      }
  }

  /// Highlight strength behind the row: brightest while held, a softer hold once
  /// the row is done/skipped (the flash that lingers until it fades out).
  private var highlightOpacity: Double {
    if isPressing { return 0.20 }
    if done { return 0.13 }
    return 0
  }

  private var rowBody: some View {
    HStack(spacing: 9) {
      Image(systemName: done ? "checkmark.circle.fill" : kindIcon)
        .font(.body)
        .foregroundStyle(iconColor)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 1) {
        Text(item.title)
          .font(.body)
          .lineLimit(1)
          .strikethrough(done)
          .foregroundStyle(done ? .secondary : .primary)
        if hasSubtitle {
          Text(item.subtitle!)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      // Quick-log nudges wear a trailing plus so the tap target reads as "add",
      // not "complete".
      if isActionableSuggestion && !done {
        Spacer(minLength: 0)
        Image(systemName: "plus.circle.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      // Overdue shown as a compact icon (not text) to free up label space.
      if item.overdue && !done {
        Spacer(minLength: 0)
        Image(systemName: "exclamationmark.circle.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    // Subtitle-less rows would otherwise be noticeably shorter; pad them up
    // partway toward the two-line height so the list reads more evenly.
    .padding(.vertical, hasSubtitle ? 1 : 4)
  }

  private var hasSubtitle: Bool {
    if let sub = item.subtitle, !sub.isEmpty { return true }
    return false
  }

  private var iconColor: Color {
    if done { return .green }
    // Suggestions read neutral, like the phone's "Suggested" group — the
    // grouping itself marks them as nudges, no accent needed.
    if isSuggestion { return .secondary }
    // Section accent tints didn't read against the time-of-day sky, so the kind
    // glyph stays plain white (matching the title text) — clean monochrome over
    // the canvas. Overdue is still carried by the trailing warning marker, not
    // by reddening the glyph.
    return .primary
  }

  // The leading glyph. Completable rows (task / habit / supplement / chore) all
  // collapse to a plain `circle` — a real checkbox that the caller fills to a
  // green `checkmark.circle.fill` when done. The per-kind symbols (repeat.circle
  // / pill / house …) were redundant once each section became its own titled
  // page: every row under "Habits" wore the same habit glyph the title already
  // names. Suggestions aren't completable, so they keep an indicative `lightbulb`
  // rather than a checkbox that would imply they can be ticked off.
  private var kindIcon: String {
    isSuggestion ? "lightbulb" : "circle"
  }
}

// MARK: - Row action drawer

/// The long-press drawer for a completable row: the phone's secondary actions on
/// the wrist, shown per-kind. Every kind offers Complete; tasks add Off today /
/// Cancel, habits + supplements add Skip today, chores have only Complete. Each
/// button fires its action and dismisses. "Cancel task" is labelled in full so
/// it doesn't read as "dismiss the sheet".
private struct RowActionDrawer: View {
  let item: NextItem
  let onComplete: () -> Void
  let onOffToday: () -> Void
  let onCancel: () -> Void
  let onSkip: () -> Void
  @Environment(\.dismiss) private var dismiss

  private var canSkip: Bool { item.kind == "habit" || item.kind == "supplement" }

  var body: some View {
    List {
      Section {
        if item.kind == "suggestion" {
          // A suggestion's only action — matches the phone's suggestion menu
          // exactly (logging is the tap, not a menu item). `forward.end` is the
          // same glyph the phone uses for "Skip today".
          Button { onSkip(); dismiss() } label: {
            Label("Skip today", systemImage: "forward.end")
          }
        } else {
          Button { onComplete(); dismiss() } label: {
            Label("Complete", systemImage: "checkmark.circle")
          }
          if canSkip {
            Button { onSkip(); dismiss() } label: {
              Label("Skip today", systemImage: "minus.circle")
            }
          }
          if item.kind == "task" {
            Button { onOffToday(); dismiss() } label: {
              Label("Off today", systemImage: "calendar.badge.minus")
            }
            Button(role: .destructive) { onCancel(); dismiss() } label: {
              Label("Cancel task", systemImage: "xmark.circle")
            }
          }
        }
      } header: {
        // Full task title, untruncated and in its natural case — the drawer's
        // header names exactly which row you're acting on.
        Text(item.title)
          .textCase(nil)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

// MARK: - Quick-log picker

/// Presented when a quick-loggable suggestion is tapped. Resolves the shared
/// `SuggestionBlocks` descriptor and shows the right minimal input — a method
/// list (intake) or the mood quadrant grid. Picking writes the
/// event and dismisses.
private struct QuickLogSheet: View {
  let item: NextItem
  let conn: WatchConnectivity
  let onDone: () -> Void

  var body: some View {
    NavigationStack {
      Group {
        if item.logKind == "intake", let kind = intakeKind {
          // Per-tracker nudge: the same container-aware input the + path offers,
          // with the suggestion's id as the optimistic-hide target so the nudge
          // clears on log.
          IntakeCaptureInput(kind: kind, conn: conn, itemID: item.id, onDone: onDone)
        } else if let block = item.logKind.flatMap({ SuggestionBlocks.byKind[$0] }) {
          // Same shared input as the on-demand + path; the suggestion's id is
          // the optimistic-hide target.
          CaptureInput(block: block, itemID: item.id, conn: conn, onDone: onDone)
        } else {
          Text("Unavailable")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .navigationTitle("Log")
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  /// The intake tracker an `intake` nudge targets, resolved from the snapshot's
  /// `intakeKinds` by the kind id encoded in the suggestion id
  /// ("intake:<kindID>:<first|next>"). Defensive against a kind id that itself
  /// contains colons.
  private var intakeKind: IntakeKindWire? {
    let parts = item.id.split(separator: ":")
    guard parts.count >= 3, parts.first == "intake" else { return nil }
    let kindID = parts[1..<(parts.count - 1)].joined(separator: ":")
    return conn.intakeKinds.first { $0.id == kindID }
  }
}

// MARK: - Capture input (shared)

/// The minimal input for one capturable, plus the write on pick. The single
/// home for the `SuggestionBlocks.Input` → view → `conn` dispatch, used by both
/// the suggestion-tap path (`QuickLogSheet`) and the on-demand + path
/// (`CaptureSheet`). The two differ only in `itemID`.
private struct CaptureInput: View {
  let block: SuggestionBlocks.Block
  /// Optimistic-hide target: the suggestion's id on the tap path, or a stable
  /// "adhoc:<kind>" on the + path (matches no row — it only names the write).
  let itemID: String
  let conn: WatchConnectivity
  let onDone: () -> Void

  var body: some View {
    switch block.input {
    case .choice(let choices):
      QuickLogChoiceList(
        choices: choices,
        tint: WatchSectionTint.color(forSectionKey: block.sectionKey, colors: conn.sectionColors)
      ) { value in
        conn.logChoice(kind: block.kind, value: value, itemID: itemID)
        onDone()
      }
    case .moodGrid:
      MoodQuadrantGrid { emotion in
        conn.logMood(quadrant: emotion.quadrant, emotion: emotion.word,
                     arousal: emotion.arousal, valence: emotion.valence,
                     itemID: itemID)
        onDone()
      }
    }
  }
}

// MARK: - Intake capture input

/// The minimal input for one intake tracker from the wire: its container-aware
/// choices (Continue (use N) / New container / methods) via the same
/// `ConsumableContainer` math the phone uses, then the write on pick.
private struct IntakeCaptureInput: View {
  let kind: IntakeKindWire
  let conn: WatchConnectivity
  /// Optimistic-hide target: the suggestion's id on the nudge-tap path, or the
  /// default ad-hoc id on the toolbar **+** path (matches no row).
  var itemID: String? = nil
  let onDone: () -> Void

  var body: some View {
    let methods = kind.methods.map {
      ConsumableContainer.Method(token: $0.token, label: $0.label,
                                 emoji: $0.emoji, usesContainer: $0.usesContainer)
    }
    let choices = ConsumableContainer.choices(
      lastCount: kind.lastContainerCount,
      containerCap: kind.containerCap,
      containerNoun: kind.containerNoun ?? "container",
      countNoun: kind.countNoun ?? "use",
      methods: methods)
    // A methodless kind still gets one tappable "Log" row.
    let resolved = choices.isEmpty
      ? [SuggestionBlocks.Choice(value: "default", label: "Log", symbol: "plus.circle")]
      : choices
    QuickLogChoiceList(
      choices: resolved,
      tint: WatchSectionTint.color(forSectionKey: kind.id,
                                   colors: kind.color.map { [kind.id: $0] } ?? [:])
    ) { value in
      conn.logIntake(kind: kind, value: value, itemID: itemID ?? "adhoc:intake:\(kind.id)")
      onDone()
    }
    .navigationTitle(kind.name)
  }
}

// MARK: - Meal picker (nutrition quick-add)

/// The wrist nutrition quick-add: the user's most-eaten meals as one-tap
/// quick-selects, each an emoji + the meal's name + a macro summary line (and an
/// ×N badge for repeats). Built entirely from the snapshot wire (`MealWire`), so
/// the watch carries no nutrition model — tapping writes a full `NutritionEntry`
/// for the chosen meal and dismisses. Ranking (frequency then recency) and the
/// 25-meal cap are applied phone-side, so the list is render-ready.
/// Internal (not file-private) so the Nutrition summary page can present the
/// same picker from its own toolbar **+**.
struct MealPickerView: View {
  let meals: [MealWire]
  let conn: WatchConnectivity
  let onDone: () -> Void

  var body: some View {
    List(meals) { meal in
      Button {
        conn.logMeal(meal)
        onDone()
      } label: {
        HStack(spacing: 9) {
          Text(meal.emoji?.isEmpty == false ? meal.emoji! : "🍽")
            .font(.body)
            .frame(width: 22)
          VStack(alignment: .leading, spacing: 1) {
            Text(meal.title)
              .font(.body)
              .lineLimit(1)
            Text(meal.macroSummary)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
          if meal.count > 1 {
            Spacer(minLength: 0)
            Text("×\(meal.count)")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
    }
    .listStyle(.plain)
    .navigationTitle("Log a meal")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Pick a medication to mark taken — one tap logs a "taken" dose and dismisses,
/// mirroring the meal picker. `detail` (strength / form) disambiguates the row.
private struct MedicationPickerView: View {
  let meds: [MedicationWire]
  let conn: WatchConnectivity
  let onDone: () -> Void

  var body: some View {
    List(meds) { med in
      Button {
        conn.logMedication(med)
        onDone()
      } label: {
        HStack(spacing: 9) {
          Image(systemName: "cross.case")
            .font(.body)
            .frame(width: 22)
            .foregroundStyle(WatchSectionTint.color(forSectionKey: "medications",
                                                    colors: conn.sectionColors))
          VStack(alignment: .leading, spacing: 1) {
            Text(med.name).font(.body).lineLimit(1)
            if let detail = med.detail, !detail.isEmpty {
              Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
    }
    .listStyle(.plain)
    .navigationTitle("Medication")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Pick a symptom, then a severity — two taps for a faithful log. The severity
/// levels (Mild / Moderate / Severe → 3 / 5 / 8 on the phone's 0–10 scale)
/// mirror `SymptomsQuickAddMenu` so a wrist log matches the phone's quick-add.
private struct SymptomPickerView: View {
  let symptoms: [SymptomWire]
  let conn: WatchConnectivity
  let onDone: () -> Void

  var body: some View {
    List(symptoms) { symptom in
      NavigationLink {
        SymptomSeverityList(symptom: symptom, conn: conn, onDone: onDone)
      } label: {
        HStack(spacing: 9) {
          Text(symptom.emoji?.isEmpty == false ? symptom.emoji! : "🩺")
            .font(.body)
            .frame(width: 22)
          Text(symptom.name).font(.body).lineLimit(1)
          Spacer(minLength: 0)
        }
      }
      .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
    }
    .listStyle(.plain)
    .navigationTitle("Symptom")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Step 2 of the symptom log — pick a calibrated severity. Logs and dismisses.
private struct SymptomSeverityList: View {
  let symptom: SymptomWire
  let conn: WatchConnectivity
  let onDone: () -> Void

  // Named severities map onto the phone editor's 0–10 scale, matching
  // `SymptomsQuickAddMenu.levels` exactly so the two surfaces never diverge.
  private static let levels: [(label: String, severity: Int)] = [
    ("Mild", 3), ("Moderate", 5), ("Severe", 8),
  ]

  var body: some View {
    List(Self.levels, id: \.severity) { level in
      Button {
        conn.logSymptom(symptom, severity: level.severity)
        onDone()
      } label: {
        HStack {
          Text(level.label).font(.body)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
    }
    .listStyle(.plain)
    .navigationTitle(symptom.name)
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Mark in-stock grocery items low. Tapping a row flags it (and drops it from
/// the list via the connectivity layer) so several can be marked in one pass;
/// the list empties as you go, and a Done button closes the capture.
private struct GroceryLowPickerView: View {
  let conn: WatchConnectivity
  let onDone: () -> Void

  var body: some View {
    List {
      ForEach(conn.groceries) { item in
        Button {
          conn.markGroceryLow(item)
        } label: {
          HStack(spacing: 9) {
            Text(item.emoji?.isEmpty == false ? item.emoji! : "🛒")
              .font(.body)
              .frame(width: 22)
            Text(item.name).font(.body).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "arrow.down.circle")
              .foregroundStyle(WatchSectionTint.color(forSectionKey: "groceries",
                                                      colors: conn.sectionColors))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
      }
      if conn.groceries.isEmpty {
        Text("All marked low")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Button("Done", action: onDone)
        .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
    }
    .listStyle(.plain)
    .navigationTitle("Groceries")
    .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - Capture sheet (on-demand log)

/// The toolbar **+** target: pick a capturable, then collect its minimal input.
/// Drives off the same `SuggestionBlocks` table as the suggestion-tap path, so
/// the capturable set + writers stay single-sourced. No suggestion row exists
/// for an ad-hoc capture, so the write carries a stable per-kind id (it only
/// names the optimistic hide, which matches nothing here).
private struct CaptureSheet: View {
  let conn: WatchConnectivity
  let onDone: () -> Void

  var body: some View {
    NavigationStack {
      List {
        // Quick-capture a task to the Inbox — a text entry, not a log, so it
        // leads the menu rather than sitting among the loggables.
        NavigationLink {
          AddInboxTaskView(conn: conn, onDone: onDone)
        } label: {
          Label {
            Text("Add to Inbox")
          } icon: {
            Image(systemName: "tray.and.arrow.down")
              .foregroundStyle(WatchSectionTint.color(forSectionKey: "tasks",
                                                      colors: conn.sectionColors))
          }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))

        // Nutrition — re-log one of the user's most-eaten meals (foods +
        // macros) in one tap. Hidden until the phone has published some meals.
        if !conn.topMeals.isEmpty {
          NavigationLink {
            MealPickerView(meals: conn.topMeals, conn: conn, onDone: onDone)
          } label: {
            Label {
              Text("Log a meal")
            } icon: {
              Image(systemName: "fork.knife")
                .foregroundStyle(WatchSectionTint.color(forSectionKey: "nutrition",
                                                        colors: conn.sectionColors))
            }
          }
          .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        }

        // The user's intake trackers, from the snapshot wire — every enabled
        // tracker is a + item, with container-aware choices.
        ForEach(conn.intakeKinds, id: \.id) { kind in
          NavigationLink {
            IntakeCaptureInput(kind: kind, conn: conn, onDone: onDone)
          } label: {
            Label {
              Text(kind.name)
            } icon: {
              Image(systemName: kind.symbol ?? "plus.circle")
                .foregroundStyle(intakeTint(kind))
            }
          }
          .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        }

        // On-demand loggables (mood / hydration / gut), from the shared
        // SuggestionBlocks table.
        ForEach(staticBlocks, id: \.kind) { block in
          NavigationLink {
            CaptureInput(block: block, itemID: "adhoc:\(block.kind)", conn: conn, onDone: onDone)
          } label: {
            Label {
              Text(title(block.kind))
            } icon: {
              Image(systemName: symbol(block.kind))
                .foregroundStyle(WatchSectionTint.color(forSectionKey: block.sectionKey,
                                                        colors: conn.sectionColors))
            }
          }
          .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        }

        // Medications — mark a dose taken. Present only when the section is
        // enabled and the user has medications (the snapshot gates both).
        if !conn.medications.isEmpty {
          NavigationLink {
            MedicationPickerView(meds: conn.medications, conn: conn, onDone: onDone)
          } label: {
            Label {
              Text("Take medication")
            } icon: {
              Image(systemName: "cross.case")
                .foregroundStyle(WatchSectionTint.color(forSectionKey: "medications",
                                                        colors: conn.sectionColors))
            }
          }
          .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        }

        // Symptoms — log one at a calibrated severity (two taps).
        if !conn.symptoms.isEmpty {
          NavigationLink {
            SymptomPickerView(symptoms: conn.symptoms, conn: conn, onDone: onDone)
          } label: {
            Label {
              Text("Log symptom")
            } icon: {
              Image(systemName: "waveform.path.ecg")
                .foregroundStyle(WatchSectionTint.color(forSectionKey: "symptoms",
                                                        colors: conn.sectionColors))
            }
          }
          .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        }

        // Groceries — mark an in-stock item low ("we ran out"). The picker stays
        // open so several can be flagged in one go.
        if !conn.groceries.isEmpty {
          NavigationLink {
            GroceryLowPickerView(conn: conn, onDone: onDone)
          } label: {
            Label {
              Text("Mark grocery low")
            } icon: {
              Image(systemName: "cart")
                .foregroundStyle(WatchSectionTint.color(forSectionKey: "groceries",
                                                        colors: conn.sectionColors))
            }
          }
          .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        }
      }
      .listStyle(.plain)
      // The default Label glyph scale reads chunky in this menu — drop one
      // notch so the icons sit lighter beside their titles.
      .imageScale(.small)
      .navigationTitle("Capture")
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  /// The compiled-in loggables (mood / hydration / gut). Consumables are
  /// driven entirely by the wire's intake trackers now, so there are no
  /// static consumable blocks to filter out.
  private var staticBlocks: [SuggestionBlocks.Block] {
    SuggestionBlocks.all
  }

  private func intakeTint(_ kind: IntakeKindWire) -> Color {
    WatchSectionTint.color(forSectionKey: kind.id,
                           colors: kind.color.map { [kind.id: $0] } ?? [:])
  }

  private func title(_ kind: String) -> String {
    kind.prefix(1).uppercased() + kind.dropFirst()
  }

  // Mirrors the phone's per-section iconography (`SectionManifest.iconByKey`).
  private func symbol(_ kind: String) -> String {
    switch kind {
    case "mood":      return "face.smiling"
    case "hydration": return "drop.fill"
    case "gut":       return "circle.bottomhalf.filled"
    default:          return "plus.circle"
    }
  }
}

/// Text entry for a quick Inbox task. The watch keyboard offers dictation /
/// scribble; committing writes an open `Task` (no project/area, not Today) the
/// phone mirrors into the Inbox.
private struct AddInboxTaskView: View {
  let conn: WatchConnectivity
  let onDone: () -> Void
  @State private var text = ""
  @FocusState private var focused: Bool

  private var trimmed: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    List {
      TextField("Task", text: $text)
        .focused($focused)
        .onSubmit(commit)
      Button(action: commit) {
        Label("Add to Inbox", systemImage: "tray.and.arrow.down")
      }
      .disabled(trimmed.isEmpty)
    }
    .navigationTitle("New To-Do")
    .navigationBarTitleDisplayMode(.inline)
    // Open straight into text entry — no tap on the field first. Defer the
    // focus to the next runloop: setting @FocusState inside onAppear fires
    // before the field is in the hierarchy on watchOS, so the input modal
    // never pops. A hop lets the keyboard/dictation come up on its own.
    .onAppear {
      DispatchQueue.main.async { focused = true }
    }
  }

  private func commit() {
    guard !trimmed.isEmpty else { return }
    conn.addInboxTask(title: trimmed)
    onDone()
  }
}

/// A short tappable list of method choices (V60 / Matcha / Other, Vape / Edible).
private struct QuickLogChoiceList: View {
  let choices: [SuggestionBlocks.Choice]
  /// Section accent for the method glyphs (falls back to orange).
  var tint: Color = .orange
  let onPick: (String) -> Void

  var body: some View {
    List(choices, id: \.value) { choice in
      Button { onPick(choice.value) } label: {
        HStack(spacing: 10) {
          if let emoji = choice.emoji, !emoji.isEmpty {
            Text(emoji).font(.body).frame(width: 22)
          } else if let symbol = choice.symbol {
            Image(systemName: symbol)
              .font(.body)
              .frame(width: 22)
              .foregroundStyle(tint)
          }
          Text(choice.label).font(.body)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
    }
    .listStyle(.plain)
  }
}

/// Mood quadrant colors + short labels for the watch picker. Mirrors the
/// phone's `MoodQuadrant` convention (yellow/red/blue/green; arousal vertical,
/// valence horizontal) but kept local — these are watch presentation, not the
/// shared affect *data* (that's `MoodVocabulary`).
private enum MoodQuadrantStyle {
  static func color(_ quadrant: String) -> Color {
    switch quadrant {
    case "hap": return .yellow   // high arousal, pleasant
    case "han": return .red      // high arousal, unpleasant
    case "lan": return .blue     // low arousal, unpleasant
    case "lap": return .green    // low arousal, pleasant
    default:    return .gray
    }
  }

  /// Two short lines (energy / valence) that fit a watch tile.
  static func label(_ quadrant: String) -> String {
    switch quadrant {
    case "hap": return "High\nPleasant"
    case "han": return "High\nUnpleasant"
    case "lan": return "Low\nUnpleasant"
    case "lap": return "Low\nPleasant"
    default:    return ""
    }
  }
}

/// Step 1 — the 2×2 valence×arousal grid. Same axes as the phone (top row
/// high-arousal, right column pleasant). Tapping a quadrant pushes its 3×3
/// emotion grid; the words come from `MoodVocabulary` (shared with the phone).
private struct MoodQuadrantGrid: View {
  let onPick: (MoodVocabulary.Emotion) -> Void

  private let columns = [GridItem(.flexible(), spacing: 6),
                         GridItem(.flexible(), spacing: 6)]

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 6) {
        // Canonical affect layout: han (top-left) hap (top-right),
        // lan (bottom-left) lap (bottom-right).
        ForEach(MoodVocabulary.quadrants, id: \.self) { quadrant in
          NavigationLink {
            MoodEmotionGrid(quadrant: quadrant, onPick: onPick)
          } label: {
            Text(MoodQuadrantStyle.label(quadrant))
              .font(.caption)
              .multilineTextAlignment(.center)
              .minimumScaleFactor(0.7)
              .frame(maxWidth: .infinity, minHeight: 56)
              .background(MoodQuadrantStyle.color(quadrant).opacity(0.30),
                          in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 4)
    }
  }
}

/// Step 2 — the chosen quadrant's 3×3 emotion grid (row 0 = high arousal,
/// col 0 = unpleasant), from `MoodVocabulary`. Tapping a word logs it.
private struct MoodEmotionGrid: View {
  let quadrant: String
  let onPick: (MoodVocabulary.Emotion) -> Void

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 4) {
        ForEach(MoodVocabulary.grid(for: quadrant), id: \.word) { emotion in
          Button { onPick(emotion) } label: {
            Text(emotion.word)
              .font(.caption2)
              .minimumScaleFactor(0.6)
              .lineLimit(1)
              .frame(maxWidth: .infinity, minHeight: 44)
              .background(MoodQuadrantStyle.color(quadrant).opacity(0.30),
                          in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 4)
    }
    .navigationTitle("Feeling")
    .navigationBarTitleDisplayMode(.inline)
  }
}
