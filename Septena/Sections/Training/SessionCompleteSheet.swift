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

  /// Bumped on appear → fires `ConfettiBurst`. One celebration per
  /// presentation; no looping.
  @State private var celebrate = 0

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        header
        statsGrid
        if !stats.doneEntries.isEmpty {
          loggedList
        }
        Button(action: onDone) {
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
    .overlay(alignment: .top) {
      // Bigger burst than the per-rep one — celebration scaled to the
      // moment but still single-tone, still bounded duration.
      ConfettiBurst(trigger: celebrate, accent: accent,
                    count: 28, duration: 1.4)
        .frame(height: 1)            // anchor only; particles fan from here
        .offset(y: 80)
    }
    .onAppear {
      Haptics.success()
      celebrate += 1
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(spacing: 6) {
      Text("SESSION COMPLETE")
        .font(.caption.weight(.semibold))
        .tracking(2)
        .foregroundStyle(accent)
      Image(systemName: stats.kind.icon)
        .font(.system(size: 44, weight: .semibold))
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
            ? "\(Int(stats.totalVolumeKg.rounded())) kg" : "—",
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
      Text(e.exercise)
        .font(.subheadline)
      if let pr = stats.prFlags[e.id] {
        if pr.weight   { prPill("PR kg") }
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
      return e.difficulty.isEmpty ? "done" : e.difficulty
    }
    var parts: [String] = []
    if e.isCardio {
      if let d = e.durationMin, d > 0 { parts.append("\(Int(d)) min") }
      if let m = e.distanceM, m > 0 { parts.append(formatDistance(m)) }
      if let l = e.level, l > 0 {
        parts.append("L\(l.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(l))" : String(format: "%.1f", l))")
      }
    } else {
      if let s = e.sets, let r = e.reps { parts.append("\(s)×\(r)") }
      if let w = e.weight, w > 0 {
        parts.append("@ \(w.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(w))" : String(format: "%.1f", w)) kg")
      }
    }
    if !e.difficulty.isEmpty { parts.append(e.difficulty) }
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
    if m >= 1000 { return String(format: "%.1f km", m / 1000) }
    return "\(Int(m)) m"
  }
}
