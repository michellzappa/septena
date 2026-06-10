import Foundation

// ConsumableContainer — the generalized "a container holds N uses; continue the
// current one or start fresh" math behind the intake quick-add. It is the
// substance-free successor to `CannabisCapsule`: the same three-choice output
// (Continue (use N) / New container / non-container methods), but parameterized
// by a kind's config instead of hardcoding vape/edible/capsule.
//
// A vape capsule, a cigarette pack, and a pill blister are the same shape — a
// container with a `containerCap` and a per-method "consumes the container"
// flag. The substance-specific vocabulary (the count noun "Hit", the container
// noun "capsule", each method's label/symbol) is data the caller supplies, so
// the migrator can reconstruct cannabis by feeding the matching config and get
// output that is byte-identical to today's `CannabisCapsule` (proven by
// `ConsumableContainerTests`).
//
// Dependency-free on purpose (Foundation + `SuggestionBlocks.Choice` only) so it
// compiles into the watch target exactly like `CannabisCapsule` / `DayBucket`.
public enum ConsumableContainer {
  /// One method as the container model needs to see it. `usesContainer` is the
  /// generalization of "vape vs. edible": a container method routes through the
  /// Continue/New rows; a non-container method (edible) is a plain choice.
  public struct Method: Sendable, Hashable {
    public let token: String     // persisted value (e.g. "vape", "edible")
    public let label: String     // display (e.g. "Edible")
    public let symbol: String?   // optional SF Symbol for non-container choices
    public let usesContainer: Bool
    public init(token: String, label: String, symbol: String? = nil, usesContainer: Bool) {
      self.token = token; self.label = label; self.symbol = symbol
      self.usesContainer = usesContainer
    }
  }

  /// True when the current container has room — there's a last count and the
  /// next use still fits under the cap. False with no use yet, or once the last
  /// use filled it (then we only offer a new container). Mirrors
  /// `CannabisCapsule.hasActiveCapsule`.
  public static func hasActiveContainer(lastCount: Int?, containerCap: Int) -> Bool {
    guard let n = lastCount else { return false }
    return n >= 1 && n < containerCap
  }

  /// The next use within the current container (only meaningful when active).
  /// Mirrors `CannabisCapsule.continueHit`.
  public static func continueCount(lastCount: Int?) -> Int { (lastCount ?? 0) + 1 }

  /// The quick-add choices in priority order for one kind, given its container
  /// state. With `containerCap == nil` (no container model — e.g. caffeine) this
  /// is just the methods as plain choices, which is what the static
  /// `SuggestionBlocks` row does today. With a cap, the first container method
  /// drives the Continue/New rows and non-container methods follow.
  ///
  /// The `value` encodes the write — container rows as "<token>:N", plain
  /// methods as the bare token — and `parse(value:)` is its inverse, so this is
  /// 1=1 with `CannabisCapsule.choices` for the cannabis config.
  public static func choices(
    lastCount: Int?,
    containerCap: Int?,
    containerNoun: String,
    countNoun: String,
    methods: [Method]
  ) -> [SuggestionBlocks.Choice] {
    var out: [SuggestionBlocks.Choice] = []
    if let cap = containerCap, let container = methods.first(where: { $0.usesContainer }) {
      if hasActiveContainer(lastCount: lastCount, containerCap: cap) {
        let n = continueCount(lastCount: lastCount)
        out.append(.init(value: "\(container.token):\(n)",
                         label: "Continue (\(countNoun) \(n))",
                         symbol: "arrow.clockwise"))
      }
      out.append(.init(value: "\(container.token):1",
                       label: "New \(containerNoun)",
                       symbol: "plus.circle"))
    }
    // Container methods are represented by the rows above; everything else is a
    // plain choice. (When there's no cap, `usesContainer` is ignored and all
    // methods list flat — the caffeine shape.)
    for m in methods where !(m.usesContainer && containerCap != nil) {
      out.append(.init(value: m.token, label: m.label, symbol: m.symbol))
    }
    return out
  }

  /// Decode a `choices` value back into `(token, count)`. Tolerant of a bare
  /// token (no count) so the static `SuggestionBlocks` fallback and older
  /// payloads still write something sensible. Identical contract to
  /// `CannabisCapsule.parse`.
  public static func parse(value: String) -> (method: String, count: Int?) {
    let parts = value.split(separator: ":", maxSplits: 1)
    let method = String(parts.first ?? "")
    let count = parts.count > 1 ? Int(parts[1]) : nil
    return (method, count)
  }
}
