// The premium language (docs/PREMIUM_LANGUAGE.md): the few pieces every paid
// surface draws with, so the plan page, the plan sheet, onboarding and every
// upsell line look like one product.
//
// - `PlanMark`: the plan's tile. Plus is a brand tile with an ink glyph; Pro
//   is an ink tile with a brand glyph. Free has no mark.
// - `PlanWordmark`: "Septena" in the label color, the plan name in the brand
//   color.
// - `BenefitTile` / `PlanBenefitRow`: one benefit, Settings-style: a small
//   filled tile in the benefit's own color (`tokens.json` `multicolorGlyphs`
//   under Colorful, the accent under every other fruit), a short title, one
//   line of detail. Words come from `plans.json` `benefits`.
//
// The brand color is `AppearancePreferences.magicPlusSwiftUIColor`:
// Persimmon under Colorful, the chosen fruit otherwise. Never system blue,
// never sparkles, never a lock or a badge on a feature.

import SwiftUI

extension PlanTier {
  /// What the plan gives, one line each (`plans.json` `benefits`).
  var benefits: [RegistryPlanBenefit] {
    switch self {
    case .plus: return RegistryPlans.plusBenefits
    case .pro: return RegistryPlans.proBenefits
    }
  }

  /// The mark's glyph (`icons.json`).
  var markIcon: String {
    switch self {
    case .plus: return "plans.plus"
    case .pro: return RegistryPlans.proCard.icon
    }
  }
}

/// The plan's tile. Sized by the caller; the corner and glyph scale with it.
struct PlanMark: View {
  let tier: PlanTier
  var size: CGFloat = 44

  private var appearance: AppearancePreferences { .shared }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
    ZStack {
      switch tier {
      case .plus:
        shape.fill(appearance.magicPlusSwiftUIColor.gradient)
      case .pro:
        shape.fill(Color.primary.gradient)
      }
      Image(systemName: RegistryIcons.sfSymbols[tier.markIcon] ?? "plus")
        .font(.system(size: size * 0.48, weight: .bold))
        .foregroundStyle(glyph)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private var glyph: Color {
    switch tier {
    case .plus: return appearance.magicPlusInkSwiftUIColor
    case .pro: return appearance.magicPlusSwiftUIColor
    }
  }
}

/// "Septena Plus" / "Septena Pro": the product name in the label color, the
/// plan name in the brand color.
struct PlanWordmark: View {
  let tier: PlanTier
  var font: Font = .title2.weight(.bold)

  var body: some View {
    let full = tier.card?.title ?? tier.title
    let product = full.replacingOccurrences(of: tier.title, with: "").trimmingCharacters(in: .whitespaces)
    let plan = Text(tier.title).foregroundStyle(AppearancePreferences.shared.magicPlusSwiftUIColor)
    Group {
      if product.isEmpty {
        plan
      } else {
        Text("\(Text(product)) \(plan)")
      }
    }
    .font(font)
    .accessibilityLabel(full)
  }
}

/// One benefit's tile: a filled square in the benefit's color, a white glyph.
struct BenefitTile: View {
  let icon: String
  var size: CGFloat = 30

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
      .fill(AppearancePreferences.shared.glyphSwiftUIColor(icon).gradient)
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: RegistryIcons.sfSymbols[icon] ?? "circle")
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(.white)
      }
      .accessibilityHidden(true)
  }
}

/// A benefit as a row: tile, title, one line of detail. Never truncated: the
/// text wraps.
struct PlanBenefitRow: View {
  let benefit: RegistryPlanBenefit

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      BenefitTile(icon: benefit.icon)
      VStack(alignment: .leading, spacing: 2) {
        Text(benefit.title).font(.body.weight(.semibold))
        Text(benefit.detail).font(.subheadline).foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The plan's head: mark, wordmark, and one line under it.
struct PlanHead: View {
  let tier: PlanTier
  var line: String?
  var markSize: CGFloat = 56

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      PlanMark(tier: tier, size: markSize)
      VStack(alignment: .leading, spacing: 3) {
        PlanWordmark(tier: tier)
        if let line {
          Text(line).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
  }
}
