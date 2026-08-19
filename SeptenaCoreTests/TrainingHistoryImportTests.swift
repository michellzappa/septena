import Testing
import Foundation

/// The importer's job is to be boringly correct on other people's files, and
/// its failure mode is silent: a column read one position off, or a pound read
/// as a kilo, produces a plausible-looking history that is simply wrong. These
/// cover the specific ways that happens.
@Suite struct TrainingHistoryImportTests {

  /// Names the fixtures pretend the app already knows.
  private let known: Set<String> = [
    exerciseKey("Bench Press"), exerciseKey("barbell-bench-press"),
    exerciseKey("Squat"), exerciseKey("Deadlift"), exerciseKey("Run"),
  ]

  private func plan(_ csv: String, unit: WeightImportUnit = .kg) throws -> TrainingImportPlan {
    try TrainingHistoryImport.plan(csv: csv, knownExerciseKeys: known, assumedUnit: unit)
  }

  // MARK: CSV shape

  @Test func quotedFieldWithCommaDoesNotShiftColumns() throws {
    let csv = """
    Date,Exercise,Weight,Reps
    2026-01-05,"Bench Press, Close Grip",60,8
    """
    let p = try plan(csv)
    let entry = try #require(p.sessions.first?.entries.first)
    #expect(entry.exercise == "Bench Press, Close Grip")
    #expect(entry.weight == 60)
    #expect(entry.reps == "8")
  }

  @Test func doubledQuotesAndCRLFSurvive() {
    let rows = TrainingHistoryImport.parseCSV("a,\"b\"\"c\"\r\n1,2\r\n")
    #expect(rows == [["a", "b\"c"], ["1", "2"]])
  }

  @Test func aFileWithNoRowsIsEmptyNotUnrecognized() {
    #expect(throws: TrainingImportError.empty) {
      _ = try plan("Date,Exercise,Weight,Reps")
    }
  }

  @Test func aFileWithoutADateColumnIsRejected() {
    #expect(throws: TrainingImportError.unrecognized) {
      _ = try plan("Exercise,Weight,Reps\nSquat,100,5")
    }
  }

  // MARK: Collapsing sets into our shape

  @Test func identicalSetsCollapseIntoOneEntry() throws {
    let csv = """
    Date,Exercise,Weight,Reps
    2026-01-05,Bench Press,60,10
    2026-01-05,Bench Press,60,10
    2026-01-05,Bench Press,60,10
    """
    let p = try plan(csv)
    #expect(p.sessionCount == 1)
    let entry = try #require(p.sessions.first?.entries.first)
    #expect(p.entryCount == 1)
    #expect(entry.sets == "3")
    #expect(entry.reps == "10")
    #expect(entry.weight == 60)
    #expect(p.setRows == 3)
  }

  @Test func aPyramidStaysThreeEntriesOfOneSet() throws {
    let csv = """
    Date,Exercise,Weight,Reps
    2026-01-05,Squat,60,10
    2026-01-05,Squat,70,8
    2026-01-05,Squat,80,6
    """
    let p = try plan(csv)
    let entries = try #require(p.sessions.first?.entries)
    #expect(entries.count == 3)
    #expect(entries.allSatisfy { $0.sets == "1" })
    #expect(entries.map(\.weight) == [60, 70, 80])
  }

  @Test func setsDifferingOnlyByEffortDoNotMerge() throws {
    let csv = """
    Date,Exercise,Weight,Reps,RPE
    2026-01-05,Squat,100,5,7
    2026-01-05,Squat,100,5,7
    2026-01-05,Squat,100,5,10
    """
    let p = try plan(csv)
    let entries = try #require(p.sessions.first?.entries)
    #expect(entries.count == 2)
    #expect(entries.contains { $0.sets == "2" && $0.difficulty == "moderate" })
    #expect(entries.contains { $0.sets == "1" && $0.difficulty == "max" })
  }

  @Test func cardioSumsRatherThanCollapsing() throws {
    let csv = """
    Date,Exercise,Distance,Distance Unit,Seconds
    2026-01-05,Run,5,km,1500
    2026-01-05,Run,3,km,900
    """
    let p = try plan(csv)
    let entry = try #require(p.sessions.first?.entries.first)
    #expect(entry.distanceM == 8000)
    #expect(entry.durationMin == 40)
    #expect(entry.sets == nil)
    #expect(p.sessions.first?.sessionType == "cardio")
  }

  @Test func eachDateBecomesItsOwnSessionInOrder() throws {
    let csv = """
    Date,Exercise,Weight,Reps
    2026-01-07,Squat,100,5
    2026-01-05,Bench Press,60,10
    """
    let p = try plan(csv)
    #expect(p.sessions.map(\.date) == ["2026-01-05", "2026-01-07"])
    #expect(p.from == "2026-01-05")
    #expect(p.to == "2026-01-07")
  }

  // MARK: Units

  @Test func poundsBecomeKilos() throws {
    let csv = """
    Date,Exercise,Weight,Weight Unit,Reps
    2026-01-05,Bench Press,225,lbs,5
    """
    let p = try plan(csv)
    let entry = try #require(p.sessions.first?.entries.first)
    #expect(entry.weight == 102.06)
    #expect(p.declaredUnit == .lb)
  }

  @Test func aFileThatDeclaresNoUnitUsesTheCallersAssumption() throws {
    let csv = """
    Date,Exercise,Weight,Reps
    2026-01-05,Bench Press,100,5
    """
    #expect(try plan(csv, unit: .kg).sessions[0].entries[0].weight == 100)
    #expect(try plan(csv, unit: .lb).sessions[0].entries[0].weight == 45.36)
    #expect(try plan(csv).declaredUnit == nil)
  }

  @Test func aMixedUnitFileConvertsPerRow() throws {
    let csv = """
    Date,Exercise,Weight,Weight Unit,Reps
    2026-01-05,Bench Press,100,kg,5
    2026-01-06,Bench Press,100,lbs,5
    """
    let p = try plan(csv)
    #expect(p.mixedUnits)
    #expect(p.declaredUnit == nil)
    #expect(p.sessions[0].entries[0].weight == 100)
    #expect(p.sessions[1].entries[0].weight == 45.36)
  }

  // MARK: Effort

  @Test func rirZeroIsFailureButRpeZeroIsNothing() {
    #expect(TrainingHistoryImport.effortRung(rir: "0", rpe: "") == "max")
    #expect(TrainingHistoryImport.effortRung(rir: "", rpe: "0") == nil)
    #expect(TrainingHistoryImport.effortRung(rir: "", rpe: "") == nil)
  }

  @Test func rpeFoldsOntoTheSameRungsAsRir() {
    #expect(TrainingHistoryImport.effortRung(rir: "", rpe: "10") == "max")
    #expect(TrainingHistoryImport.effortRung(rir: "", rpe: "9") == "hard")
    #expect(TrainingHistoryImport.effortRung(rir: "", rpe: "8") == "moderate")
    #expect(TrainingHistoryImport.effortRung(rir: "", rpe: "6") == "easy")
    #expect(TrainingHistoryImport.effortRung(rir: "1", rpe: "") == "hard")
    #expect(TrainingHistoryImport.effortRung(rir: "4", rpe: "") == "easy")
  }

  @Test func cardioRowsDropTheirRating() throws {
    let csv = """
    Date,Exercise,Distance,Distance Unit,Seconds,RPE
    2026-01-05,Run,5,km,1500,9
    """
    let p = try plan(csv)
    #expect(p.sessions[0].entries[0].difficulty == nil)
    #expect(p.ratedSets == 0)
  }

  // MARK: Per-exporter shapes

  @Test func hevyIsRecognizedAndItsWarmupsAreDropped() throws {
    let csv = """
    title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps,distance_km,duration_seconds,rpe
    Push Day,"22 Dec 2025, 08:00","22 Dec 2025, 09:10",Bench Press (Barbell),0,warmup,40,10,,,
    Push Day,"22 Dec 2025, 08:00","22 Dec 2025, 09:10",Bench Press (Barbell),1,normal,80,5,,,9
    Push Day,"22 Dec 2025, 08:00","22 Dec 2025, 09:10",Bench Press (Barbell),2,normal,80,5,,,9
    """
    let p = try plan(csv)
    #expect(p.source == "Hevy")
    #expect(p.warmupRows == 1)
    #expect(p.setRows == 2)
    let session = try #require(p.sessions.first)
    #expect(session.date == "2025-12-22")
    #expect(session.time == "08:00")
    #expect(session.name == "Push Day")
    let entry = try #require(session.entries.first)
    // "(Barbell)" is a qualifier our catalog spells as an alias, so this has to
    // land on the known lift rather than inventing a second bench press.
    #expect(entry.isKnownExercise)
    #expect(entry.sets == "2")
    #expect(entry.difficulty == "hard")
    #expect(entry.note == "Push Day")
  }

  @Test func strongIsRecognizedAndItsWorkoutDurationIsNotASet() throws {
    // Strong repeats the whole workout's Duration on every row. Read as a
    // per-set time it turns a zero-rep row into a 158-minute cardio session.
    let csv = """
    Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,RPE
    2026-01-05 18:51:52,Leg Day,2h 38m,Squat (Barbell),1,100,5,,0,,8
    2026-01-05 18:51:52,Leg Day,2h 38m,Squat (Barbell),2,0,0,,0,,
    """
    let p = try plan(csv)
    #expect(p.source == "Strong")
    #expect(p.skippedRows == 1)          // the empty set measured nothing
    let entries = try #require(p.sessions.first?.entries)
    #expect(entries.count == 1)
    #expect(entries[0].durationMin == nil)
    #expect(entries[0].weight == 100)
    #expect(entries[0].difficulty == "moderate")
    #expect(p.sessions[0].time == "18:51")
  }

  @Test func fitNotesTimeIsPerSetBecauseThereIsNoSecondsColumn() throws {
    let csv = """
    Date,Exercise,Category,Weight,Weight Unit,Reps,Distance,Distance Unit,Time,Comment
    2026-01-05,Plank,Core,0,kg,0,,,00:01:30,
    """
    let p = try plan(csv)
    #expect(p.source == "FitNotes")
    #expect(p.sessions[0].entries[0].durationMin == 1.5)
  }

  // MARK: Name resolution

  @Test func anUnknownNameIsKeptReadableAndFlagged() throws {
    let csv = """
    Date,Exercise,Weight,Reps
    2026-01-05,Hack Squat (Machine),120,10
    """
    let p = try plan(csv)
    let entry = try #require(p.sessions.first?.entries.first)
    #expect(entry.isKnownExercise == false)
    #expect(entry.exercise == "Hack Squat Machine")
    #expect(p.unknownNames == ["Hack Squat Machine"])
    #expect(p.knownNames.isEmpty)
  }

  @Test func aQualifierMatchesEitherWayRound() {
    let against = known
    #expect(TrainingHistoryImport.resolve(name: "Bench Press (Barbell)", against: against) != nil)
    #expect(TrainingHistoryImport.resolve(name: "Barbell Bench Press", against: against) != nil)
    #expect(TrainingHistoryImport.resolve(name: "bench press", against: against) != nil)
    // Close, but a different lift — guessing here would file years under the
    // wrong exercise.
    #expect(TrainingHistoryImport.resolve(name: "Incline Bench Press", against: against) == nil)
  }

  // MARK: Dates

  @Test func theDateDialectsAllLand() {
    #expect(TrainingHistoryImport.parseWhen("2026-01-05")?.date == "2026-01-05")
    #expect(TrainingHistoryImport.parseWhen("2026-1-5")?.date == "2026-01-05")
    #expect(TrainingHistoryImport.parseWhen("2026-01-05 18:51:52")?.time == "18:51")
    #expect(TrainingHistoryImport.parseWhen("22 Dec 2025, 08:00")?.date == "2025-12-22")
    #expect(TrainingHistoryImport.parseWhen("Dec 22, 2025")?.date == "2025-12-22")
    // Day-first when ambiguous — every app that writes a bare numeric date got
    // it there through a European spreadsheet.
    #expect(TrainingHistoryImport.parseWhen("07/03/2024")?.date == "2024-03-07")
    #expect(TrainingHistoryImport.parseWhen("22/03/2024")?.date == "2024-03-22")
    #expect(TrainingHistoryImport.parseWhen("not a date") == nil)
    #expect(TrainingHistoryImport.parseWhen("") == nil)
  }

  @Test func aRowWithNoUsableDateIsCountedNotFatal() throws {
    let csv = """
    Date,Exercise,Weight,Reps
    ,Squat,100,5
    2026-01-05,Squat,100,5
    """
    let p = try plan(csv)
    #expect(p.skippedRows == 1)
    #expect(p.setRows == 1)
  }

  // MARK: Scalars

  @Test func durationsParseInEveryDialect() {
    #expect(TrainingHistoryImport.minutesFrom("00:01:30") == 1.5)
    #expect(TrainingHistoryImport.minutesFrom("01:30") == 1.5)
    #expect(TrainingHistoryImport.minutesFrom("2h 38m") == 158)
    #expect(TrainingHistoryImport.minutesFrom("90") == 90)
    #expect(TrainingHistoryImport.minutesFrom("") == 0)
  }

  @Test func distancesConvertToMeters() {
    #expect(TrainingHistoryImport.metersFrom("5", unit: "km") == 5000)
    #expect(TrainingHistoryImport.metersFrom("400", unit: "m") == 400)
    #expect(TrainingHistoryImport.metersFrom("1", unit: "mi") == 1609)
    // No unit column at all: these exports write kilometres.
    #expect(TrainingHistoryImport.metersFrom("5", unit: "") == 5000)
  }

  @Test func commaDecimalsRead() {
    #expect(TrainingHistoryImport.number("62,5") == 62.5)
    #expect(TrainingHistoryImport.number("62.5 kg") == 62.5)
    #expect(TrainingHistoryImport.number("") == 0)
  }
}
