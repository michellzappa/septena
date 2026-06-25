import SwiftUI

// In-app detail pages for the macro and training ring complications — the pages
// their `widgetURL` taps open, and the same pages reachable from the foot of the
// Next list. They render the phone-computed rings held on `WatchConnectivity`
// (the snapshot's `nutritionRings` / `trainingRings`), reusing the complication's
// shared `RingsView` + `MacroStyle` / `TrainingStyle` so the page and the
// complication can't drift. The watch carries no nutrition / training model.

/// A pushable summary page. Drives `NextWatchView`'s `navigationDestination`,
/// set both by the foot-of-feed links and by the complication deep links.
enum WatchPage: Hashable {
  case nutrition
  case training
  case intake
}

// MARK: - Nutrition (today's macros)

struct NutritionDetailView: View {
  let conn: WatchConnectivity
  /// Presents the most-eaten-meals picker — the same one-tap quick-log the
  /// Capture sheet's "Log a meal" row opens, surfaced contextually here.
  @State private var loggingMeal = false

  /// The canonical five in order, backfilling any the snapshot hasn't sent with
  /// empty tracks — so the page reads as "macros" even before the first sync
  /// (mirrors the complication's `rings`).
  private var rings: [ComplicationRing] {
    RingMetrics.canonical(order: MacroStyle.order, from: conn.nutritionRings)
  }

  private var accent: Color {
    WatchSectionTint.color(forSectionKey: "nutrition", colors: conn.sectionColors)
  }

  /// The fasting context only when the live state machine says we're *actually*
  /// fasting right now — the context is published whenever fasting is tracked, so
  /// gate it here exactly as the complication face does, else a fed daytime would
  /// wrongly take over the page.
  private var liveFast: FastingComplication? {
    guard let f = conn.fasting, f.liveState(now: Date()).isFasting else { return nil }
    return f
  }

  var body: some View {
    Group {
      if let fast = liveFast {
        // A live fast takes over the whole page — the complication's tap target
        // shows the fast the face is showing, not a list of zero macros (an
        // overnight fast has no meals logged yet). Mirrors the face's morph.
        FastingDetailPage(fast: fast)
      } else {
        RingSummaryPage(
          // Draw kcal/protein/carbs/fat (fiber stays legend-only) — same set the
          // circular complication draws.
          drawnRings: Array(rings.prefix(4)),
          legendRings: rings,
          color: MacroStyle.color,
          label: MacroStyle.label,
          unit: MacroStyle.unit,
          isEmpty: conn.nutritionRings.isEmpty,
          emptyHint: "No meals logged today",
          recent: conn.recentNutrition,
          recentTitle: "Recent meals")
      }
    }
    .navigationTitle(liveFast == nil ? "Nutrition" : "Fasting")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      // Contextual quick-log: re-log one of the user's most-eaten meals straight
      // from the nutrition page, tinted to the section accent. Gated on the
      // phone having published meals (same condition as the Capture sheet's row).
      if !conn.topMeals.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Button { loggingMeal = true } label: {
            Image(systemName: "plus")
          }
          .tint(accent)
        }
      }
    }
    .sheet(isPresented: $loggingMeal) {
      NavigationStack {
        MealPickerView(meals: conn.topMeals, conn: conn) { loggingMeal = false }
      }
    }
    // Direct deep-link launches mount this page under the Next root; the root's
    // `.task` fetches, but pull once more here if we arrived before any data.
    .task { if conn.nutritionRings.isEmpty && conn.fasting == nil { conn.fetchNext() } }
  }
}

/// A live fast as the whole nutrition summary page — a big ring filling toward
/// the target with the elapsed hours centered, then the since / goal labels.
/// Mirrors the macro complication's fasting morph and the phone's Nutrition tile,
/// so a fast never reads as "0 protein". Ticks every minute via `TimelineView`,
/// and the ring laps past 100% once the fast exceeds its target.
private struct FastingDetailPage: View {
  let fast: FastingComplication

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { ctx in
      let elapsed = max(0, ctx.date.timeIntervalSince(fast.lastMealAt))
      let totalMin = Int(elapsed) / 60
      let h = totalMin / 60, m = totalMin % 60
      let tint = FastingStyle.color(fast.colorHex)
      let ring = ComplicationRing(key: "fasting",
                                  value: elapsed / 3600,
                                  goal: max(fast.targetHours, 0.1),
                                  colorHex: fast.colorHex)
      ScrollView {
        VStack(spacing: 12) {
          ZStack {
            RingsView(rings: [ring], color: { _ in tint }, lineWidth: 10, spacing: 0)
              .frame(width: 112, height: 112)
            VStack(spacing: -1) {
              Text("\(h)")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
              Text(m > 0 ? "h \(m)m" : "h")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.top, 6)

          VStack(spacing: 4) {
            Label("Fasting", systemImage: "hourglass")
              .font(.caption).fontWeight(.semibold)
              .foregroundStyle(tint)
            Text("since \(fast.sinceLabel)")
              .font(.caption2).foregroundStyle(.secondary)
            Text("\(Int(fast.targetHours.rounded()))h goal")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
      }
    }
  }
}

// MARK: - Training (this week)

struct TrainingDetailView: View {
  let conn: WatchConnectivity

  private var rings: [ComplicationRing] {
    RingMetrics.canonical(order: TrainingStyle.order, from: conn.trainingRings)
  }

  var body: some View {
    RingSummaryPage(
      drawnRings: rings,
      legendRings: rings,
      color: TrainingStyle.color,
      label: TrainingStyle.label,
      unit: TrainingStyle.unit,
      isEmpty: conn.trainingRings.isEmpty,
      emptyHint: "No training logged this week",
      recent: conn.recentTraining,
      recentTitle: "Recent sets")
    .navigationTitle("This week")
    .navigationBarTitleDisplayMode(.inline)
    .task { if conn.trainingRings.isEmpty { conn.fetchNext() } }
  }
}

// MARK: - Intake (today's tally)

/// A dead-simple "what I've had today" page — one row per intake tracker logged
/// today (its glyph, name, and an ×N tally with an optional noun summary). No
/// rings or goals; intake is a log, not a target. Reads the phone-computed
/// `intakeToday` tally off the snapshot, so the watch carries no intake model.
struct IntakeDetailView: View {
  let conn: WatchConnectivity

  /// One row per *enabled* tracker (from `intakeKinds`, always on the snapshot),
  /// each carrying today's tally — `×0` for a tracker not logged yet. So the page
  /// reads as a full "what I track" list with today's counts, not just the
  /// subset that happens to have an event today. Falls back to the today-only
  /// tally if the kind list hasn't synced (older snapshot).
  private var rows: [IntakeTodayWire] {
    guard !conn.intakeKinds.isEmpty else { return conn.intakeToday }
    let logged = Dictionary(conn.intakeToday.map { ($0.id, $0) },
                            uniquingKeysWith: { a, _ in a })
    return conn.intakeKinds.map { k in
      logged[k.id] ?? IntakeTodayWire(id: k.id, name: k.name, symbol: k.symbol,
                                      color: k.color, count: 0, detail: nil)
    }
  }

  var body: some View {
    Group {
      if rows.isEmpty {
        ScrollView {
          Text("No intake trackers")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
      } else {
        List(rows) { row in
          IntakeTallyRow(row: row)
            .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
            .watchSkyRow()
        }
        .listStyle(.plain)
        .watchSkyList()
      }
    }
    .navigationTitle("Today")
    .navigationBarTitleDisplayMode(.inline)
    .task { if conn.intakeKinds.isEmpty && conn.intakeToday.isEmpty { conn.fetchNext() } }
  }
}

/// One intake tracker's tally row: glyph + name on the left, the count summary
/// (the noun line if the wire carried one, else "×N") on the right.
private struct IntakeTallyRow: View {
  let row: IntakeTodayWire

  private var tint: Color {
    // Resolve like the Capture menu's intake glyphs — handles hex / hsl / rgb
    // tokens and lifts dark colors for the always-dark watch canvas.
    WatchSectionTint.color(forSectionKey: row.id,
                           colors: row.color.map { [row.id: $0] } ?? [:])
  }

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: row.symbol ?? "circle.fill")
        .font(.body)
        .foregroundStyle(tint)
        .frame(width: 18)
      Text(row.name)
        .font(.body)
        .lineLimit(1)
      Spacer(minLength: 4)
      Text(row.detail ?? "×\(row.count)")
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
  }
}

// MARK: - Shared page layout

/// The big ring stack on top, then one legend row per metric. Generic over the
/// per-key style closures so the macro and training pages share the layout.
private struct RingSummaryPage: View {
  let drawnRings: [ComplicationRing]
  let legendRings: [ComplicationRing]
  let color: (String) -> Color
  let label: (String) -> String
  let unit: (String) -> String
  let isEmpty: Bool
  let emptyHint: String
  /// The most-recent logged rows, listed under the legend so the user can confirm
  /// the snapshot is current. Empty → the section is omitted.
  var recent: [RecentLogWire] = []
  var recentTitle: String = ""

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {

        // Show only rings with real data — an unlogged metric (e.g. 0/12 sets)
        // would otherwise draw a full dim "shadow" track; the legend below still
        // lists every target, so nothing is lost by dropping the empty ring.
        RingsView(rings: drawnRings, color: color, lineWidth: 7, spacing: 3,
                  hidesEmptyRings: true)
          .frame(width: 108, height: 108)
          .padding(.top, 4)

        VStack(spacing: 7) {
          ForEach(legendRings, id: \.key) { ring in
            RingLegendRow(ring: ring,
                          label: label(ring.key),
                          unit: unit(ring.key),
                          color: Color(hexToken: ring.colorHex) ?? color(ring.key))
          }
        }

        if isEmpty {
          Text(emptyHint)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
        }

        if !recent.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text(recentTitle.uppercased())
              .font(.caption2)
              .foregroundStyle(.secondary)
            ForEach(recent) { row in
              RecentLogRow(row: row)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
        }
      }
      .padding(.horizontal, 6)
      .padding(.bottom, 8)
    }
  }
}

/// One recently-logged row: emoji + name on the left, the metric summary and the
/// "when" stacked on the right — a glanceable "last logged" line so the user can
/// tell whether the wrist is showing the latest data.
private struct RecentLogRow: View {
  let row: RecentLogWire

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if let emoji = row.emoji, !emoji.isEmpty {
        Text(emoji).font(.caption)
      }
      Text(row.title)
        .font(.caption)
        .lineLimit(1)
        // Claim the title's full width first so a long "when" stamp
        // ("Yesterday 10:50") shrinks/truncates before the title does — the
        // name is what the row is for; the timestamp is secondary.
        .layoutPriority(1)
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 1) {
        if let detail = row.detail, !detail.isEmpty {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(row.when)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      .minimumScaleFactor(0.7)
    }
  }
}

/// One metric's row: a color dot, its label, the value/goal readout, and a slim
/// progress bar filling toward the goal (a faint track when no goal is set).
private struct RingLegendRow: View {
  let ring: ComplicationRing
  let label: String
  let unit: String
  let color: Color

  private var fraction: Double {
    guard let goal = ring.goal, goal > 0 else { return 0 }
    return min(ring.value / goal, 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 8, height: 8)
        Text(label)
          .font(.caption)
          .lineLimit(1)
        Spacer(minLength: 4)
        HStack(spacing: 2) {
          Text("\(Int(ring.value.rounded()))")
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(color)
          if let goal = ring.goal {
            Text("/ \(Int(goal.rounded()))")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          if !unit.isEmpty {
            Text(unit)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      }

      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(color.opacity(0.22))
          Capsule().fill(color).frame(width: geo.size.width * fraction)
        }
      }
      .frame(height: 4)
    }
  }
}

// MARK: - Helpers

private enum RingMetrics {
  /// Return the canonical metrics in `order`, backfilling any the snapshot
  /// hasn't sent yet with empty (no-goal) tracks.
  static func canonical(order: [String], from rings: [ComplicationRing]) -> [ComplicationRing] {
    let byKey = Dictionary(rings.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    return order.map { byKey[$0] ?? ComplicationRing(key: $0, value: 0, goal: nil) }
  }
}
