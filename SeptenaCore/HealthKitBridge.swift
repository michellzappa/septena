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

    // Caffeine
    if let t = HKQuantityType.quantityType(forIdentifier: .dietaryCaffeine) { s.insert(t) }

    // Nutrition (food correlation + individual macros/micros)
    if let t = HKCorrelationType.correlationType(forIdentifier: .food) { s.insert(t) }
    let nutritionIDs: [HKQuantityTypeIdentifier] = [
      .dietaryEnergyConsumed, .dietaryProtein, .dietaryFatTotal,
      .dietaryCarbohydrates, .dietaryFiber, .dietarySugar,
      .dietarySodium, .dietaryCholesterol, .dietaryWater,
    ]
    for id in nutritionIDs {
      if let t = HKQuantityType.quantityType(forIdentifier: id) { s.insert(t) }
    }

    // Training
    s.insert(HKWorkoutType.workoutType())

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

  // MARK: - Caffeine

  /// Write a caffeine intake event. Converts grams of coffee/matcha →
  /// milligrams of caffeine using per-method ratios from published data:
  ///   v60 / pour-over: ~12 mg/g dry grounds
  ///   espresso:        ~10 mg/g (less extraction than filter)
  ///   matcha:          ~17.5 mg/g powder (35 mg per standard 2 g serving)
  ///   other:           ~12 mg/g (conservative filter estimate)
  func writeCaffeine(grams: Double, method: String, date: Date) async {
    #if canImport(HealthKit)
    guard isAvailable, syncSettings.caffeine else { return }
    guard let type = HKQuantityType.quantityType(forIdentifier: .dietaryCaffeine) else { return }
    let mgPerGram: Double = {
      switch method.lowercased() {
      case "matcha":          return 17.5
      case "espresso":        return 10.0
      default:                return 12.0   // v60, filter, other
      }
    }()
    let mg = grams * mgPerGram
    guard mg > 0 else { return }
    let qty    = HKQuantity(unit: .gramUnit(with: .milli), doubleValue: mg)
    let sample = HKQuantitySample(type: type, quantity: qty, start: date, end: date)
    do {
      try await store.save(sample)
    } catch {
      SeptenaLog.error("HK caffeine write", error)
    }
    #endif
  }

  // MARK: - Nutrition

  /// Write a meal as an HKCorrelation(.food) containing individual nutrient
  /// samples. Only non-nil, non-zero values are included so the Health app
  /// displays clean data rather than a row of zeros.
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
    guard let foodType = HKCorrelationType.correlationType(forIdentifier: .food) else { return }

    var samples: Set<HKSample> = []

    func addQty(_ id: HKQuantityTypeIdentifier, value: Double?, unit: HKUnit) {
      guard let v = value, v > 0,
            let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
      samples.insert(HKQuantitySample(type: type,
                                      quantity: HKQuantity(unit: unit, doubleValue: v),
                                      start: date, end: date))
    }

    addQty(.dietaryEnergyConsumed,  value: kcal,          unit: .kilocalorie())
    addQty(.dietaryProtein,         value: proteinG,       unit: .gram())
    addQty(.dietaryFatTotal,        value: fatG,           unit: .gram())
    addQty(.dietaryCarbohydrates,   value: carbsG,         unit: .gram())
    addQty(.dietaryFiber,           value: fiberG,         unit: .gram())
    addQty(.dietarySugar,           value: sugarG,         unit: .gram())
    addQty(.dietarySodium,          value: sodiumMg,       unit: .gramUnit(with: .milli))
    addQty(.dietaryCholesterol,     value: cholesterolMg,  unit: .gramUnit(with: .milli))
    addQty(.dietaryWater,           value: waterMl.map { $0 / 1000.0 }, // ml → L
                                    unit: .liter())

    guard !samples.isEmpty else { return }

    let correlation = HKCorrelation(type: foodType,
                                    start: date, end: date,
                                    objects: samples)
    do {
      try await store.save(correlation)
    } catch {
      SeptenaLog.error("HK nutrition write", error)
    }
    #endif
  }

  // MARK: - Training

  /// Write a completed workout session. sessionType drives the HK activity
  /// type; durationMin is used for the start→end window. Active calories are
  /// best-effort: if nil, HK leaves them blank (still valid).
  func writeWorkout(sessionType: String,
                    durationMin: Double,
                    activeKcal: Double? = nil,
                    date: Date) async {
    #if canImport(HealthKit)
    guard isAvailable, syncSettings.training else { return }
    let activityType = Self.hkActivityType(for: sessionType)
    let duration     = max(durationMin, 1) * 60          // clamp to ≥1 min, in seconds
    let start        = date.addingTimeInterval(-duration)
    let end          = date
    var samples: [HKSample] = []
    if let kcal = activeKcal, kcal > 0,
       let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
      let qty = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
      samples.append(HKQuantitySample(type: energyType, quantity: qty, start: start, end: end))
    }
    let builder = HKWorkoutBuilder(healthStore: store,
                                   configuration: HKWorkoutConfiguration(),
                                   device: .local())
    builder.workoutConfiguration.activityType = activityType
    do {
      try await builder.beginCollection(at: start)
      if !samples.isEmpty { try await builder.addSamples(samples) }
      try await builder.endCollection(at: end)
      try await builder.finishWorkout()
    } catch {
      SeptenaLog.error("HK workout write", error)
    }
    #endif
  }

  #if canImport(HealthKit)
  private static func hkActivityType(for sessionType: String) -> HKWorkoutActivityType {
    let s = sessionType.lowercased()
    if s.contains("run")                            { return .running }
    if s.contains("cycl") || s.contains("bike")     { return .cycling }
    if s.contains("swim")                           { return .swimming }
    if s.contains("row")                            { return .rowing }
    if s.contains("cardio")                         { return .other }
    if s.contains("hiit") || s.contains("circuit")  { return .highIntensityIntervalTraining }
    if s.contains("mobil") || s.contains("stretch")
       || s.contains("flex") || s.contains("yoga")  { return .flexibility }
    // upper, lower, push, pull, legs, full, strength, etc.
    return .traditionalStrengthTraining
  }
  #endif

  // MARK: - Mood (HKStateOfMind, iOS 18+)

  /// Mirror a Septena mood check-in to HealthKit as a momentary HKStateOfMind
  /// sample. Returns the saved sample's UUID string so the caller can persist
  /// it for later delete/replace. No-ops silently on iOS < 18 or when
  /// HealthKit is unavailable, returning nil.
  @discardableResult
  func writeMood(quadrant: String, valence: Int,
                 emotion: String, date: Date) async -> String? {
    #if canImport(HealthKit)
    guard isAvailable else { return nil }
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
