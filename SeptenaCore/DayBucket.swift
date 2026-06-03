import SwiftUI

// DayBucket — canonical time-of-day partition shared by Habits, Mood,
// Supplements, and anywhere else the day is sliced into morning /
// afternoon / evening. Single source of truth for the cutoff hours and
// the SF Symbol used as the bucket's visual identity.
//
// Cutoffs (local time):
//   morning   : hour <  12
//   afternoon : hour <  17
//   evening   : otherwise
//
// `rawValue` is the persisted string ("morning", "afternoon", "evening")
// — every place that stores a bucket on an entity uses this lowercase
// form, so a future schema change happens here and not at the call sites.

public enum DayBucket: String, CaseIterable, Identifiable, Hashable, Sendable {
  case morning, afternoon, evening

  public var id: String { rawValue }

  /// Capitalized noun for headers and labels ("Morning").
  public var title: String { rawValue.capitalized }

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
    let h = calendar.component(.hour, from: date)
    if h < 12 { return .morning }
    if h < 17 { return .afternoon }
    return .evening
  }

  /// Parse an `"HH:MM"` or `"HH:MM:SS"` string into a bucket. Falls back
  /// to morning on a malformed input — defensive, since logged times
  /// should always be well-formed.
  public static func from(time hms: String) -> DayBucket {
    let h = Int(hms.prefix(2)) ?? 0
    if h < 12 { return .morning }
    if h < 17 { return .afternoon }
    return .evening
  }

  /// The bucket the user is currently in, by wall-clock.
  public static var current: DayBucket { from(date: .now) }

  /// Exclusive end-of-window hour (local) for this bucket — the same
  /// cutoffs `from(date:)` uses, exposed so countdown UIs derive the
  /// window boundary here instead of re-hardcoding 12 / 17. Evening runs
  /// to the day boundary (24 → next 00:00).
  public var endHour: Int {
    switch self {
    case .morning:   return 12
    case .afternoon: return 17
    case .evening:   return 24
    }
  }
}
