import SwiftUI

// DayBucketHeader — shared Section-header look for any section grouped
// by morning / afternoon / evening. Used by Habits (today's grouped
// list) and Mood (today's check-in slots), and meant for any future
// section that wants the same time-of-day rhythm.
//
// Renders: icon · "Morning" · trailing count · "Now" pill on the
// current bucket. The "Now" pill is the cheap unification cue the user
// asked for after first shipping Mood.

struct DayBucketHeader: View {
  /// Bucket as the canonical lowercase string ("morning" / "afternoon" /
  /// "evening"). Unknown strings render with a fallback dot icon so a
  /// stray entity name doesn't crash the header.
  let bucket: String
  /// Trailing string — Habits uses `"2/5"`, Mood uses entry counts.
  /// Pass `nil` to suppress.
  var trailing: String? = nil

  private var parsed: DayBucket? { DayBucket(rawValue: bucket) }
  private var isCurrent: Bool {
    parsed.map { $0 == DayBucket.current } ?? false
  }
  /// "anytime" (the optional-bucket sentinel) gets a dashed-circle glyph —
  /// reads as "no particular slot" — rather than the unknown-bucket fallback.
  private var iconName: String {
    if bucket == DayBucket.anytimeKey { return "circle.dashed" }
    return parsed?.icon ?? "circle"
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: iconName)
        .font(.footnote)
        .foregroundStyle(.secondary)
      Text(parsed?.title ?? bucket.capitalized)
      if isCurrent {
        Text("Now")
          .font(.caption2.weight(.semibold))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(
            Capsule().fill(Color.accentColor.opacity(0.18))
          )
          .foregroundStyle(Color.accentColor)
      }
      Spacer()
      if let trailing {
        Text(trailing).monospacedDigit()
      }
    }
  }
}
