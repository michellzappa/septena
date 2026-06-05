import SwiftUI

// DayBucketHeader — shared Section-header look for any section grouped
// by morning / afternoon / evening. Used by Habits (today's grouped
// list) and Mood (today's check-in slots), and meant for any future
// section that wants the same time-of-day rhythm.
//
// Renders: icon · "Morning" · trailing count · "Now" pill on the
// current bucket. The "Now" pill is the cheap unification cue the user
// asked for after first shipping Mood. With `showTimeLeft` / `disclosed`
// it also drives the accordion drawer headers (see `BucketDisclosure`).

struct DayBucketHeader: View {
  /// Bucket as the canonical lowercase string ("morning" / "afternoon" /
  /// "evening"). Unknown strings render with a fallback dot icon so a
  /// stray entity name doesn't crash the header.
  let bucket: String
  /// Trailing string — Habits uses `"2/5"`, Mood uses entry counts.
  /// Pass `nil` to suppress.
  var trailing: String? = nil
  /// Show the "time left in this window" countdown (just before the count)
  /// when this is the current, time-bound bucket. Off by default — only the
  /// accordion drawers turn it on.
  var showTimeLeft: Bool = false
  /// When non-nil, render a trailing disclosure chevron: `true` points down
  /// (expanded), `false` points right (collapsed). `nil` = no chevron, the
  /// plain header look used by Mood and the past-day lists.
  var disclosed: Bool? = nil

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
    HStack(spacing: 10) {
      Image(systemName: iconName)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 26, alignment: .center)
      Text(parsed?.title ?? bucket.capitalized)
        .font(.septenaSectionTitle)
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
      // The countdown sits before the count on the current, time-bound bucket
      // — the cue that this window is closing. "anytime" has no cutoff, so it
      // never shows one even if it were somehow flagged current.
      if showTimeLeft, isCurrent, bucket != DayBucket.anytimeKey {
        BucketTimeLeft(bucket: bucket, font: .subheadline.weight(.semibold))
      }
      if let trailing {
        Text(trailing)
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      if let disclosed {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(disclosed ? 90 : 0))
      }
    }
  }
}

// MARK: - Time left

/// "Xh / Xm left" chip that ticks once a minute, coloring from secondary →
/// orange → red as the bucket's cutoff approaches. Shared by the Next-tab
/// habit strip (large, section-title font) and the accordion drawer headers
/// (`.subheadline`).
struct BucketTimeLeft: View {
  let bucket: String
  var font: Font = .septenaSectionTitle

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { ctx in
      let parts = formatted(remaining: cutoff().timeIntervalSince(ctx.date))
      Text(parts.text)
        .font(font)
        .foregroundStyle(parts.color)
        .monospacedDigit()
    }
  }

  /// End of the current habit window. Bucket boundaries come from DayBucket
  /// so they can't drift from the morning/afternoon/evening cutoffs the rest
  /// of the app uses (noon, 5pm, midnight by default).
  private func cutoff() -> Date {
    let cal = Calendar.current
    let now = Date()
    let hour = (DayBucket(rawValue: bucket) ?? .evening).endHour
    if hour >= 24 {
      return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
    }
    return cal.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
  }

  private func formatted(remaining seconds: TimeInterval) -> (text: String, color: Color) {
    let s = max(0, Int(seconds))
    let totalMin = s / 60
    let h = totalMin / 60
    let m = totalMin % 60

    let text: String
    if totalMin >= 120 {
      // Plenty of runway — coarse hours only.
      text = "\(h)h"
    } else if totalMin >= 60 {
      // Last hour-and-a-bit — show "1h 25m", rounded to 5m.
      let rounded = (m / 5) * 5
      text = rounded == 0 ? "\(h)h" : "\(h)h \(rounded)m"
    } else {
      // Under an hour — minutes, exact (this is the "more detail" zone).
      text = "\(totalMin)m"
    }

    let color: Color
    if totalMin < 15      { color = Theme.overdueRed }
    else if totalMin < 60 { color = .orange }
    else                  { color = Theme.inkSecondary }

    return (text, color)
  }
}

// MARK: - Accordion wrapper

/// Accordion wrapper for one time-of-day bucket in the Habits / Supplements
/// destination drawers. The `DayBucketHeader` is the whole tap target; the
/// `content` (a `DrawerSection` of rows) folds away when collapsed. The
/// current, time-bound bucket also surfaces a "time left" countdown.
///
/// Expansion is owned by the caller so it can run the policy the user asked
/// for: the current bucket open with its countdown, the others tucked behind
/// their headers, the open one advancing with the clock until the first tap.
/// Used on *today* only — past days render every bucket open.
struct BucketDisclosure<Content: View>: View {
  let bucket: String
  var trailing: String? = nil
  let isExpanded: Bool
  let onToggle: () -> Void
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: onToggle) {
        DayBucketHeader(bucket: bucket,
                        trailing: trailing,
                        showTimeLeft: true,
                        disclosed: isExpanded)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 16)
      // Collapsed buckets show only their header, so they need a touch of their
      // own vertical room to sit evenly; the expanded one already gets breathing
      // space from the VStack gap above its content.
      .padding(.vertical, isExpanded ? 0 : 4)
      .accessibilityHint(isExpanded ? "Collapse" : "Expand")

      if isExpanded {
        content()
          .transition(.opacity)
      }
    }
  }
}
