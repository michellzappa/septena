import SwiftUI

// Training mini-app — historical log of exercise entries grouped by
// session (date + session-type pair). Uses the new LogRow since entries
// aren't checklist items; they're records of what already happened.
// Header summary: this week's session count + Z2 minutes vs target.

struct TrainingDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(NavigationState.self) private var nav

  @State private var entries: [ExerciseEntry] = []
  @State private var cardio: CardioHistoryResponse? = nil
  @State private var loading = true

  private var accent: Color { theme.color(for: "training") }

  /// Group entries by (date, session). Server returns most-recent first
  /// already, so just preserve first-appearance order per session key.
  private var sessions: [SessionBlock] {
    var order: [String] = []
    var byKey: [String: [ExerciseEntry]] = [:]
    for e in entries {
      let key = "\(e.date)|\(e.session)"
      if byKey[key] == nil { order.append(key) }
      byKey[key, default: []].append(e)
    }
    return order.map { key in
      let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
      return SessionBlock(date: String(parts[0]),
                          session: parts.count > 1 ? String(parts[1]) : "",
                          entries: byKey[key] ?? [])
    }
  }

  var body: some View {
    List {
      summary
      ForEach(sessions, id: \.key) { block in
        Section {
          ForEach(block.entries) { entry in
            LogRow(
              title: entry.exercise ?? "—",
              detail: detailLine(entry),
              trailing: entry.loggedAt.map(timeOnly),
              accent: accent
            )
            .listRowInsets(EdgeInsets())
          }
        } header: {
          HStack {
            Text(block.session.capitalized.isEmpty ? "Session" : block.session.capitalized)
            Spacer()
            Text(friendlyDate(block.date))
              .foregroundStyle(.secondary)
          }
        }
      }
      if !loading && entries.isEmpty {
        ContentUnavailableView("No entries yet",
                               systemImage: "figure.strengthtraining.traditional",
                               description: Text("Log a session in the webapp to see it here."))
      }
    }
    .listStyle(.insetGrouped)
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Training")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task { await load() }
    .refreshable { await load() }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          nav.showTrainingSession = true
        } label: {
          Label("Start session", systemImage: "play.fill")
        }
        .tint(accent)
      }
    }
  }

  // MARK: - Summary

  private var summary: some View {
    let sessionsThisWeek = uniqueSessionDates(thisWeek: true).count
    let z2 = Int(cardio?.daily.reduce(0) { $0 + $1.minutes } ?? 0)
    let target = cardio?.targetWeeklyMin ?? 150
    return Section {
      HStack(alignment: .top, spacing: 24) {
        stat(value: "\(sessionsThisWeek)", label: "sessions", tint: accent)
        stat(value: "\(z2)", label: "Z2 min", tint: accent, unit: "m")
        Spacer()
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Z2 CARDIO")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
          Spacer()
          Text("\(z2)/\(target)m").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        ProgressView(value: Double(min(z2, target)),
                     total: Double(max(target, 1)))
          .tint(accent)
      }
    }
  }

  private func stat(value: String, label: String, tint: Color, unit: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(value)
          .font(.system(.title2, design: .rounded).weight(.semibold))
          .foregroundStyle(tint)
        if let unit {
          Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }

  // MARK: - Loading

  private func load() async {
    loading = true
    let since = sinceDate(daysBack: 14)
    async let e: [ExerciseEntry]? = try? await client.trainingEntries(since: since)
    async let c: CardioHistoryResponse? = try? await client.trainingCardioHistory(days: 7)
    let (entriesRes, cardioRes) = await (e, c)
    entries = entriesRes ?? []
    cardio = cardioRes
    loading = false
  }

  // MARK: - Helpers

  private struct SessionBlock {
    let date: String
    let session: String
    let entries: [ExerciseEntry]
    var key: String { "\(date)|\(session)" }
  }

  /// Build a detail line that adapts to the entry shape — strength rows
  /// favor weight × sets × reps; cardio favors duration · distance.
  private func detailLine(_ e: ExerciseEntry) -> String? {
    var parts: [String] = []
    if let w = e.weight, w > 0 {
      parts.append(formatWeight(w))
    }
    if let s = e.sets, let r = e.reps {
      parts.append("\(s)×\(r)")
    } else if let r = e.reps {
      parts.append(r)
    }
    if let d = e.durationMin, d > 0 {
      parts.append("\(Int(d)) min")
    }
    if let m = e.distanceM, m > 0 {
      parts.append(formatDistance(m))
    }
    if let lvl = e.level, lvl > 0 {
      parts.append("L\(Int(lvl))")
    }
    if let diff = e.difficulty, !diff.isEmpty {
      parts.append(diff)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func formatWeight(_ w: Double) -> String {
    w.truncatingRemainder(dividingBy: 1) == 0
      ? "\(Int(w))kg"
      : String(format: "%.1fkg", w)
  }

  private func formatDistance(_ m: Double) -> String {
    m >= 1000
      ? String(format: "%.1f km", m / 1000)
      : "\(Int(m)) m"
  }

  private func timeOnly(_ ts: String) -> String {
    // Server returns ISO8601 like "2026-05-17T07:42:11" — grab HH:MM.
    if let tIdx = ts.firstIndex(of: "T") {
      let after = ts.index(after: tIdx)
      let end = ts.index(after, offsetBy: 5, limitedBy: ts.endIndex) ?? ts.endIndex
      return String(ts[after..<end])
    }
    return ts
  }

  /// "Today" / "Yesterday" / weekday name / full date — same vocabulary as
  /// the rest of the app's date display.
  private func friendlyDate(_ iso: String) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.timeZone = .current
    guard let d = fmt.date(from: iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d)     { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: d, to: Date()).day ?? 0
    if days < 7 {
      let weekday = DateFormatter()
      weekday.dateFormat = "EEEE"
      return weekday.string(from: d)
    }
    let pretty = DateFormatter()
    pretty.dateFormat = "MMM d"
    return pretty.string(from: d)
  }

  private func sinceDate(daysBack: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    return fmt.string(from: d)
  }

  /// Unique YYYY-MM-DD dates among entries, optionally restricted to the
  /// current calendar week.
  private func uniqueSessionDates(thisWeek: Bool) -> Set<String> {
    guard thisWeek else { return Set(entries.map(\.date)) }
    let cal = Calendar.current
    let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                      from: Date())) ?? Date()
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    let cutoff = fmt.string(from: weekStart)
    return Set(entries.map(\.date).filter { $0 >= cutoff })
  }
}

// MARK: - Draft store
//
// One in-progress training session, persisted to UserDefaults as JSON so a
// background-kill or crash mid-workout doesn't lose progress. Mirrors the
// webapp's IndexedDB draft. Per-entry saves are POSTed as the user marks
// each exercise "Done" — `TrainingDestinationView` then refreshes and the
// new entries roll into the historical log immediately.

@MainActor
@Observable
final class TrainingDraftStore {
  private static let key = "septena.training.draft"

  /// Cached session-types from the server. Empty until first fetch.
  var sessionTypes: [SessionTypeConfig] = []
  /// Days since the last session of each type — feeds the palette's
  /// "Last 2d ago" badges. Keyed by type id ("upper", "cardio", ...).
  var daysAgo: [String: Int] = [:]
  /// Server-suggested next type, if any.
  var suggested: String? = nil

  /// Currently active draft. Nil when no session is in flight.
  var draft: DraftSession?

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.key),
       let decoded = try? JSONDecoder().decode(DraftSession.self, from: data) {
      draft = decoded
    }
  }

  // MARK: - Persistence

  private func persist() {
    guard let draft else {
      UserDefaults.standard.removeObject(forKey: Self.key)
      return
    }
    if let data = try? JSONEncoder().encode(draft) {
      UserDefaults.standard.set(data, forKey: Self.key)
    }
  }

  // MARK: - Catalog

  /// Pull session-type config + suggestion in parallel. Cheap to call on
  /// palette open; tolerates missing endpoints by leaving lists empty.
  func refreshCatalog(client: SeptenaClient) async {
    async let types = try? await client.sessionTypes()
    async let sw    = try? await client.suggestedWorkout()
    let (t, s) = await (types, sw)
    if let t { sessionTypes = t }
    if let s {
      daysAgo = s.daysAgo
      suggested = s.suggested?.type
    }
  }

  // MARK: - Start / discard

  /// Build a fresh draft for `type`, pre-filling each exercise from the
  /// user's last entry for it. Replaces any existing draft.
  func start(type: SessionTypeConfig, client: SeptenaClient) async {
    let exercises = type.exercises
    let last: [String: LastEntryValues] =
      (try? await client.lastEntries(exercises: exercises)) ?? [:]
    let entries = exercises.map { ex in
      DraftEntry.from(exercise: ex, last: last[ex])
    }
    let now = Date()
    let timeF = DateFormatter()
    timeF.dateFormat = "HH:mm"
    timeF.locale = Locale(identifier: "en_US_POSIX")
    let isoF = ISO8601DateFormatter()
    isoF.formatOptions = [.withInternetDateTime]
    draft = DraftSession(
      date: SeptenaDate.today,
      time: timeF.string(from: now),
      sessionType: type.id,
      emoji: type.emoji,
      label: type.label,
      entries: entries,
      startedAt: isoF.string(from: now),
      updatedAt: isoF.string(from: now)
    )
    persist()
  }

  func discard() {
    draft = nil
    persist()
  }

  // MARK: - Mutate

  func update(_ patch: (inout DraftSession) -> Void) {
    guard var d = draft else { return }
    patch(&d)
    let isoF = ISO8601DateFormatter()
    isoF.formatOptions = [.withInternetDateTime]
    d.updatedAt = isoF.string(from: Date())
    draft = d
    persist()
  }

  /// POST one entry to the backend and flip its status to `done` on
  /// success / `failed` on error. Mirrors the webapp's per-exercise save.
  func markDone(index: Int, client: SeptenaClient) async {
    guard let d = draft, d.entries.indices.contains(index) else { return }
    update { $0.entries[index].status = .saving }
    do {
      var entry = d.entries[index]
      entry.status = .done
      let written = try await client.postTrainingSession(
        date: d.date, time: d.time, sessionType: d.sessionType,
        entries: [entry]
      )
      update {
        $0.entries[index].status = .done
        $0.entries[index].savedFile = written.first
      }
    } catch {
      SeptenaLog.error("training save failed", error)
      update { $0.entries[index].status = .failed }
    }
  }

  func markSkipped(index: Int) {
    update {
      guard $0.entries.indices.contains(index) else { return }
      $0.entries[index].status = .skipped
    }
  }
}

// MARK: - Session logger UI
//
// Webapp parity: header with elapsed / cardio / lifted stats; per-exercise
// expandable cards with weight/sets/reps (strength) or duration/distance/
// level (cardio); incremental save on "Done"; resume-after-crash via the
// `TrainingDraftStore`'s UserDefaults persistence. Lives as a sheet over
// the dashboard so the user can swipe away and come back without losing
// state.

struct TrainingSessionView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(TrainingDraftStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  /// Re-render the elapsed counter once per minute. Cheap and avoids a
  /// timer goroutine flickering the whole sheet.
  @State private var tick = Date()

  private var accent: Color { theme.color(for: "training") }

  var body: some View {
    NavigationStack {
      Group {
        if store.draft != nil {
          logger
        } else {
          picker
        }
      }
      .background(Theme.paperBackground)
      .navigationTitle(store.draft.map { "\($0.emoji ?? "💪") \($0.label)" } ?? "Start training")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
        if store.draft != nil {
          ToolbarItem(placement: .primaryAction) {
            Button("Finish") { finish() }
              .tint(accent)
              .bold()
          }
        }
      }
      .tint(accent)
    }
    .task {
      if store.sessionTypes.isEmpty {
        await store.refreshCatalog(client: client)
      }
    }
  }

  // MARK: - Type picker (no draft yet)

  private var picker: some View {
    List {
      if store.sessionTypes.isEmpty {
        Section { ProgressView() }
      } else {
        Section("Pick a session") {
          ForEach(store.sessionTypes) { type in
            Button { start(type) } label: {
              HStack(spacing: 12) {
                Text(type.emoji ?? "💪").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                  Text(type.label).font(.septenaTaskTitle)
                    .foregroundStyle(Theme.inkPrimary)
                  if let d = store.daysAgo[type.id] {
                    Text(d == 0 ? "Today" :
                         d == 1 ? "1 day ago" : "\(d) days ago")
                      .font(.septenaMeta)
                      .foregroundStyle(Theme.inkSecondary)
                  } else {
                    Text("No prior session")
                      .font(.septenaMeta)
                      .foregroundStyle(Theme.inkSecondary)
                  }
                }
                Spacer()
                if store.suggested == type.id {
                  Text("Suggested")
                    .font(.septenaBadge)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(accent.opacity(0.18),
                                in: Capsule())
                    .foregroundStyle(accent)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #else
    .listStyle(.inset)
    #endif
  }

  // MARK: - Logger (active draft)

  @ViewBuilder
  private var logger: some View {
    if let d = store.draft {
      List {
        statsHeader(d)
        Section {
          ForEach(Array(d.entries.enumerated()), id: \.element.exercise) { idx, e in
            TrainingExerciseCard(
              index: idx,
              entry: e,
              accent: accent
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
          }
        }
      }
      #if os(iOS)
      .listStyle(.insetGrouped)
      #else
      .listStyle(.inset)
      #endif
      .onAppear { tick = Date() }
    }
  }

  private func statsHeader(_ d: DraftSession) -> some View {
    let elapsed = elapsedMinutes(since: d.startedAt)
    let lifted = d.entries
      .filter { $0.status == .done && !$0.isCardio }
      .reduce(0.0) { acc, e in
        let s = Double(e.sets ?? 0)
        let r = Double(e.reps.flatMap { Int($0) } ?? 0)
        return acc + (e.weight ?? 0) * s * r
      }
    let cardio = d.entries
      .filter { $0.status == .done && $0.isCardio }
      .reduce(0.0) { $0 + ($1.durationMin ?? 0) }
    return Section {
      HStack(alignment: .top, spacing: 24) {
        stat(value: "\(elapsed)", label: "elapsed", unit: "m")
        stat(value: "\(Int(cardio))", label: "cardio", unit: "m")
        stat(value: "\(Int(lifted))", label: "lifted", unit: "kg")
        Spacer()
      }
      let done = d.doneCount
      let total = max(d.totalCount, 1)
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("PROGRESS")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer()
          Text("\(done)/\(total)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        ProgressView(value: Double(done), total: Double(total))
          .tint(accent)
      }
    }
  }

  private func stat(value: String, label: String, unit: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(value)
          .font(.system(.title2, design: .rounded).weight(.semibold))
          .foregroundStyle(accent)
        if let unit {
          Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }

  // MARK: - Actions

  private func start(_ type: SessionTypeConfig) {
    Task { await store.start(type: type, client: client) }
  }

  private func finish() {
    store.discard()
    dismiss()
  }

  /// Whole-minute elapsed since the ISO8601 `startedAt`. Cheap re-eval on
  /// each render; we don't bother with sub-minute precision.
  private func elapsedMinutes(since iso: String) -> Int {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    guard let start = f.date(from: iso) else { return 0 }
    return max(0, Int(Date().timeIntervalSince(start) / 60))
  }
}

// MARK: - Exercise card

/// Expandable per-exercise card in the active session. Collapsed shows the
/// summary; tapping expands to weight/sets/reps inputs (or duration/
/// distance/level for cardio) plus the difficulty pills and a Done button.
struct TrainingExerciseCard: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(TrainingDraftStore.self) private var store

  let index: Int
  let entry: DraftEntry
  let accent: Color

  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if expanded { editor }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.cardSurface)
    )
    .opacity(opacityFor(entry.status))
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      statusIcon
        .foregroundStyle(statusTint)
        .font(.system(size: 18, weight: .regular))
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.exercise.capitalized)
          .font(.septenaCardTitle)
          .foregroundStyle(Theme.inkPrimary)
        if let s = summaryLine {
          Text(s)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
        }
      }
      Spacer()
      Image(systemName: expanded ? "chevron.up" : "chevron.down")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.inkSecondary)
    }
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch entry.status {
    case .pending: Image(systemName: "circle")
    case .saving:  ProgressView().controlSize(.small)
    case .done:    Image(systemName: "checkmark.circle.fill")
    case .failed:  Image(systemName: "exclamationmark.triangle.fill")
    case .skipped: Image(systemName: "minus.circle")
    }
  }

  private var statusTint: Color {
    switch entry.status {
    case .done:    return accent
    case .failed:  return .red
    case .skipped: return Theme.inkSecondary
    default:       return Theme.inkSecondary
    }
  }

  private func opacityFor(_ status: DraftEntry.Status) -> Double {
    switch status {
    case .done:    return 0.75
    case .skipped: return 0.45
    default:       return 1
    }
  }

  private var summaryLine: String? {
    var parts: [String] = []
    if entry.isCardio {
      if let d = entry.durationMin, d > 0 { parts.append("\(Int(d)) min") }
      if let m = entry.distanceM, m > 0 {
        parts.append(m >= 1000 ? String(format: "%.1f km", m/1000) : "\(Int(m)) m")
      }
      if let l = entry.level, l > 0 { parts.append("L\(l)") }
    } else {
      if let w = entry.weight, w > 0 {
        parts.append(w.truncatingRemainder(dividingBy: 1) == 0
                     ? "\(Int(w))kg" : String(format: "%.1fkg", w))
      }
      if let s = entry.sets, let r = entry.reps { parts.append("\(s)×\(r)") }
      if !entry.difficulty.isEmpty { parts.append(entry.difficulty) }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: - Editor (expanded)

  @ViewBuilder
  private var editor: some View {
    Divider().padding(.vertical, 10)
    if entry.isCardio {
      cardioInputs
    } else {
      strengthInputs
      difficultyPicker
    }
    HStack(spacing: 8) {
      Button("Skip") {
        store.markSkipped(index: index)
        expanded = false
      }
      .buttonStyle(.bordered)
      .tint(.secondary)
      Spacer()
      Button(entry.status == .failed ? "Retry"
             : entry.status == .done ? "Update" : "Done") {
        Task {
          await store.markDone(index: index, client: client)
          if entry.status != .failed { expanded = false }
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(accent)
      .disabled(entry.status == .saving)
    }
    .padding(.top, 12)
  }

  // MARK: - Strength fields

  private var strengthInputs: some View {
    HStack(spacing: 10) {
      numberField(label: "Weight", unit: "kg",
                  value: Binding(
                    get: { entry.weight.map { fmt($0) } ?? "" },
                    set: { setWeight($0) }
                  ))
      numberField(label: "Sets",
                  value: Binding(
                    get: { entry.sets.map(String.init) ?? "" },
                    set: { setSets(Int($0)) }
                  ))
      numberField(label: "Reps",
                  value: Binding(
                    get: { entry.reps ?? "" },
                    set: { setReps($0) }
                  ))
    }
  }

  private var difficultyPicker: some View {
    HStack(spacing: 6) {
      ForEach(["easy", "medium", "hard"], id: \.self) { d in
        Button {
          store.update { $0.entries[index].difficulty = d }
        } label: {
          Text(d.capitalized)
            .font(.septenaMetaStrong)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
              entry.difficulty == d ? accent.opacity(0.22) : Theme.mutedSurface,
              in: Capsule()
            )
            .foregroundStyle(entry.difficulty == d ? accent : Theme.inkSecondary)
        }
        .buttonStyle(.plain)
      }
      Spacer()
    }
    .padding(.top, 8)
  }

  // MARK: - Cardio fields

  private var cardioInputs: some View {
    HStack(spacing: 10) {
      numberField(label: "Duration", unit: "min",
                  value: Binding(
                    get: { entry.durationMin.map { fmt($0) } ?? "" },
                    set: { setDuration($0) }
                  ))
      numberField(label: "Distance", unit: "m",
                  value: Binding(
                    get: { entry.distanceM.map { fmt($0) } ?? "" },
                    set: { setDistance($0) }
                  ))
      numberField(label: "Level",
                  value: Binding(
                    get: { entry.level.map(String.init) ?? "" },
                    set: { setLevel(Int($0)) }
                  ))
    }
  }

  // MARK: - Field helpers

  private func numberField(label: String,
                           unit: String? = nil,
                           value: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(spacing: 4) {
        TextField("", text: value)
          #if os(iOS)
          .keyboardType(.decimalPad)
          #endif
          .textFieldStyle(.plain)
          .font(.system(.title3, design: .rounded).weight(.medium))
        if let unit {
          Text(unit).font(.septenaMeta).foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 8)
      .background(Theme.mutedSurface,
                  in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
  }

  private func fmt(_ d: Double) -> String {
    d.truncatingRemainder(dividingBy: 1) == 0
      ? String(Int(d)) : String(format: "%.1f", d)
  }

  private func setWeight(_ s: String) {
    store.update { $0.entries[index].weight = Double(s.replacingOccurrences(of: ",", with: ".")) }
  }
  private func setSets(_ v: Int?) {
    store.update { $0.entries[index].sets = v }
  }
  private func setReps(_ s: String) {
    store.update { $0.entries[index].reps = s.isEmpty ? nil : s }
  }
  private func setDuration(_ s: String) {
    store.update { $0.entries[index].durationMin = Double(s.replacingOccurrences(of: ",", with: ".")) }
  }
  private func setDistance(_ s: String) {
    store.update { $0.entries[index].distanceM = Double(s.replacingOccurrences(of: ",", with: ".")) }
  }
  private func setLevel(_ v: Int?) {
    store.update { $0.entries[index].level = v }
  }
}
