import Foundation

// ConsumableContainer — the generalized "a container holds N uses; continue the
// current one or start fresh" math behind the intake quick-add. Three-choice
// output (Continue (use N) / New container / non-container methods), parameterized
// by a kind's config instead of hardcoding any one substance's vape/edible/capsule.
//
// A vape capsule, a cigarette pack, and a pill blister are the same shape — a
// container with a `containerCap` and a per-method "consumes the container"
// flag. The substance-specific vocabulary (the count noun "Hit", the container
// noun "capsule", each method's label/symbol) is data the caller supplies, so
// the migrator reconstructs a container tracker by feeding the matching config.
// `ConsumableContainerTests` pins the exact rows.
//
// Dependency-free on purpose (Foundation + `SuggestionBlocks.Choice` only) so it
// compiles into the watch target exactly like `SuggestionBlocks` / `DayBucket`.
public enum ConsumableContainer {
  /// One method as the container model needs to see it. `usesContainer` is the
  /// generalization of "vape vs. edible": a container method routes through the
  /// Continue/New rows; a non-container method (edible) is a plain choice.
  public struct Method: Sendable, Hashable {
    public let token: String     // persisted value (e.g. "vape", "edible")
    public let label: String     // display (e.g. "Edible")
    public let emoji: String?    // optional Tier-3 user glyph for non-container choices
    public let usesContainer: Bool
    public init(token: String, label: String, emoji: String? = nil, usesContainer: Bool) {
      self.token = token; self.label = label; self.emoji = emoji
      self.usesContainer = usesContainer
    }
  }

  /// True when the current container has room — there's a last count and the
  /// next use still fits under the cap. False with no use yet, or once the last
  /// use filled it (then we only offer a new container).
  public static func hasActiveContainer(lastCount: Int?, containerCap: Int) -> Bool {
    guard let n = lastCount else { return false }
    return n >= 1 && n < containerCap
  }

  /// The next use within the current container (only meaningful when active).
  public static func continueCount(lastCount: Int?) -> Int { (lastCount ?? 0) + 1 }

  /// The quick-add choices in priority order for one kind, given its container
  /// state. With `containerCap == nil` (no container model — e.g. caffeine) this
  /// is just the methods as plain choices, which is what the static
  /// `SuggestionBlocks` row does today. With a cap, the first container method
  /// drives the Continue/New rows and non-container methods follow.
  ///
  /// The `value` encodes the write — container rows as "<token>:N", plain
  /// methods as the bare token — and `parse(value:)` is its inverse.
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
    // methods list flat — the caffeine shape.) Methods are emoji-first, but we
    // also carry a guessed SF Symbol so emoji-less methods get a meaningful icon
    // (the quick-add surfaces show emoji when present, else this symbol) instead
    // of every row collapsing to the same generic fallback.
    for m in methods where !(m.usesContainer && containerCap != nil) {
      let symbol = (m.emoji?.isEmpty ?? true) ? defaultSymbol(for: m) : nil
      out.append(.init(value: m.token, label: m.label, symbol: symbol, emoji: m.emoji))
    }
    return out
  }

  /// A best-effort SF Symbol for an emoji-less method, keyed off keywords in its
  /// token/label. Methods carry no symbol field (they're emoji-first by design),
  /// so this keeps the quick-add menus visually consistent with every other
  /// section's menu without reintroducing a per-method symbol the user must set.
  public static func defaultSymbol(for method: Method) -> String {
    let s = (method.token + " " + method.label).lowercased()
    func has(_ keys: String...) -> Bool { keys.contains { s.contains($0) } }
    switch true {
    case has("vape", "vaporiz", "pen", "inhale", "dab"):            return "smoke"
    case has("smoke", "joint", "cigarett", "cig", "spliff", "bong"): return "smoke.fill"
    case has("edible", "gummy", "cookie", "brownie", "chocolate"):  return "fork.knife"
    case has("capsule", "pill", "tablet", "softgel"):               return "pills"
    case has("tincture", "drop", "oil", "sublingual", "subling"):   return "drop"
    case has("inject", "shot", "syringe", "jab"):                   return "syringe"
    case has("patch"):                                              return "bandage"
    case has("spray", "mist", "nasal"):                             return "wind"
    case has("espresso", "coffee", "v60", "brew", "pour", "americano", "drip"): return "cup.and.saucer"
    case has("tea", "matcha", "latte", "chai"):                     return "cup.and.saucer.fill"
    case has("drink", "beverage", "can", "bottle", "soda", "energy", "shake"):  return "waterbottle"
    case has("powder", "scoop"):                                    return "scalemass"
    case has("chew", "lozenge", "gum", "mint"):                     return "mouth"
    default:                                                        return "plus.circle"
    }
  }

  /// Decode a `choices` value back into `(token, count)`. Tolerant of a bare
  /// token (no count) so the static `SuggestionBlocks` fallback and older
  /// payloads still write something sensible.
  public static func parse(value: String) -> (method: String, count: Int?) {
    let parts = value.split(separator: ":", maxSplits: 1)
    let method = String(parts.first ?? "")
    let count = parts.count > 1 ? Int(parts[1]) : nil
    return (method, count)
  }
}
