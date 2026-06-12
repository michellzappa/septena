import SwiftUI

struct NextWatchView: View {
  @State private var conn = WatchConnectivity.shared
  @State private var quickLogItem: NextItem?
  @State private var capturing = false
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(conn.bucket.isEmpty ? "Next" : conn.bucket.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          // Capture a loggable (caffeine / cannabis / mood) on demand, not just
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
      VStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
          .font(.title2)
          .foregroundStyle(.green)
        Text("All done")
          .foregroundStyle(.secondary)
      }
    } else {
      List {
        ForEach(Array(conn.items.enumerated()), id: \.element.id) { index, item in
          // A thin section-accent rule wherever the group changes from the
          // previous row — the watch echo of iOS's tinted section headers.
          if index > 0,
             WatchSectionTint.key(for: item) != WatchSectionTint.key(for: conn.items[index - 1]) {
            sectionRule(for: item)
          }
          NextItemRow(item: item,
                      done: conn.completedIDs.contains(item.id),
                      onComplete: { conn.complete(item) },
                      onQuickLog: { quickLogItem = item })
          .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        }
      }
      .listStyle(.plain)
      .environment(\.defaultMinListRowHeight, 0)
      .animation(.default, value: conn.items)
    }
  }

  /// A 2pt rounded rule in the new group's section accent, sitting in its own
  /// (separator-free) list row between two adjacent groups.
  private func sectionRule(for item: NextItem) -> some View {
    Capsule()
      .fill(WatchSectionTint.color(for: item, colors: conn.sectionColors).opacity(0.7))
      .frame(height: 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 2, trailing: 6))
      .listRowBackground(Color.clear)
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
  /// to one group regardless of their `logKind` (caffeine / cannabis / mood).
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

  static func color(for item: NextItem, colors: [String: String]) -> Color {
    let k = key(for: item)
    // Suggestions aren't a section — keep the row's lightbulb / plus accent.
    if k == "suggestion" { return .orange }
    return color(forSectionKey: k, colors: colors)
  }

  /// Resolve a section's accent straight from its key (e.g. the Capture sheet's
  /// caffeine / cannabis / mood rows). Neutral when the section has no color.
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
/// list (caffeine / cannabis) or the mood quadrant grid. Picking writes the
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

        // The user's intake trackers, from the snapshot wire — every enabled
        // tracker is a + item, with container-aware choices. These supersede
        // the static caffeine/cannabis blocks below (kept for old payloads).
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

        // On-demand loggables (mood / hydration / gut — plus caffeine/cannabis
        // only while no trackers ride the wire), from the shared SuggestionBlocks
        // table.
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
      }
      .listStyle(.plain)
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
    // Open straight into text entry — no tap on the field first.
    .onAppear { focused = true }
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
