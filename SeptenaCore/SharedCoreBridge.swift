import Foundation

// Value conversion for calls into the shared Rust core (ADR 0025,
// `docs/SHARED_CORE_SPEC.md`). The core takes instants as ISO-8601 strings
// and days as `YYYY-MM-DD`; this file is the one place that formats them.
// The core itself comes from the pinned release in `core/release/swift`
// (module `SeptenaSharedCore`). Import that module only in the files that
// call it: its type names (`TaskSnapshot`, `PushOutcome`, …) are generic.

enum SharedCoreValues {
  /// `2026-11-21T12:00:00.000Z`. Hand-formatted from the epoch: no formatter
  /// instance, so it is cheap per row and safe on any thread.
  static func instant(_ date: Date) -> String {
    let ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    let days = ms >= 0 ? ms / 86_400_000 : (ms - 86_399_999) / 86_400_000
    let msOfDay = ms - days * 86_400_000
    let (y, m, d) = civil(fromDays: days)
    let h = msOfDay / 3_600_000
    let mi = msOfDay / 60_000 % 60
    let s = msOfDay / 1000 % 60
    let f = msOfDay % 1000
    return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(h, 2)):\(pad(mi, 2)):\(pad(s, 2)).\(pad(f, 3))Z"
  }

  /// The host's UTC offset at `date`, for a date-only value the core must
  /// place on the local clock.
  static func utcOffsetSeconds(at date: Date) -> Int32 {
    Int32(TimeZone.current.secondsFromGMT(for: date))
  }

  // Howard Hinnant's civil-from-days, the same algorithm as the core.
  private static func civil(fromDays days: Int64) -> (Int64, Int64, Int64) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
  }

  private static func pad(_ value: Int64, _ width: Int) -> String {
    let s = String(value)
    return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
  }
}
