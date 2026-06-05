import SwiftUI

// DayBucket — canonical time-of-day partition shared by Habits, Mood,
// Supplements, and anywhere else the day is sliced into morning /
// afternoon / evening. Single source of truth for the cutoff hours and
// the SF Symbol used as the bucket's visual identity.
//
// Cutoffs (local time) are USER-CONFIGURABLE via Settings ▸ Time of Day.
// They live in the shared App Group suite so the main app, widget, and
// watch all read the same boundaries; the authoritative copy is synced
// across devices in `AppSettings` and mirrored into the suite at launch.
// Defaults match the historical hardcoded values:
//   morning   : hour <  morningEnd   (default 12)
//   afternoon : hour <  afternoonEnd (default 17)
//   evening   : otherwise (runs to the day boundary, 24)
//
// `rawValue` is the persisted string ("morning", "afternoon", "evening")
// — every place that stores a bucket on an entity uses this lowercase
// form, so a future schema change happens here and not at the call sites.

/// User-configurable boundary hours between the three day buckets.
/// `morningEnd` is the first hour that counts as afternoon; `afternoonEnd`
/// the first hour that counts as evening. The init clamps to a valid,
/// strictly-increasing pair so callers never see a degenerate window.
public struct DayBucketCutoffs: Equatable, Sendable {
  public let morningEnd: Int
  public let afternoonEnd: Int

  public static let `default` = DayBucketCutoffs(morningEnd: 12, afternoonEnd: 17)

  public init(morningEnd: Int, afternoonEnd: Int) {
    // morningEnd ∈ 1…22, afternoonEnd strictly greater and ≤ 23, so every
    // bucket keeps at least one hour and evening never starts at midnight.
    let m = min(max(morningEnd, 1), 22)
    let a = min(max(afternoonEnd, m + 1), 23)
    self.morningEnd = m
    self.afternoonEnd = a
  }
}

public enum DayBucket: String, CaseIterable, Identifiable, Hashable, Sendable {
  case morning, afternoon, evening

  public var id: String { rawValue }

  /// Localized noun for headers and labels ("Morning" / "Manhã").
  public var title: String {
    switch self {
    case .morning:   return String(localized: "Morning")
    case .afternoon: return String(localized: "Afternoon")
    case .evening:   return String(localized: "Evening")
    }
  }

  /// SF Symbol used as the bucket's visual identity. Picked once here
  /// so Mood slot cards, Habits section headers, and any future bucket
  /// UI render with the same glyph.
  public var icon: String {
    switch self {
    case .morning:   return "sunrise"
    case .afternoon: return "sun.max"
    case .evening:   return "moon.stars"
    }
  }

  /// Which bucket the given local time falls into. Used at write time
  /// to stamp `bucket` on a freshly-logged entry without asking the
  /// user to confirm.
  public static func from(date: Date,
                          calendar: Calendar = .current) -> DayBucket {
    bucket(forHour: calendar.component(.hour, from: date))
  }

  /// Parse an `"HH:MM"` or `"HH:MM:SS"` string into a bucket. Falls back
  /// to morning on a malformed input — defensive, since logged times
  /// should always be well-formed.
  public static func from(time hms: String) -> DayBucket {
    bucket(forHour: Int(hms.prefix(2)) ?? 0)
  }

  /// Shared hour → bucket mapping, reading the user's configured cutoffs.
  private static func bucket(forHour h: Int) -> DayBucket {
    let c = cutoffs
    if h < c.morningEnd { return .morning }
    if h < c.afternoonEnd { return .afternoon }
    return .evening
  }

  /// The bucket the user is currently in, by wall-clock.
  public static var current: DayBucket { from(date: .now) }

  /// Position in the day (morning = 0 … evening = 2). Lets callers ask
  /// "have we reached this bucket yet?" — `b.order <= DayBucket.current.order`
  /// — without re-hardcoding the morning/afternoon/evening sequence.
  public var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

  /// UI/grouping key for "no specific time of day". Not a `DayBucket` case —
  /// it's stored as `nil` on the entity; this string is only used as a
  /// section/picker key for sections (e.g. Supplements) where bucketing is
  /// *optional* and an unbucketed item should surface all day.
  public static let anytimeKey = "anytime"

  /// Exclusive end-of-window hour (local) for this bucket — the same
  /// cutoffs `from(date:)` uses, exposed so countdown UIs derive the
  /// window boundary here instead of re-hardcoding 12 / 17. Evening runs
  /// to the day boundary (24 → next 00:00).
  public var endHour: Int {
    let c = Self.cutoffs
    switch self {
    case .morning:   return c.morningEnd
    case .afternoon: return c.afternoonEnd
    case .evening:   return 24
    }
  }
}

// MARK: - Configurable cutoffs (App Group–backed)

public extension DayBucket {
  /// App Group suite shared by the app, widget, and watch — same string
  /// used elsewhere for cross-target shared state.
  static let appGroupSuite = "group.com.septena.cloud"

  private enum CutoffKey {
    static let morningEnd   = "septena.timeofday.morningEnd"
    static let afternoonEnd = "septena.timeofday.afternoonEnd"
  }

  private static var sharedDefaults: UserDefaults {
    UserDefaults(suiteName: appGroupSuite) ?? .standard
  }

  /// The user's configured cutoffs, or `.default` when none have been set.
  /// Read on every `from(date:)` / `current` lookup — cheap (a UserDefaults
  /// hit), and always reflects the latest value the app mirrored in.
  static var cutoffs: DayBucketCutoffs {
    let d = sharedDefaults
    guard let m = d.object(forKey: CutoffKey.morningEnd) as? Int,
          let a = d.object(forKey: CutoffKey.afternoonEnd) as? Int else {
      return .default
    }
    return DayBucketCutoffs(morningEnd: m, afternoonEnd: a)
  }

  /// Persist cutoffs into the shared suite so the app, widget, and watch
  /// pick them up immediately. The authoritative cross-device copy lives in
  /// `AppSettings`; this is the fast local mirror.
  static func saveCutoffs(_ c: DayBucketCutoffs) {
    let d = sharedDefaults
    d.set(c.morningEnd, forKey: CutoffKey.morningEnd)
    d.set(c.afternoonEnd, forKey: CutoffKey.afternoonEnd)
  }
}
