import Foundation

// Import a training history exported from another app.
//
// Every one of these apps exports the same thing in a different dialect: one
// row per *set*, carrying a date, an exercise name, and some mix of
// weight/reps/distance/time. So this reads a column map built from the header
// rather than fixed positions — a new app is usually a few header aliases
// rather than another importer.
//
// Header shapes this was written against:
//   FitNotes (Android) Date,Exercise,Category,Weight,Weight Unit,Reps,Distance,
//                      Distance Unit,Time,Comment
//   FitNotes 2 (iOS)   Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,
//                      Distance,Distance Unit,Time,Notes,Kind
//   Strong             Date,Workout Name,Duration,Exercise Name,Set Order,
//                      Weight,Reps,Distance,Seconds,Notes,Workout Notes,RPE
//   Hevy               title,start_time,end_time,description,exercise_title,
//                      superset_id,exercise_notes,set_index,set_type,weight_kg,
//                      reps,distance_km,duration_seconds,rpe
// Anything else falls through to loose header matching, which covers
// spreadsheet round-trips as long as the file has a date, an exercise name and
// something measured.
//
// **The shape mismatch is the whole design problem.** Those apps store one row
// per set; `ExerciseEntryEntity` stores one row per (exercise, session) with an
// aggregate `sets`/`reps`/`weight`. So identical consecutive sets are collapsed
// — 3 rows of 60 kg × 10 become one entry of `sets: "3", reps: "10", weight: 60`
// — and a pyramid stays three entries of one set each. That is lossless in the
// only sense that matters here: replaying the entries reproduces the same work.
//
// Nothing in this file touches SwiftData or the UI. It reads text and returns a
// plan; the caller previews the plan, then writes it. Nothing throws on a bad
// row either — a history of several thousand sets will contain oddities, and
// losing the file over one of them helps nobody. Bad rows are counted and
// reported instead.

// MARK: - Output

/// One exercise within an imported session — the shape `TrainingEntryDraft`
/// wants, kept separate so the parser stays free of the mutator layer.
public struct ImportedExerciseEntry: Hashable, Sendable {
  public var exercise: String
  public var weight: Double?        // always kg; the file's unit is resolved on the way in
  public var sets: String?
  public var reps: String?
  public var difficulty: String?    // canonical rung: easy | moderate | hard | max
  public var durationMin: Double?
  public var distanceM: Double?
  public var note: String?
  /// False when the name didn't resolve to anything in the catalog or the
  /// curated library, so the caller knows to create a definition for it.
  public var isKnownExercise: Bool
}

/// One training day from the file. Foreign exporters group by workout; we group
/// by date, because that is what `concludedAt` groups by on our side.
public struct ImportedSession: Hashable, Sendable {
  public var date: String           // YYYY-MM-DD
  public var time: String           // HH:MM, "12:00" when the file carries no clock
  public var sessionType: String    // strength | cardio | mobility
  public var name: String?          // the exporter's workout name, if any
  public var entries: [ImportedExerciseEntry]
}

/// Everything the preview needs to describe the file before anything is written.
public struct TrainingImportPlan: Sendable {
  public var source: String?              // "Hevy", "Strong", … nil when unrecognized
  public var sessions: [ImportedSession]
  public var setRows: Int                 // set-level rows successfully read
  public var skippedRows: Int             // rows with no date, no name, or nothing measured
  public var warmupRows: Int              // dropped on purpose — see `isWarmup`
  public var knownNames: [String]         // distinct names that resolved
  public var unknownNames: [String]       // distinct names that didn't
  public var declaredUnit: WeightImportUnit?  // what the file itself said, if anything
  public var mixedUnits: Bool
  public var ratedSets: Int               // sets that carried an RPE/RIR we could map
  public var from: String?
  public var to: String?

  public var sessionCount: Int { sessions.count }
  public var entryCount: Int { sessions.reduce(0) { $0 + $1.entries.count } }
}

public enum WeightImportUnit: String, Sendable, CaseIterable, Identifiable {
  case kg, lb
  public var id: String { rawValue }
  public var label: String { self == .kg ? "kg" : "lb" }
}

public enum TrainingImportError: Error, Equatable {
  /// Fewer than two lines, or nothing but blanks.
  case empty
  /// No column that reads as a date, or none that reads as an exercise name.
  case unrecognized
}

// MARK: - Parser

public enum TrainingHistoryImport {

  /// Read an export into sessions, without touching state.
  ///
  /// `knownExerciseKeys` is the set of `exerciseKey` values the app already
  /// knows — the user's catalog plus the curated library — passed in so this
  /// stays a pure function. `assumedUnit` only applies to rows that declare no
  /// unit of their own (Strong writes a bare `Weight` column whose unit lives
  /// in that app's settings, not in the file), and the caller is expected to
  /// show which unit it assumed rather than silently rewriting someone's
  /// numbers.
  public static func plan(csv text: String,
                          knownExerciseKeys: Set<String>,
                          assumedUnit: WeightImportUnit) throws -> TrainingImportPlan {
    let rows = parseCSV(text)
    guard rows.count >= 2 else { throw TrainingImportError.empty }
    let header = rows[0]
    let map = mapHeader(header)
    let source = detectSource(header)
    let dateField: Column? = map[.date] != nil ? .date : (map[.startTime] != nil ? .startTime : nil)
    guard let dateField, map[.exercise] != nil else { throw TrainingImportError.unrecognized }

    var days: [String: DayAccumulator] = [:]
    var dayOrder: [String] = []
    var known = Set<String>(), unknown = Set<String>()
    var setRows = 0, skipped = 0, warmups = 0, rated = 0
    var sawKg = false, sawLb = false

    func cell(_ row: [String], _ column: Column) -> String {
      guard let i = map[column], i < row.count else { return "" }
      return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    for row in rows.dropFirst() {
      let rawName = cell(row, .exercise)
      guard !rawName.isEmpty, let when = parseWhen(cell(row, dateField)) else {
        skipped += 1
        continue
      }

      // An explicit kg/lb column beats a generic column plus a unit column,
      // which in turn beats the caller's assumption.
      var rawWeight = 0.0
      var rowUnit: WeightImportUnit?
      if !cell(row, .weightKg).isEmpty {
        rawWeight = number(cell(row, .weightKg)); rowUnit = .kg
      } else if !cell(row, .weightLb).isEmpty {
        rawWeight = number(cell(row, .weightLb)); rowUnit = .lb
      } else {
        rawWeight = number(cell(row, .weight))
        let u = cell(row, .weightUnit).lowercased()
        if u.hasPrefix("lb") { rowUnit = .lb } else if u.hasPrefix("kg") { rowUnit = .kg }
      }
      if rowUnit == .kg { sawKg = true }
      if rowUnit == .lb { sawLb = true }

      let reps = Int(number(cell(row, .reps)).rounded())
      let seconds = number(cell(row, .seconds))
      // A per-set duration comes from `Seconds`. A `Duration`/`Time` column is
      // only per-set when the file has no seconds column (FitNotes) — in Strong,
      // which has both, `Duration` is the *whole workout* ("2h 38m") repeated on
      // every row, and reading it as a set would turn a stray zero-rep row into
      // a 158-minute cardio session.
      let minutes: Double
      if seconds > 0 {
        minutes = (seconds / 60 * 10).rounded() / 10
      } else if map[.seconds] == nil {
        minutes = minutesFrom(cell(row, .time))
      } else {
        minutes = 0
      }
      let meters = !cell(row, .distanceKm).isEmpty
        ? number(cell(row, .distanceKm)) * 1000
        : metersFrom(cell(row, .distance), unit: cell(row, .distanceUnit))

      guard rawWeight != 0 || reps > 0 || minutes > 0 || meters > 0 else {
        skipped += 1
        continue
      }
      // A warm-up set is dropped rather than imported. We have no per-set
      // warm-up flag, so an imported warm-up would be indistinguishable from a
      // working set and would inflate every set count and muscle-volume figure
      // it touched. Counted so the summary can say how many went.
      if cell(row, .setType).lowercased().contains("warm") {
        warmups += 1
        continue
      }

      let weightKg = convert(rawWeight, from: rowUnit ?? assumedUnit)
      // Reps decide the shape: a row with reps is strength work even when it
      // also carries a duration (a timed set), and a row without them that
      // measured distance or time is cardio.
      let isCardio = reps <= 0 && (meters > 0 || minutes > 0)

      let name = cleanedName(rawName)
      let matched = resolve(name: rawName, against: knownExerciseKeys)
      let exercise = matched ?? name
      if matched != nil { known.insert(exercise) } else { unknown.insert(exercise) }

      // Effort rides along only where it means something — a weighted rep set.
      // A treadmill row with an RPE has nowhere to put it on our side.
      var difficulty: String?
      if !isCardio {
        difficulty = effortRung(rir: cell(row, .rir), rpe: cell(row, .rpe))
        if difficulty != nil { rated += 1 }
      }

      let day: DayAccumulator
      if let existing = days[when.date] {
        day = existing
      } else {
        day = DayAccumulator(time: when.time ?? "12:00")
        days[when.date] = day
        dayOrder.append(when.date)
      }
      if day.name == nil {
        let workout = cell(row, .workoutName)
        if !workout.isEmpty { day.name = workout }
      }
      day.add(exercise: exercise,
              known: matched != nil,
              weightKg: isCardio ? nil : (rawWeight > 0 ? weightKg : nil),
              reps: isCardio ? nil : (reps > 0 ? reps : nil),
              difficulty: difficulty,
              durationMin: isCardio ? (minutes > 0 ? minutes : nil) : nil,
              distanceM: isCardio ? (meters > 0 ? meters : nil) : nil,
              isCardio: isCardio)
      setRows += 1
    }

    let ordered = dayOrder.sorted()
    let sessions = ordered.compactMap { date -> ImportedSession? in
      guard let day = days[date] else { return nil }
      return day.session(date: date)
    }.filter { !$0.entries.isEmpty }

    return TrainingImportPlan(
      source: source,
      sessions: sessions,
      setRows: setRows,
      skippedRows: skipped,
      warmupRows: warmups,
      knownNames: known.sorted(),
      unknownNames: unknown.sorted(),
      declaredUnit: sawKg && sawLb ? nil : (sawKg ? .kg : (sawLb ? .lb : nil)),
      mixedUnits: sawKg && sawLb,
      ratedSets: rated,
      from: sessions.first?.date,
      to: sessions.last?.date
    )
  }

  // MARK: Session accumulation

  /// Collapses set rows into our per-exercise shape as they arrive.
  ///
  /// A class rather than a struct because it is mutated through a dictionary
  /// lookup in a hot loop, and copying the whole day's work per row to write one
  /// set back is exactly the kind of quadratic surprise a several-thousand-row
  /// import cannot afford.
  private final class DayAccumulator {
    /// The key identical sets collapse on. Difficulty is part of it: three sets
    /// at 60×10 where the last one went to failure is genuinely two prescriptions,
    /// and merging them would throw the rating away.
    struct StrengthKey: Hashable {
      let exercise: String
      let weight: Double?
      let reps: Int?
      let difficulty: String?
    }

    let time: String
    var name: String?
    private var order: [StrengthKey] = []
    private var counts: [StrengthKey: Int] = [:]
    private var known: [String: Bool] = [:]
    /// Cardio doesn't collapse — it sums. Two 15-minute rows are half an hour of
    /// work, not "2 sets of cardio".
    private var cardioOrder: [String] = []
    private var cardioMinutes: [String: Double] = [:]
    private var cardioMeters: [String: Double] = [:]
    private var sawCardio = false
    private var sawStrength = false

    init(time: String) { self.time = time }

    func add(exercise: String,
             known isKnown: Bool,
             weightKg: Double?,
             reps: Int?,
             difficulty: String?,
             durationMin: Double?,
             distanceM: Double?,
             isCardio: Bool) {
      known[exercise] = (known[exercise] ?? false) || isKnown
      if isCardio {
        sawCardio = true
        if cardioMinutes[exercise] == nil && cardioMeters[exercise] == nil {
          cardioOrder.append(exercise)
        }
        if let durationMin { cardioMinutes[exercise, default: 0] += durationMin }
        if let distanceM { cardioMeters[exercise, default: 0] += distanceM }
        return
      }
      sawStrength = true
      let key = StrengthKey(exercise: exercise, weight: weightKg,
                            reps: reps, difficulty: difficulty)
      if counts[key] == nil { order.append(key) }
      counts[key, default: 0] += 1
    }

    func session(date: String) -> ImportedSession {
      var entries: [ImportedExerciseEntry] = order.map { key in
        ImportedExerciseEntry(
          exercise: key.exercise,
          weight: key.weight,
          sets: String(counts[key] ?? 1),
          reps: key.reps.map(String.init),
          difficulty: key.difficulty,
          durationMin: nil,
          distanceM: nil,
          note: nil,
          isKnownExercise: known[key.exercise] ?? false
        )
      }
      entries += cardioOrder.map { exercise in
        ImportedExerciseEntry(
          exercise: exercise,
          weight: nil,
          sets: nil,
          reps: nil,
          difficulty: nil,
          durationMin: cardioMinutes[exercise].map { ($0 * 10).rounded() / 10 },
          distanceM: cardioMeters[exercise].map { $0.rounded() },
          note: nil,
          isKnownExercise: known[exercise] ?? false
        )
      }
      // The exporter's workout name ("Push Day") rides on the last entry, which
      // is where this app already keeps a session note.
      if let name, !name.isEmpty, !entries.isEmpty {
        entries[entries.count - 1].note = name
      }
      // Ids `SessionKind.defaulted(for:)` already recognizes, so an imported
      // session gets the right glyph and input shape without inventing a
      // catalog row the user never made.
      let type = sawStrength ? "strength" : (sawCardio ? "cardio" : "strength")
      return ImportedSession(date: date, time: time, sessionType: type,
                             name: name, entries: entries)
    }
  }

  // MARK: Exercise name resolution

  /// Foreign name → a name this app already knows, or nil.
  ///
  /// Our catalog is alias-rich and its names are unqualified ("Bench Press",
  /// with "barbell-bench-press" among its aliases), while the exporters bolt
  /// the equipment on in parentheses — Hevy writes "Bench Press (Barbell)",
  /// Strong "Squat (Barbell)". So the candidates are tried widest-first: the
  /// name as written, the name with the parenthetical dropped, and the
  /// parenthetical moved to the front, which is how our aliases spell it.
  ///
  /// No fuzzy fallback on purpose. Guessing between "Bench Press" and "Incline
  /// Bench Press" would file years of training under the wrong lift, which is
  /// worse than leaving it as its own exercise the user can see and merge.
  static func resolve(name raw: String, against known: Set<String>) -> String? {
    for candidate in candidateKeys(for: raw) where known.contains(candidate.key) {
      return candidate.display
    }
    return nil
  }

  /// `(key, display)` pairs to try, in order. The display half is what gets
  /// stored when that candidate hits, so a match on the qualified form keeps
  /// the qualified name.
  static func candidateKeys(for raw: String) -> [(key: String, display: String)] {
    let cleaned = cleanedName(raw)
    var out: [(String, String)] = [(exerciseKey(cleaned), cleaned)]

    let (base, qualifier) = splitQualifier(raw)
    if !base.isEmpty, base != cleaned {
      out.append((exerciseKey(base), base))
    }
    if !qualifier.isEmpty, !base.isEmpty {
      let leading = "\(qualifier) \(base)"
      out.append((exerciseKey(leading), leading))
      // "(DB)" and friends — the exporters use the same shorthand our aliases do.
      let expanded = expandShorthand(leading)
      if expanded != leading { out.append((exerciseKey(expanded), expanded)) }
    }
    let expandedCleaned = expandShorthand(cleaned)
    if expandedCleaned != cleaned { out.append((exerciseKey(expandedCleaned), expandedCleaned)) }

    var seen = Set<String>()
    return out.filter { !$0.0.isEmpty && seen.insert($0.0).inserted }
      .map { (key: $0.0, display: $0.1) }
  }

  /// "Bench Press (Barbell)" → ("Bench Press", "Barbell"). Empty qualifier when
  /// there are no parentheses.
  private static func splitQualifier(_ raw: String) -> (base: String, qualifier: String) {
    guard let open = raw.firstIndex(of: "("),
          let close = raw[open...].firstIndex(of: ")") else {
      return (cleanedName(raw), "")
    }
    let inner = String(raw[raw.index(after: open)..<close])
    var outer = raw
    outer.removeSubrange(open...close)
    return (cleanedName(outer), cleanedName(inner))
  }

  /// Collapse whitespace and drop the punctuation the exporters sprinkle in.
  /// Kept readable rather than slugged — an unmatched name is shown to the user
  /// and becomes a catalog entry, so it has to look like something a person
  /// wrote.
  static func cleanedName(_ raw: String) -> String {
    let stripped = raw.replacingOccurrences(of: "[()\\[\\]]", with: " ",
                                            options: .regularExpression)
    return stripped.split(whereSeparator: { $0 == " " || $0 == "\t" })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let shorthand: [(String, String)] = [
    ("bb", "Barbell"), ("db", "Dumbbell"), ("kb", "Kettlebell"),
    ("ohp", "Overhead Press"), ("bw", "Bodyweight"), ("rdl", "Romanian Deadlift"),
    ("ez", "EZ Bar"), ("smith machine", "Smith"),
  ]

  private static func expandShorthand(_ name: String) -> String {
    var words = name.split(separator: " ").map(String.init)
    for i in words.indices {
      let lower = words[i].lowercased()
      if let hit = shorthand.first(where: { $0.0 == lower }) { words[i] = hit.1 }
    }
    return words.joined(separator: " ")
  }

  // MARK: Effort

  /// An RPE/RIR out of someone else's export, folded onto our four rungs.
  ///
  /// Two traps, both of them zeroes. A blank cell is "not rated" and has to stay
  /// absent rather than becoming a rating. And 0 means opposite things on the
  /// two scales: RIR 0 is a set taken to failure and is the single most
  /// informative value in the file, while RPE has no 0 (the scale runs 6–10), so
  /// an app writing 0 there means "nothing here" and must not be read as an
  /// effort. RPE is converted to RIR first so there is one bucketing rule, and
  /// the buckets match `TrainingEffort`: max ↔ 0, hard ↔ 1, moderate ↔ 2,
  /// easy ↔ 3 or more.
  static func effortRung(rir rawRIR: String, rpe rawRPE: String) -> String? {
    var reserve: Double?
    if let v = effortValue(rawRIR, zeroIsARating: true) {
      reserve = v
    } else if let v = effortValue(rawRPE, zeroIsARating: false) {
      reserve = max(0, 10 - v)
    }
    guard let reserve else { return nil }
    switch reserve {
    case ..<0.5:  return "max"
    case ..<1.5:  return "hard"
    case ..<2.5:  return "moderate"
    default:      return "easy"
    }
  }

  private static func effortValue(_ raw: String, zeroIsARating: Bool) -> Double? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    let n = number(s)
    guard n.isFinite, n >= 0, !(n == 0 && !zeroIsARating) else { return nil }
    return min(10, n)
  }

  // MARK: Scalars

  private static let poundsInKilo = 0.45359237

  private static func convert(_ value: Double, from unit: WeightImportUnit) -> Double {
    guard unit == .lb else { return (value * 100).rounded() / 100 }
    return (value * poundsInKilo * 100).rounded() / 100
  }

  /// Tolerant number read: a comma decimal separator is the norm in half the
  /// exports people actually have, and a stray unit suffix shouldn't lose a set.
  static func number(_ raw: String) -> Double {
    let cleaned = raw.replacingOccurrences(of: ",", with: ".")
      .filter { $0.isNumber || $0 == "." || $0 == "-" }
    return Double(cleaned) ?? 0
  }

  /// "HH:MM:SS" · "MM:SS" · "2h 38m" · "90" → minutes.
  static func minutesFrom(_ raw: String) -> Double {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return 0 }
    if s.contains(":") {
      let parts = s.split(separator: ":").map { Int($0.filter(\.isNumber)) ?? 0 }
      let seconds = parts.count == 3
        ? parts[0] * 3600 + parts[1] * 60 + parts[2]
        : (parts.count == 2 ? parts[0] * 60 + parts[1] : parts[0])
      return (Double(seconds) / 60 * 10).rounded() / 10
    }
    // Strong writes a workout duration as "2h 38m".
    let lower = s.lowercased()
    if lower.contains("h") || lower.contains("m") {
      var hours = 0.0, mins = 0.0
      var digits = ""
      for ch in lower {
        if ch.isNumber || ch == "." { digits.append(ch) }
        else if ch == "h" { hours = Double(digits) ?? 0; digits = "" }
        else if ch == "m" { mins = Double(digits) ?? 0; digits = "" }
        else if !ch.isWhitespace { digits = "" }
      }
      if hours > 0 || mins > 0 { return hours * 60 + mins }
    }
    return (number(s) * 10).rounded() / 10
  }

  private static let distanceInMeters: [String: Double] = [
    "m": 1, "meter": 1, "meters": 1, "km": 1000, "kilometer": 1000, "kilometers": 1000,
    "cm": 0.01, "in": 0.0254, "ft": 0.3048, "yd": 0.9144,
    "mi": 1609.344, "mile": 1609.344, "miles": 1609.344,
  ]

  static func metersFrom(_ raw: String, unit: String) -> Double {
    let value = number(raw)
    guard value != 0 else { return 0 }
    let key = unit.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    // No unit column at all: these exports write kilometres, not metres.
    let factor = distanceInMeters[key] ?? (key.isEmpty ? 1000 : 1)
    return (value * factor).rounded()
  }

  // MARK: Dates

  struct ParsedWhen { let date: String; let time: String? }

  private static let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5,
                                   "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10,
                                   "nov": 11, "dec": 12]

  /// "2020-12-30 18:51:52" · "2024-03-07" · "22 Dec 2025, 08:00" · "07/03/2024".
  static func parseWhen(_ raw: String) -> ParsedWhen? {
    let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !v.isEmpty else { return nil }

    if let m = match(v, #"^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{2}))?"#) {
      return when(y: m[1], mo: m[2], d: m[3], h: m[4], mi: m[5])
    }
    if let m = match(v, #"^(\d{1,2})\s+([A-Za-z]{3})[a-z]*\.?\s+(\d{4})(?:,?\s+(\d{1,2}):(\d{2}))?"#),
       let mo = monthNames[m[2].lowercased()] {
      return when(y: m[3], mo: String(mo), d: m[1], h: m[4], mi: m[5])
    }
    if let m = match(v, #"^([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})(?:,?\s+(\d{1,2}):(\d{2}))?"#),
       let mo = monthNames[m[1].lowercased()] {
      return when(y: m[3], mo: String(mo), d: m[2], h: m[4], mi: m[5])
    }
    // Day-first when ambiguous: FitNotes, Strong and Hevy all write unambiguous
    // dates, so a bare numeric one arrived via a spreadsheet, and those are
    // usually European.
    if let m = match(v, #"^(\d{1,2})[/.](\d{1,2})[/.](\d{4})(?:[, ]+(\d{1,2}):(\d{2}))?"#) {
      let a = Int(m[1]) ?? 1, b = Int(m[2]) ?? 1
      let day = a > 12 ? a : (b > 12 ? b : a)
      let month = day == a ? b : a
      return when(y: m[3], mo: String(month), d: String(day), h: m[4], mi: m[5])
    }
    return nil
  }

  private static func when(y: String, mo: String, d: String, h: String, mi: String) -> ParsedWhen? {
    guard let year = Int(y), let month = Int(mo), let day = Int(d),
          (1...12).contains(month), (1...31).contains(day) else { return nil }
    let date = String(format: "%04d-%02d-%02d", year, month, day)
    guard let hour = Int(h), let minute = Int(mi),
          (0...23).contains(hour), (0...59).contains(minute) else {
      return ParsedWhen(date: date, time: nil)
    }
    return ParsedWhen(date: date, time: String(format: "%02d:%02d", hour, minute))
  }

  /// Capture groups as strings, absent groups as "". Nil when no match.
  private static func match(_ s: String, _ pattern: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    else { return nil }
    return (0..<m.numberOfRanges).map { i in
      guard let r = Range(m.range(at: i), in: s) else { return "" }
      return String(s[r])
    }
  }

  // MARK: Header mapping

  enum Column: Hashable {
    case exercise, date, startTime, workoutName, category
    case weight, weightKg, weightLb, weightUnit
    case reps, rpe, rir
    case distance, distanceKm, distanceUnit, seconds, time
    case setType, note
  }

  /// Header text → the field it means. Specific names first; first match wins,
  /// so a file with both "Weight (kg)" and "Weight" resolves the explicit one.
  private static let columnAliases: [(Column, [String])] = [
    (.exercise, ["exercise", "exercise name", "exercise title"]),
    (.date, ["date", "workout date"]),
    (.startTime, ["start time"]),
    (.workoutName, ["workout name", "title"]),
    (.category, ["category", "body part", "muscle group"]),
    (.weightKg, ["weight kg"]),
    (.weightLb, ["weight lbs", "weight lb"]),
    (.weight, ["weight"]),
    (.weightUnit, ["weight unit", "unit"]),
    (.reps, ["reps", "repetitions"]),
    // Hevy and Strong both write an RPE per set. Nothing mainstream exports
    // RIR, but read it where it is there rather than dropping the column.
    (.rpe, ["rpe", "rpe rating"]),
    (.rir, ["rir", "reps in reserve"]),
    (.distanceKm, ["distance km"]),
    (.distance, ["distance"]),
    (.distanceUnit, ["distance unit"]),
    (.seconds, ["seconds", "duration seconds"]),
    (.time, ["time", "duration"]),
    (.setType, ["set type"]),
    (.note, ["comment", "comments", "notes", "note"]),
  ]

  private static func normalizeHeader(_ h: String) -> String {
    let lowered = h.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
    return String(lowered).split(separator: " ").joined(separator: " ")
  }

  private static func mapHeader(_ header: [String]) -> [Column: Int] {
    var map: [Column: Int] = [:]
    for (i, raw) in header.enumerated() {
      let n = normalizeHeader(raw)
      for (column, names) in columnAliases where map[column] == nil && names.contains(n) {
        map[column] = i
        break
      }
    }
    return map
  }

  /// The app a header looks like, shown back to the user so they can sanity-check
  /// what was read before anything is written.
  static func detectSource(_ header: [String]) -> String? {
    let h = Set(header.map(normalizeHeader))
    if h.contains("exercise title") && h.contains("set index") { return "Hevy" }
    if h.contains("exercise name") && h.contains("set order") { return "Strong" }
    if h.contains("exercise") && h.contains("kind") { return "FitNotes (iOS)" }
    if h.contains("exercise") && (h.contains("weight unit") || h.contains("category")) { return "FitNotes" }
    return nil
  }

  // MARK: CSV

  /// A real CSV reader: quoted fields, embedded commas and newlines, doubled
  /// quotes, BOM and CRLF. Splitting on commas breaks on the first exercise
  /// named "Bench Press, Close Grip" — and a whole history would import shifted
  /// by one column without ever erroring, which is the worst possible failure
  /// for something the user is trusting with years of data.
  static func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    let iterator = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
    var i = 0

    func endField() { row.append(field); field = "" }
    func endRow() {
      endField()
      if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
      row = []
    }

    while i < iterator.count {
      let c = iterator[i]
      if quoted {
        if c == "\"" {
          if i + 1 < iterator.count && iterator[i + 1] == "\"" { field.append("\""); i += 1 }
          else { quoted = false }
        } else {
          field.append(c)
        }
      } else if c == "\"" {
        quoted = true
      } else if c == "," {
        endField()
      } else if c == "\n" || c == "\r" {
        if c == "\r" && i + 1 < iterator.count && iterator[i + 1] == "\n" { i += 1 }
        endRow()
      } else {
        field.append(c)
      }
      i += 1
    }
    endRow()
    return rows
  }
}
