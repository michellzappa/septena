// Septena Plus finish (ADR 0023): the obsidian-and-foil look worn by a
// Septena Plus account (profile badge, avatar ring). Visual constants only.
// The plan itself, its name and all its copy live in `registry/plans.json`
// (`RegistryPlans`), and the server decides who has it (`PlanStatus`). The old
// tip jar ("Support Septena", tiers, reasons, perks) left the task app with
// ADR 0023 and docs/SYNC_SUBSCRIPTION_SPEC.md §8.

import SwiftUI

enum SeptenaPlus {
  // MARK: Premium finish
  //
  // A graphite surface with a single champagne-foil accent. Restraint reads as
  // premium.
  //
  // Every value here is FIXED, never run through the global dark-mode `adaptive`
  // lift (`parseHexColor`): the lift hoists anything below 50% lightness up to
  // a flat gray, which would dissolve the obsidian plate into mud, exactly the
  // bug this finish exists to avoid. The foil is the same in both appearances
  // (`AdaptiveColor.raw`); only `ink` is hand-tuned per mode.

  /// Authored-as-stored color, no dark-mode lift — the whole finish is fixed.
  private static func fixed(_ hex: String) -> Color { AdaptiveColor.raw(hex) ?? .gray }

  /// Graphite "ink" surface — the metal membership card. Deep graphite in
  /// light mode (pops against the white page); a *raised* graphite in dark
  /// mode that sits a touch lighter than the near-black sheet (~#1C1C1E) so the
  /// card reads as a jewel raised off the canvas, not a hole punched into it.
  static let ink = LinearGradient(
    colors: [AdaptiveColor.dual(light: "#33353B", dark: "#3A3D45"),
             AdaptiveColor.dual(light: "#17181B", dark: "#23252B")],
    startPoint: .top, endPoint: .bottom
  )

  /// Champagne-gold foil — the single Plus accent. Warm, to sit with the
  /// app's New York serif. Used flat for fills/strokes…
  static let foil = fixed("#C9A86A")
  /// …and as a metallic sweep for rims and the avatar ring.
  static let foilGradient = LinearGradient(
    colors: [fixed("#E7D29A"), fixed("#C9A86A"), fixed("#9C7E45")],
    startPoint: .topLeading, endPoint: .bottomTrailing
  )

  /// A faint top-down white sheen clipped to a rounded rect of `corner`, laid
  /// over an `ink` surface so it reads as raised metal with a glossed top edge
  /// rather than a flat slab — the cue that sells the card in dark mode.
  static func sheen(corner: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: corner, style: .continuous)
      .fill(LinearGradient(colors: [.white.opacity(0.10), .clear],
                           startPoint: .top, endPoint: .center))
      .allowsHitTesting(false)
  }
}
