import SwiftUI

/// Snapshot of a finished training session, captured at "Finish" tap
/// so the celebration sheet can render after the draft is discarded.
/// Mirrors the shape the webapp's `/training/session/done` page uses
/// (see `septena-app/app/(app)/septena/training/session/done/page.tsx`).
struct SessionStats: Identifiable {
  /// Per-presentation id so `.sheet(item:)` distinguishes back-to-back
  /// completions (rare, but defensive). Not a stable identity.
  let id = UUID()
  let routineLabel: String
  let kind: SessionKind
  /// The session bucket (date + type) so the completion sheet can persist a
  /// note via TrainingMutator.setSessionNote.
  let date: String
  let sessionType: String
  let startedAt: Date?
  let concludedAt: Date
  let doneCount: Int
  let skippedCount: Int
  let totalCount: Int
  let totalVolumeKg: Double          // weight × sets × reps, strength only
  let totalDurationMin: Double       // sum of cardio durations
  let totalDistanceM: Double
  let doneEntries: [DraftEntry]
  let prFlags: [String: PRFlags]     // keyed by entry.id (== exercise)

  struct PRFlags {
    let weight: Bool
    let distance: Bool
    let duration: Bool
    var any: Bool { weight || distance || duration }
  }

  var durationSeconds: Double? {
    guard let start = startedAt else { return nil }
    return max(0, concludedAt.timeIntervalSince(start))
  }

  /// Build the snapshot from a live draft. PR flags are computed by
  /// comparing each done entry against the draft's pre-session
  /// `prBaselines` — same data the in-session "PR" pill uses. Volume
  /// PRs are skipped; `PRBaseline` doesn't carry a max-volume figure
  /// so we'd need a separate sweep, not worth it for v1.
  init(from draft: DraftSession, kind: SessionKind) {
    self.routineLabel = draft.label
    self.kind = kind
    self.date = draft.date
    self.sessionType = draft.sessionType
    self.concludedAt = Date()

    let isoF = ISO8601DateFormatter()
    isoF.formatOptions = [.withInternetDateTime]
    self.startedAt = isoF.date(from: draft.startedAt)

    let done = draft.entries.filter { $0.status == .done }
    self.doneCount = done.count
    self.skippedCount = draft.entries.filter { $0.status == .skipped }.count
    self.totalCount = draft.entries.count
    self.doneEntries = done

    var volume: Double = 0
    var dur: Double = 0
    var dist: Double = 0
    for e in done where !e.isMobility {
      if e.isCardio {
        dur += e.durationMin ?? 0
        dist += e.distanceM ?? 0
      } else if let w = e.weight, let s = e.sets, let r = e.reps.flatMap(Int.init) {
        volume += w * Double(s) * Double(r)
      }
    }
    self.totalVolumeKg = volume
    self.totalDurationMin = dur
    self.totalDistanceM = dist

    var flags: [String: PRFlags] = [:]
    for e in done {
      let baseline = draft.prBaselines[exerciseKey(e.exercise)] ?? .empty
      guard baseline.hasHistory else { continue }    // first-ever attempt: not a PR
      let weightPR = !e.isCardio && !e.isMobility
        && (e.weight ?? 0) > 0
        && (baseline.bestWeight.map { (e.weight ?? 0) > $0 } ?? false)
      let distancePR = e.isCardio
        && (e.distanceM ?? 0) > 0
        && (baseline.bestDistanceM.map { (e.distanceM ?? 0) > $0 } ?? false)
      let durationPR = e.isCardio
        && (e.durationMin ?? 0) > 0
        && (baseline.bestDurationMin.map { (e.durationMin ?? 0) > $0 } ?? false)
      if weightPR || distancePR || durationPR {
        flags[e.id] = PRFlags(weight: weightPR,
                              distance: distancePR,
                              duration: durationPR)
      }
    }
    self.prFlags = flags
  }
}

/// "Session complete" celebration sheet. Shown after Finish so the
/// user gets a summary of what they just did — duration, totals,
/// PRs, the full logged list — before the draft is discarded. Mirrors
/// the webapp's `/training/session/done` page in content; takes the
/// iOS detent shape from the rest of the app's drawer flow.
struct SessionCompleteSheet: View {
  let stats: SessionStats
  let accent: Color
  let onDone: () -> Void
  /// Persist an optional session note (how it felt, niggles…). Called on
  /// "Back to dashboard" with the field's current text (empty clears).
  var onSaveNote: (String) -> Void = { _ in }

  /// Bumped on appear → fires the completion flourish. One celebration
  /// per presentation; no looping.
  @State private var celebrate = 0
  @State private var note = ""
  @AppStorage(EffortScale.storageKey) private var effortScaleRaw = EffortScale.difficulty.rawValue
  @AppStorage(WeightUnit.defaultsKey) private var weightUnitRaw = WeightUnit.kg.rawValue
  private var weightUnit: WeightUnit { WeightUnit.resolve(weightUnitRaw) }

  /// The logged rung rendered under the user's chosen scale, e.g. "Hard" or
  /// "RIR 1"; falls back to the raw string for anything unrecognized.
  private func effortText(_ raw: String) -> String {
    let scale = EffortScale(rawValue: effortScaleRaw) ?? .difficulty
    return TrainingEffort.displayLabel(forKey: raw, scale: scale) ?? raw
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        header
        statsGrid
        if !stats.doneEntries.isEmpty {
          loggedList
        }
        noteField
        Button(action: { onSaveNote(note); onDone() }) {
          Text("Back to dashboard")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
      }
      .padding(20)
    }
    .background(Theme.groupedBackground)
    .overlay {
      // Finishing a session is training's ONE celebration — the confetti
      // burst, every time (sets commit silently along the way). Intensity
      // still tells the story: louder per PR broken, scaled by volume on an
      // ordinary day.
      CommitFlourish(motion: completionMotion,
                     accent: accent,
                     intensity: completionIntensity,
                     trigger: celebrate)
    }
    .onAppear {
      // Motion-matched: the burst's pop at the same intensity the visual
      // plays — not a flat generic buzz.
      Haptics.play(completionMotion.hapticSpec(intensity: completionIntensity))
      celebrate += 1
    }
  }

  /// Optional note on the session — how it felt, niggles, a back-off set.
  /// Persisted to the session's concluding entry on "Back to dashboard".
  private var noteField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("NOTE")
        .font(.caption2.weight(.semibold)).tracking(1.5)
        .foregroundStyle(.secondary)
      TextField("How did it feel? Niggles, energy, anything to remember…",
                text: $note, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(2...5)
        .padding(12)
        .background(Theme.paperBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.secondary.opacity(0.15)))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Did any logged entry break a personal record this session?
  private var hasPR: Bool { stats.prFlags.values.contains { $0.any } }

  /// Session done → burst, always. (Was ripple-on-PR / bloom otherwise;
  /// the PR's extra payoff now lives in the intensity + the milestone
  /// layer's own ignition.)
  private var completionMotion: CommitMotion { .burst }

  /// PR sessions get louder with each record broken; non-PR sessions scale
  /// by total volume moved (a hard leg day blooms wider than a light one;
  /// cardio sessions, volume 0, settle to the gentle floor).
  private var completionIntensity: Double {
    if hasPR {
      let prCount = stats.prFlags.values.filter { $0.any }.count
      return min(1.5, 1.0 + 0.15 * Double(prCount))
    }
    return min(1.3, max(0.7, stats.totalVolumeKg / 3000))
  }

  // MARK: - Header

  private var header: some View {
    VStack(spacing: 6) {
      Text("SESSION COMPLETE")
        .font(.caption.weight(.semibold))
        .tracking(2)
        .foregroundStyle(accent)
      Image(systemName: stats.kind.icon)
        .scaledFont(size: 44, weight: .semibold, relativeTo: .largeTitle)
        .foregroundStyle(accent)
      Text("Nice work.")
        .font(.system(.title, design: .rounded).weight(.semibold))
      let skippedSuffix = stats.skippedCount > 0 ? ", \(stats.skippedCount) skipped" : ""
      Text("\(stats.routineLabel) — \(stats.doneCount) of \(stats.totalCount) exercises done\(skippedSuffix)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(.top, 20)
  }

  // MARK: - Stats grid

  /// Top row: duration / started / finished / exercises. Bottom row
  /// is category-specific — strength shows volume, cardio shows
  /// distance + avg pace, mobility just hides the bottom row.
  private var statsGrid: some View {
    VStack(spacing: 10) {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
        statTile(label: "Duration", value: formatDuration(stats.durationSeconds), prominent: true)
        statTile(label: "Exercises", value: "\(stats.doneCount)/\(stats.totalCount)")
        statTile(label: "Started", value: formatTime(stats.startedAt))
        statTile(label: "Finished", value: formatTime(stats.concludedAt))
      }
      categorySpecificTiles
    }
  }

  @ViewBuilder
  private var categorySpecificTiles: some View {
    if stats.kind == .mobility {
      EmptyView()
    } else if stats.kind == .cardio || (stats.totalDurationMin > 0 && stats.totalVolumeKg == 0) {
      // Cardio focus: distance + average pace.
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
        statTile(
          label: "Distance",
          value: formatDistance(stats.totalDistanceM),
          sub: "\(Int(stats.totalDurationMin)) min total"
        )
        statTile(
          label: "Avg pace",
          value: stats.totalDurationMin > 0
            ? "\(Int((stats.totalDistanceM / stats.totalDurationMin).rounded())) m/min"
            : "—"
        )
      }
    } else {
      // Strength / mixed: total volume + any cardio sidecar.
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
        statTile(
          label: "Volume",
          value: stats.totalVolumeKg > 0
            ? "\(Int(weightUnit.display(stats.totalVolumeKg).rounded())) \(weightUnit.suffix)" : "—",
          sub: "weight × sets × reps"
        )
        statTile(
          label: "Cardio",
          value: stats.totalDurationMin > 0
            ? "\(Int(stats.totalDurationMin)) min · \(formatDistance(stats.totalDistanceM))"
            : "—"
        )
      }
    }
  }

  private func statTile(label: String, value: String, sub: String? = nil, prominent: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label.uppercased())
        .font(.caption2.weight(.semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.title2, design: .rounded).weight(.semibold))
        .foregroundStyle(prominent ? accent : .primary)
        .monospacedDigit()
      if let sub {
        Text(sub).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(prominent ? accent.opacity(0.12) : Theme.cardSurface)
    )
  }

  // MARK: - Logged list

  private var loggedList: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("LOGGED")
        .font(.caption2.weight(.semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
      VStack(spacing: 6) {
        ForEach(stats.doneEntries, id: \.id) { entry in
          loggedRow(entry)
        }
      }
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Theme.cardSurface)
      )
    }
  }

  private func loggedRow(_ e: DraftEntry) -> some View {
    HStack(spacing: 8) {
      Text(CanonicalExerciseName.display(e.exercise))
        .font(.subheadline)
      if let pr = stats.prFlags[e.id] {
        if pr.weight   { prPill("PR \(weightUnit.suffix)") }
        if pr.distance { prPill("PR m") }
        if pr.duration { prPill("PR min") }
      }
      Spacer()
      Text(rowSummary(e))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  private func prPill(_ text: String) -> some View {
    Text(text)
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(accent.opacity(0.18), in: Capsule())
      .foregroundStyle(accent)
      .accessibilityLabel("Personal record")
  }

  private func rowSummary(_ e: DraftEntry) -> String {
    if e.isMobility {
      return e.difficulty.isEmpty ? "done" : effortText(e.difficulty)
    }
    var parts: [String] = []
    if e.isCardio {
      if let d = e.durationMin, d > 0 { parts.append("\(Int(d)) min") }
      if let m = e.distanceM, m > 0 { parts.append(formatDistance(m)) }
      if let l = e.level, l > 0 {
        parts.append("L\(l.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(l))" : l.decimalString())")
      }
    } else {
      if let s = e.sets, let r = e.reps { parts.append("\(s)×\(r)") }
      if let w = e.weight, w > 0 {
        let dw = weightUnit.display(w)
        parts.append("@ \(dw.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(dw))" : dw.decimalString()) \(weightUnit.suffix)")
      }
    }
    if !e.difficulty.isEmpty { parts.append(effortText(e.difficulty)) }
    return parts.isEmpty ? "done" : parts.joined(separator: " · ")
  }

  // MARK: - Formatters

  private func formatDuration(_ seconds: Double?) -> String {
    guard let s = seconds else { return "—" }
    let mins = Int((s / 60).rounded())
    if mins < 60 { return "\(mins) min" }
    return "\(mins / 60)h \(mins % 60)m"
  }

  private func formatTime(_ d: Date?) -> String {
    guard let d else { return "—" }
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: d)
  }

  private func formatDistance(_ m: Double) -> String {
    guard m > 0 else { return "—" }
    if m >= 1000 { return "\((m / 1000).decimalString(1)) km" }
    return "\(Int(m)) m"
  }
}
