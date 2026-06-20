import SwiftUI

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
      if hasNutrition || hasTraining {
        List {
          allDoneHero
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 14, leading: 6, bottom: 8, trailing: 6))
            .listRowBackground(Color.clear)
          summaryLinkRows
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
      } else {
        allDoneHero
      }
    } else {
      // Snapshot the enumerated items once per render and read group boundaries
      // from this local copy — never from live `conn.items` by index. Rapid
      // wrist taps mutate `conn.items` (optimistic completion removals plus the
      // post-write reconcile) while the List is mid-animation; a row closure
      // re-evaluated against the now-shorter live array would index out of
      // bounds. The captured copy stays consistent for the life of the closure.
      let rows = Array(conn.items.enumerated())
      List {
        ForEach(rows, id: \.element.id) { index, item in
          // A section header — accent rule plus a count label — at the start of
          // each group: the first row, or wherever the group changes from the
          // row above. The watch echo of iOS's tinted section headers.
          if index == 0 ||
             WatchSectionTint.key(for: item) != WatchSectionTint.key(for: rows[index - 1].element) {
            sectionHeader(for: item, at: index, in: rows)
          }
          NextItemRow(item: item,
                      done: conn.completedIDs.contains(item.id),
                      onComplete: { conn.complete(item) },
                      onQuickLog: { quickLogItem = item })
          .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        }
        summaryLinkRows
      }
      .listStyle(.plain)
      .environment(\.defaultMinListRowHeight, 0)
      .animation(.default, value: conn.items)
    }
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

  private func sectionAvailable(_ key: String) -> Bool {
    if !conn.enabledSections.isEmpty { return conn.enabledSections.contains(key) }
    return true
  }

  /// Foot-of-feed links to the macro / training summary pages — the same pages
  /// the complications open. Shown only for sections the snapshot has data for,
  /// under a quiet header so they read as a footer, not another task group.
  @ViewBuilder
  private var summaryLinkRows: some View {
    if hasNutrition || hasTraining {
      Text("Summaries")
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .listRowInsets(EdgeInsets(top: 10, leading: 6, bottom: 2, trailing: 6))
        .listRowBackground(Color.clear)
      if hasNutrition {
        summaryLink(.nutrition, title: "Macros", systemImage: "fork.knife",
                    color: WatchSectionTint.color(forSectionKey: "nutrition", colors: conn.sectionColors))
      }
      if hasTraining {
        summaryLink(.training, title: "Training", systemImage: "figure.strengthtraining.traditional",
                    color: WatchSectionTint.color(forSectionKey: "training", colors: conn.sectionColors))
      }
    }
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
  }

  /// A group header in its own (separator-free) list row: a 2pt rule in the
  /// group's section accent, plus an accent-tinted count caption ("3 tasks").
  /// Renders before every group, so each section is labelled — not just the
  /// boundaries between adjacent groups.
  private func sectionHeader(for item: NextItem, at index: Int,
                             in rows: [(offset: Int, element: NextItem)]) -> some View {
    let accent = WatchSectionTint.color(for: item, colors: conn.sectionColors)
    return VStack(alignment: .leading, spacing: 3) {
      Capsule()
        .fill(accent.opacity(0.7))
        .frame(height: 2)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(sectionLabel(startingAt: index, in: rows))
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(accent)
        .lineLimit(1)
    }
    // The very first header hugs the top; later ones get more breathing room
    // above to read as a fresh group rather than another row.
    .listRowInsets(EdgeInsets(top: index == 0 ? 2 : 8, leading: 6, bottom: 2, trailing: 6))
    .listRowBackground(Color.clear)
  }

  /// "3 tasks" — the count of contiguous rows in the group that begins at
  /// `index`, with the section's own noun. Counting the run (rather than every
  /// matching row) stays correct even if a section key were ever to recur.
  private func sectionLabel(startingAt index: Int,
                            in rows: [(offset: Int, element: NextItem)]) -> String {
    let key = WatchSectionTint.key(for: rows[index].element)
    var count = 0
    var i = index
    while i < rows.count, WatchSectionTint.key(for: rows[i].element) == key {
      count += 1
      i += 1
    }
    return "\(count) \(WatchSectionTint.noun(forKey: key, count: count))"
  }
}

// MARK: - Section accent palette (watch)

/// Resolves a Next row to its section's accent for the group rule. The watch
/// has no `SectionTheme` (that's phone/Mac, CloudKit-backed), so the *actual*
/// per-section colors ride in on the snapshot (`NextItemsResponse.sectionColors`)
/// and are parsed here. A row whose section has no color — or a section we
/// can't resolve — gets a neutral rule rather than a guessed tint. All
/// suggestions share one band, like the phone's single `NextSuggestionsSection`.
private enum WatchSectionTint {
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

  static func color(for item: NextItem, colors: [String: String]) -> Color {
    let k = key(for: item)
    // Suggestions aren't a section — keep the row's lightbulb / plus accent.
    if k == "suggestion" { return .orange }
    return color(forSectionKey: k, colors: colors)
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

  private var isSuggestion: Bool { item.kind == "suggestion" }
  /// A suggestion that can be logged from a tap (carries a `SuggestionBlocks`
  /// kind in `logKind`). Other suggestions stay read-only nudges.
  private var isActionableSuggestion: Bool { isSuggestion && item.logKind != nil }

  var body: some View {
    if isActionableSuggestion {
      // Quick-log nudge: tap opens the method / mood picker.
      Button(action: { onQuickLog?() }) { rowBody }
        .buttonStyle(.plain)
    } else if isSuggestion {
      // Read-only nudge (training / fast-break for now).
      rowBody
    } else {
      // Checklist member: tap to complete.
      Button(action: onComplete) { rowBody }
        .buttonStyle(.plain)
    }
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
          .foregroundStyle(.orange)
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
    if isSuggestion { return .orange }
    // Overdue is carried by the trailing warning marker (below), not by
    // reddening the kind glyph — matches the widget's chore treatment.
    return .secondary
  }

  private var kindIcon: String {
    switch item.kind {
    case "suggestion": return "lightbulb"
    case "task":       return "circle"
    case "habit":      return "repeat.circle"
    case "supplement": return "pill"
    case "chore":      return "house"
    default:           return "circle"
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
        if let block = item.logKind.flatMap({ SuggestionBlocks.byKind[$0] }) {
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
  let onDone: () -> Void

  var body: some View {
    let methods = kind.methods.map {
      ConsumableContainer.Method(token: $0.token, label: $0.label,
                                 symbol: $0.symbol, usesContainer: $0.usesContainer)
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
      conn.logIntake(kind: kind, value: value, itemID: "adhoc:intake:\(kind.id)")
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
private struct MealPickerView: View {
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
          if let symbol = choice.symbol {
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
