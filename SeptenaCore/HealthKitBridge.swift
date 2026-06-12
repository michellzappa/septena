import Foundation
import SwiftUI
#if canImport(HealthKit)
import HealthKit
#endif

// HealthKit data lives on-device — no FastAPI round-trip required. The
// webapp has a /api/health/apple proxy that mirrors the same HKQuantity
// types from a separately-collected Apple Health export; here we read
// straight from the HKHealthStore on the user's iPhone instead.
//
// Read-only. Same access-state shape as RemindersBridge / CalendarBridge
// so the destination view can render granted / not-determined / denied
// states identically.
//
// macOS gets a no-op stub: HealthKit isn't available there, so the Mac
// build still compiles but always reports `.denied`. The Activity tile
// hides itself when bridge.isAvailable is false.

@MainActor
@Observable
final class HealthKitBridge {
  static let shared = HealthKitBridge()

  /// True on devices that actually back HealthKit (iPhone yes, Mac no).
  let isAvailable: Bool

  /// Cached snapshot of the last successful pull. Kept here so the Week
  /// tile and the Activity destination can both read without re-querying.
  var stepsToday: Int = 0
  var activeKcalToday: Double = 0
  var exerciseMinutesToday: Int = 0
  var stepsHistory: [Int] = Array(repeating: 0, count: 7)
  var vo2Max: Double? = nil
  var hrv: Double? = nil
  var restingHR: Double? = nil

  /// Flips after the first refresh so the UI can stop showing a spinner.
  var hasLoaded: Bool = false

  #if canImport(HealthKit)
  let store = HKHealthStore()
  #endif

  private init() {
    #if canImport(HealthKit)
    isAvailable = HKHealthStore.isHealthDataAvailable()
    #else
    isAvailable = false
    #endif
  }

  enum Access {
    case granted
    case denied
    case notDetermined
  }

  /// HealthKit doesn't expose per-type read status for privacy reasons —
  /// callers see `.sharingDenied` even when the user said yes — so we
  /// approximate. If we've loaded any non-zero number, treat as granted;
  /// otherwise probe the step type's authorization status.
  var access: Access {
    guard isAvailable else { return .denied }
    #if canImport(HealthKit)
    if hasLoaded && (stepsToday > 0 || stepsHistory.contains(where: { $0 > 0 })) {
      return .granted
    }
    let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    switch store.authorizationStatus(for: stepType) {
    case .notDetermined: return .notDetermined
    default:             return hasLoaded ? .granted : .notDetermined
    }
    #else
    return .denied
    #endif
  }

  // MARK: - Write authorization
  //
  // Unlike read access (obscured for privacy — see `access` above), WRITE
  // authorization IS reliably queryable per-type via `authorizationStatus`.
  // The UI uses this so a user who denied a specific category's write in the
  // permission sheet sees that toggle reflect reality instead of failing
  // silently.

  /// The sections Septena can write to HealthKit. Maps 1:1 to `HKSyncSettings`.
  enum WritableKind: String, CaseIterable, Hashable {
    case mood, nutrition
  }

  enum ShareStatus: Equatable {
    case authorized       // user allowed writes — toggle works
    case denied           // user denied in the permission sheet / Health app
    case notDetermined    // never asked — needs a connect/grant first
    case unavailable      // no HealthKit, or type needs a newer OS (mood < iOS 18)
  }

  /// Observable cache of per-section write status. Refreshed by
  /// `refreshShareStatuses()` after authorization and on settings appearance,
  /// so SwiftUI views re-render when the user changes permissions and returns.
  var shareStatuses: [WritableKind: ShareStatus] = [:]

  /// Current write status for a section. Reads the cache (observable), falling
  /// back to a live probe when the cache hasn't been populated yet.
  func shareStatus(_ kind: WritableKind) -> ShareStatus {
    shareStatuses[kind] ?? liveShareStatus(kind)
  }

  /// True once the user has made a decision (allow or deny) on at least one
  /// writable type — i.e. they've been through the permission sheet at least
  /// once. Drives the Settings headline (Connect vs. Connected).
  var hasRequestedWrite: Bool {
    WritableKind.allCases.contains {
      let s = liveShareStatus($0)
      return s == .authorized || s == .denied
    }
  }

  /// Re-probe every writable type and publish into `shareStatuses`.
  func refreshShareStatuses() {
    var m: [WritableKind: ShareStatus] = [:]
    for k in WritableKind.allCases { m[k] = liveShareStatus(k) }
    shareStatuses = m
  }

  private func liveShareStatus(_ kind: WritableKind) -> ShareStatus {
    #if canImport(HealthKit)
    guard isAvailable, let type = Self.sampleType(for: kind) else { return .unavailable }
    switch store.authorizationStatus(for: type) {
    case .sharingAuthorized: return .authorized
    case .sharingDenied:     return .denied
    case .notDetermined:     return .notDetermined
    @unknown default:        return .notDetermined
    }
    #else
    return .unavailable
    #endif
  }

  #if canImport(HealthKit)
  /// Representative HK type per section — the one we probe for write status.
  /// Nutrition uses dietary energy as a stand-in for the whole correlation set
  /// (they're requested together, so status is uniform).
  private static func sampleType(for kind: WritableKind) -> HKSampleType? {
    switch kind {
    case .mood:
      if #available(iOS 18, *) { return HKObjectType.stateOfMindType() }
      return nil
    case .nutrition: return HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed)
    }
  }
  #endif

  #if canImport(HealthKit)
  // Types we read. Add to this list when a new module needs more.
  private var readTypes: Set<HKObjectType> {
    var s: Set<HKObjectType> = []
    let ids: [HKQuantityTypeIdentifier] = [
      .stepCount, .activeEnergyBurned, .appleExerciseTime,
      .vo2Max, .heartRateVariabilitySDNN, .restingHeartRate
    ]
    for id in ids {
      if let t = HKQuantityType.quantityType(forIdentifier: id) {
        s.insert(t)
      }
    }
    return s
  }

  // Types we write. iOS-version-gated additions go here.
  private var writeTypes: Set<HKSampleType> {
    var s: Set<HKSampleType> = []

    // Mood — iOS 18+
    if #available(iOS 18, *) {
      s.insert(HKObjectType.stateOfMindType())
    }

    // Nutrition — individual quantity types only. HKCorrelationType.food
    // is restricted to Apple and cannot be requested by third-party apps.
    let nutritionIDs: [HKQuantityTypeIdentifier] = [
      .dietaryEnergyConsumed, .dietaryProtein, .dietaryFatTotal,
      .dietaryCarbohydrates, .dietaryFiber, .dietarySugar,
      .dietarySodium, .dietaryCholesterol, .dietaryWater,
    ]
    for id in nutritionIDs {
      if let t = HKQuantityType.quantityType(forIdentifier: id) { s.insert(t) }
    }

    return s
  }

  // MARK: - Sync settings cache
  // Updated by SeptenaServices when AppSettings change. Defaults all-on so
  // writes work immediately after the user grants access, before settings load.
  var syncSettings = HKSyncSettings()

  #endif

  func requestAccess() async -> Bool {
    #if canImport(HealthKit)
    guard isAvailable else { return false }
    do {
      try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
      await refresh()
      refreshShareStatuses()
      return true
    } catch {
      return false
    }
    #else
    return false
    #endif
  }

  /// Pull every metric in one parallel pass and cache. Called after
  /// authorization and on pull-to-refresh from the Week dashboard.
  func refresh() async {
    #if DEBUG
    // Screenshot / demo builds: synthetic Activity so the tile looks lived-in
    // without HealthKit data (or a permission prompt).
    if DemoSeedMode.isOn {
      stepsToday = 9240; activeKcalToday = 540; exerciseMinutesToday = 38
      stepsHistory = [7100, 8300, 11200, 6400, 9900, 12400, 9240]
      vo2Max = 48.5; hrv = 58; restingHR = 52
      hasLoaded = true
      return
    }
    #endif
    #if canImport(HealthKit)
    guard isAvailable else { hasLoaded = true; return }
    async let st = todaySum(.stepCount)
    async let ak = todaySum(.activeEnergyBurned, unit: .kilocalorie())
    async let ex = todaySum(.appleExerciseTime, unit: .minute())
    async let sh = sevenDaySums(.stepCount)
    async let vo = latest(.vo2Max,
                          unit: HKUnit(from: "ml/kg*min"))
    async let hrvVal = latest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli))
    async let rhr = latest(.restingHeartRate,
                           unit: HKUnit.count().unitDivided(by: .minute()))

    let (stRes, akRes, exRes, shRes, voRes, hrvRes, rhrRes) =
      await (st, ak, ex, sh, vo, hrvVal, rhr)

    stepsToday = Int(stRes)
    activeKcalToday = akRes
    exerciseMinutesToday = Int(exRes)
    stepsHistory = shRes
    vo2Max = voRes
    hrv = hrvRes
    restingHR = rhrRes
    hasLoaded = true

    // Persist + sync the daily history. Kicked off un-awaited so the live
    // snapshot (above) and the UI stay as fast as before; the mutator's
    // unchanged-skip makes re-reading the trailing window each refresh cheap.
    Task { await ingestActivityHistory(daysBack: 14) }
    backfillActivityHistoryIfNeeded()
    #else
    hasLoaded = true
    #endif
  }

  // MARK: - Queries (iOS only)

  #if canImport(HealthKit)
  /// Sum of `id`'s samples for today, in the given unit. Returns 0 if the
  /// query fails or the user denied that type.
  private func todaySum(_ id: HKQuantityTypeIdentifier,
                        unit: HKUnit = .count()) async -> Double {
    guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return 0 }
    let cal = Calendar.current
    let start = cal.startOfDay(for: Date())
    let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date()
    let pred = HKQuery.predicateForSamples(withStart: start, end: end)
    return await withCheckedContinuation { cont in
      let q = HKStatisticsQuery(quantityType: type,
                                quantitySamplePredicate: pred,
                                options: .cumulativeSum) { _, stats, _ in
        let v = stats?.sumQuantity()?.doubleValue(for: unit) ?? 0
        cont.resume(returning: v)
      }
      store.execute(q)
    }
  }

  /// Seven daily sums (oldest first) for the given type. Used by the
  /// step histogram on the Week tile.
  private func sevenDaySums(_ id: HKQuantityTypeIdentifier,
                            unit: HKUnit = .count()) async -> [Int] {
    guard let type = HKQuantityType.quantityType(forIdentifier: id) else {
      return Array(repeating: 0, count: 7)
    }
    let cal = Calendar.current
    let anchor = cal.startOfDay(for: Date())
    let start = cal.date(byAdding: .day, value: -6, to: anchor) ?? anchor
    let interval = DateComponents(day: 1)
    let q = HKStatisticsCollectionQuery(quantityType: type,
                                        quantitySamplePredicate: nil,
                                        options: .cumulativeSum,
                                        anchorDate: anchor,
                                        intervalComponents: interval)
    return await withCheckedContinuation { cont in
      q.initialResultsHandler = { _, results, _ in
        var vals: [Int] = []
        results?.enumerateStatistics(from: start,
                                     to: cal.date(byAdding: .day, value: 1, to: anchor) ?? anchor) { stat, _ in
          vals.append(Int(stat.sumQuantity()?.doubleValue(for: unit) ?? 0))
        }
        while vals.count < 7 { vals.insert(0, at: 0) }
        cont.resume(returning: Array(vals.suffix(7)))
      }
      store.execute(q)
    }
  }

  /// Per-day sums keyed by "yyyy-MM-dd" over a trailing window, via one
  /// statistics-collection query. Days with no samples are omitted (their sum
  /// would be 0 and we never persist an empty row). Used by the cloud-history
  /// ingest, which needs real calendar dates rather than a fixed-length array.
  private func dailySums(_ id: HKQuantityTypeIdentifier,
                         unit: HKUnit,
                         daysBack: Int) async -> [String: Double] {
    guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [:] }
    let cal = Calendar.current
    let anchor = cal.startOfDay(for: Date())
    let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: anchor) ?? anchor
    let end = cal.date(byAdding: .day, value: 1, to: anchor) ?? anchor
    let q = HKStatisticsCollectionQuery(quantityType: type,
                                        quantitySamplePredicate: nil,
                                        options: .cumulativeSum,
                                        anchorDate: anchor,
                                        intervalComponents: DateComponents(day: 1))
    return await withCheckedContinuation { cont in
      q.initialResultsHandler = { _, results, _ in
        var out: [String: Double] = [:]
        results?.enumerateStatistics(from: start, to: end) { stat, _ in
          if let sum = stat.sumQuantity()?.doubleValue(for: unit), sum > 0,
             let key = SeptenaDate.format(stat.startDate) {
            out[key] = sum
          }
        }
        cont.resume(returning: out)
      }
      store.execute(q)
    }
  }

  /// Most recent quantity sample's value. Used for vitals (VO2, HRV, RHR)
  /// where "today's total" isn't meaningful.
  private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
    guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
    let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
    return await withCheckedContinuation { cont in
      let q = HKSampleQuery(sampleType: type,
                            predicate: nil,
                            limit: 1,
                            sortDescriptors: [sort]) { _, samples, _ in
        let v = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
        cont.resume(returning: v)
      }
      store.execute(q)
    }
  }
  #endif

  // MARK: - Cloud history ingest
  //
  // HealthKit is per-device and macOS has none, so we read each day from the
  // phone's store ONCE and persist a tiny day-keyed record that syncs through
  // CloudKit to every surface (Mac tile, history chart, correlations). Past
  // days are effectively immutable; today's row is rewritten through the day
  // and freezes at rollover.

  /// Sentinel for the one-time deep backfill. Device-local (UserDefaults) on
  /// purpose: the backfill reads THIS device's HealthKit, so "already done"
  /// is a per-device fact, not account data.
  private static let backfillKey = "activity.import.v1"

  /// Read steps / active energy / exercise minutes per day over a trailing
  /// window and upsert each through `ActivityMutator`. iOS only.
  func ingestActivityHistory(daysBack: Int) async {
    #if canImport(HealthKit)
    guard isAvailable else { return }
    async let stepsD = dailySums(.stepCount,          unit: .count(),       daysBack: daysBack)
    async let kcalD  = dailySums(.activeEnergyBurned, unit: .kilocalorie(), daysBack: daysBack)
    async let exMinD = dailySums(.appleExerciseTime,  unit: .minute(),      daysBack: daysBack)
    let (steps, kcal, exMin) = await (stepsD, kcalD, exMinD)

    let days = Set(steps.keys).union(kcal.keys).union(exMin.keys)
    guard !days.isEmpty else { return }

    let mutator = SeptenaServices.shared.activityMutator
    for day in days.sorted() {
      mutator.upsert(date: day,
                     steps: steps[day].map { Int($0.rounded()) },
                     activeKcal: kcal[day],
                     exerciseMinutes: exMin[day].map { Int($0.rounded()) })
    }
    #endif
  }

  /// One-time deep ingest of the trailing year, gated by `backfillKey` and run
  /// at background priority so it never touches the launch critical path. The
  /// flag is set only on completion, so a killed run retries next launch.
  private func backfillActivityHistoryIfNeeded() {
    #if canImport(HealthKit)
    guard isAvailable,
          !UserDefaults.standard.bool(forKey: Self.backfillKey) else { return }
    Task(priority: .background) {
      await ingestActivityHistory(daysBack: 365)
      UserDefaults.standard.set(true, forKey: Self.backfillKey)
    }
    #endif
  }

  // MARK: - Nutrition

  /// Write a meal as an HKCorrelation(.food) containing individual nutrient
  /// samples. Only non-nil, non-zero values are included so the Health app
  /// displays clean data rather than a row of zeros.
  /// Write a meal's nutrition data as individual HKQuantitySamples. Apple
  /// restricts HKCorrelationType.food to first-party apps, so we write each
  /// nutrient as a standalone sample — they appear in Health's Nutrition tab
  /// grouped by timestamp. Only non-nil, non-zero values are written.
  func writeNutritionEntry(kcal: Double?,
                           proteinG: Double?,
                           fatG: Double?,
                           carbsG: Double?,
                           fiberG: Double?,
                           sugarG: Double?,
                           sodiumMg: Double?,
                           cholesterolMg: Double?,
                           waterMl: Double?,
                           date: Date) async {
    #if canImport(HealthKit)
    guard isAvailable, syncSettings.nutrition else { return }

    var samples: [HKSample] = []

    func addQty(_ id: HKQuantityTypeIdentifier, value: Double?, unit: HKUnit) {
      guard let v = value, v > 0,
            let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
      samples.append(HKQuantitySample(type: type,
                                      quantity: HKQuantity(unit: unit, doubleValue: v),
                                      start: date, end: date))
    }

    addQty(.dietaryEnergyConsumed, value: kcal,                        unit: .kilocalorie())
    addQty(.dietaryProtein,        value: proteinG,                     unit: .gram())
    addQty(.dietaryFatTotal,       value: fatG,                         unit: .gram())
    addQty(.dietaryCarbohydrates,  value: carbsG,                       unit: .gram())
    addQty(.dietaryFiber,          value: fiberG,                       unit: .gram())
    addQty(.dietarySugar,          value: sugarG,                       unit: .gram())
    addQty(.dietarySodium,         value: sodiumMg,                     unit: .gramUnit(with: .milli))
    addQty(.dietaryCholesterol,    value: cholesterolMg,                unit: .gramUnit(with: .milli))
    addQty(.dietaryWater,          value: waterMl.map { $0 / 1000.0 }, unit: .liter())

    guard !samples.isEmpty else { return }
    do {
      try await store.save(samples)
    } catch {
      SeptenaLog.error("HK nutrition write", error)
    }
    #endif
  }

  // MARK: - Mood (HKStateOfMind, iOS 18+)

  /// Mirror a Septena mood check-in to HealthKit as a momentary HKStateOfMind
  /// sample. Returns the saved sample's UUID string so the caller can persist
  /// it for later delete/replace. No-ops silently on iOS < 18 or when
  /// HealthKit is unavailable, returning nil.
  @discardableResult
  func writeMood(quadrant: String, valence: Int,
                 emotion: String, date: Date) async -> String? {
    #if canImport(HealthKit)
    guard isAvailable, syncSettings.mood else { return nil }
    if #available(iOS 18, *) {
      let hkValence = Self.hkValence(quadrant: quadrant, valence: valence)
      let labels    = Self.hkLabels(for: emotion)
      let sample    = HKStateOfMind(date: date,
                                    kind: .momentaryEmotion,
                                    valence: hkValence,
                                    labels: labels,
                                    associations: [])
      do {
        try await store.save(sample)
        return sample.uuid.uuidString
      } catch {
        SeptenaLog.error("HKStateOfMind write", error)
        return nil
      }
    }
    return nil
    #else
    return nil
    #endif
  }

  /// Delete the HKStateOfMind sample that was written for a mood entry,
  /// looked up by the UUID string stored in MoodEventEntity.hkSampleID.
  /// No-ops silently on iOS < 18 or when HealthKit is unavailable.
  func deleteMoodSample(uuid: String) async {
    #if canImport(HealthKit)
    guard isAvailable, let hkUUID = UUID(uuidString: uuid) else { return }
    if #available(iOS 18, *) {
      let pred = HKQuery.predicateForObject(with: hkUUID)
      let type = HKObjectType.stateOfMindType()
      let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
      let found: [HKSample] = await withCheckedContinuation { cont in
        let q = HKSampleQuery(sampleType: type,
                              predicate: pred,
                              limit: 1,
                              sortDescriptors: [sort]) { _, samples, _ in
          cont.resume(returning: samples ?? [])
        }
        store.execute(q)
      }
      guard let sample = found.first else { return }
      do {
        try await store.delete(sample)
      } catch {
        SeptenaLog.error("HKStateOfMind delete", error)
      }
    }
    #endif
  }

  #if canImport(HealthKit)
  // Maps Septena's (quadrant, valence 1–3) onto HKStateOfMind's -1…1 scale.
  // Pleasant quadrants (hap/lap) → positive; unpleasant (han/lan) → negative.
  // Within each half: valence 1 is the outermost pole, 3 is closest to neutral.
  @available(iOS 18, *)
  private static func hkValence(quadrant: String, valence: Int) -> Double {
    let pleasant = quadrant == "hap" || quadrant == "lap"
    return pleasant
      ?  Double(valence) / 3.0          //  0.33 … 1.0
      : -Double(4 - valence) / 3.0      // -1.0  … -0.33
  }

  @available(iOS 18, *)
  private static func hkLabels(for emotion: String) -> [HKStateOfMind.Label] {
    let map: [String: HKStateOfMind.Label] = [
      // HAP — high arousal, pleasant
      "Excited": .excited,   "Elated":  .happy,    "Ecstatic": .joyful,
      "Eager":   .hopeful,   "Upbeat":  .happy,    "Joyful":   .joyful,
      "Focused": .satisfied, "Alive":   .happy,    "Content":  .content,
      // HAN — high arousal, unpleasant
      "Enraged":   .angry,     "Panicked": .scared,  "Stressed":  .stressed,
      "Angry":     .angry,     "Anxious":  .anxious, "Frustrated":.frustrated,
      "Irritated": .irritated, "Tense":    .stressed,"Restless":  .worried,
      // LAN — low arousal, unpleasant
      "Bored":       .indifferent, "Discouraged": .discouraged, "Disappointed": .disappointed,
      "Sad":         .sad,         "Lonely":      .lonely,      "Glum":         .sad,
      "Drained":     .drained,     "Hopeless":    .hopeless,    "Despondent":   .sad,
      // LAP — low arousal, pleasant
      "Mellow":  .peaceful, "Easygoing": .calm,     "Pleased": .content,
      "Calm":    .calm,     "Grateful":  .grateful, "Loved":   .grateful,
      "Relaxed": .peaceful, "Serene":    .peaceful, "Tranquil":.peaceful,
    ]
    return [map[emotion] ?? .indifferent]
  }
  #endif
}
