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
  #endif

  func requestAccess() async -> Bool {
    #if canImport(HealthKit)
    guard isAvailable else { return false }
    do {
      try await store.requestAuthorization(toShare: [], read: readTypes)
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
}
