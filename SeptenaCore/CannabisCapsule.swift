import Foundation

// CannabisCapsule — the single source of truth for the "capsule / hit" math
// behind the cannabis quick-add, shared by the phone menu (`CannabisQuickAddMenu`)
// and the watch quick-log so the two can't disagree about what the next step is.
//
// A vape capsule holds `usesPerCapsule` hits. The quick-add answers "what's the
// next step right now?" rather than enumerating options:
//   • Continue (Hit N) — only while the current capsule has room (hit < cap).
//   • New capsule       — always; starts a fresh capsule at hit 1.
//   • Edible            — always; capsule-free.
//
// Dependency-free on purpose (Foundation + `SuggestionBlocks.Choice` only) so it
// compiles into the watch target exactly like `SuggestionBlocks` / `DayBucket`.
public enum CannabisCapsule {
  /// True when the current capsule has room — there's a last vape hit and the
  /// next hit still fits under the cap. False with no vape yet, or once the last
  /// hit filled the capsule (then we only offer New capsule).
  public static func hasActiveCapsule(lastHit: Int?, usesPerCapsule: Int) -> Bool {
    guard let h = lastHit else { return false }
    return h >= 1 && h < usesPerCapsule
  }

  /// The next hit within the current capsule (only meaningful when active).
  public static func continueHit(lastHit: Int?) -> Int { (lastHit ?? 0) + 1 }

  /// The quick-add choices in priority order, given the current capsule state.
  /// Labels + symbols mirror `CannabisQuickAddMenu` so the wrist list is 1=1 with
  /// the phone. The `value` encodes the write — `parse(value:)` is its inverse:
  ///   • "vape:N" → a vape at hit N   • "edible" → an edible (no hit).
  public static func choices(lastHit: Int?, usesPerCapsule: Int) -> [SuggestionBlocks.Choice] {
    var out: [SuggestionBlocks.Choice] = []
    if hasActiveCapsule(lastHit: lastHit, usesPerCapsule: usesPerCapsule) {
      let h = continueHit(lastHit: lastHit)
      out.append(.init(value: "vape:\(h)", label: "Continue (Hit \(h))", symbol: "arrow.clockwise"))
    }
    out.append(.init(value: "vape:1", label: "New capsule", symbol: "plus.circle"))
    out.append(.init(value: "edible", label: "Edible", symbol: "circle.fill"))
    return out
  }

  /// Decode a `choices` value back into the write: `(method, hit)`. Tolerant of a
  /// bare "vape" / "edible" (no hit) so the static `SuggestionBlocks` fallback and
  /// older payloads still write something sensible.
  public static func parse(value: String) -> (method: String, hit: Int?) {
    let parts = value.split(separator: ":", maxSplits: 1)
    let method = String(parts.first ?? "")
    let hit = parts.count > 1 ? Int(parts[1]) : nil
    return (method, hit)
  }
}
