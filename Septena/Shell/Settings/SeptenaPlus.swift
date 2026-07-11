// Support-Septena (patronage) constants — extracted from SettingsPanes.swift
// so shells that don't compile the full Settings surface (Septask) can still
// render the supporter celebration finish in LogCommit — see docs/SEPTASK.md.

import SwiftUI

// MARK: - Support Septena (patronage, not a paid tier)
//
// The whole app is free — every section, every feature, forever, with
// nothing gated. "Support Septena" is a pure tip jar: an optional way to
// keep the app independent and ad-free. A supporter unlocks no in-app
// capability another user can't have; what it changes is cosmetic (a
// "Supporter" badge + the avatar foil ring) plus one timing perk — early
// access to new builds via TestFlight. That's not a paywall: everyone still
// gets every feature, supporters just get it weeks sooner. So the rule still
// holds — don't put a real in-app feature behind `plusUnlocked`, ship it
// free; early access only changes *when* you get the same build, never
// *whether*. (Delivery is operational: supporters are invited to a TestFlight
// group; there's no in-app gate to enforce it here.)
//
// Purchases run through StoreKit 2 (`SupportStore`). Locally they resolve
// against Config/Septena.storekit wired into the scheme, so the flow is
// testable with no App Store Connect account; the matching ASC products are
// still to be created (their ids are permanent once they are). `SupportStore`
// mirrors the entitlement into `SettingsKey.plusUnlocked`. (Internal type
// names keep the `SeptenaPlus` prefix for continuity; everything user-facing
// reads "Support Septena".)

/// One "why support" reason. The support screen renders the list straight
/// from `SeptenaPlus.reasons`, so adding one is a one-line append. Keep `id`
/// stable. Also reused for the cosmetic perks a supporter actually gets.
struct SeptenaPlusFeature: Identifiable {
  let id: String
  let icon: String      // SF Symbol
  let title: String
  let detail: String
}

/// One support tier shown on the support screen. Annual is the highlighted
/// default; lifetime is the one-time "Founding Supporter". `id` maps to a
/// future StoreKit product identifier.
struct SupportTier: Identifiable {
  let id: String
  let title: String
  let price: String
  let cadence: String     // "per year" / "per month" / "one time"
  let note: String?       // e.g. "Two months free", "Lifetime"
  let highlighted: Bool
}

enum SeptenaPlus {
  /// User-facing name of the support offering (no "+", which would imply
  /// gated features — there are none).
  static let name = "Support Septena"
  /// The single word worn by a supporter (badge + thank-you copy).
  static let badgeWord = "Supporter"

  // MARK: Premium finish — "Obsidian + disc medallion"
  //
  // The rainbow is the *free* app's identity (the seven sections). The
  // membership is its refined, contained form: a graphite surface carrying a
  // single champagne-foil accent, with the spectrum distilled into a small
  // precise medallion (`SeptenaDiscMark`) — a jewel you earn, never a gradient
  // smeared across text. Restraint reads as premium; maximalism reads as free.
  //
  // Every value here is FIXED, never run through the global dark-mode `adaptive`
  // lift (`parseHexColor`): the lift hoists anything below 50% lightness up to
  // a flat gray, which would dissolve the obsidian plate into mud — exactly the
  // bug this finish exists to avoid. The foil and discs are the same in both
  // appearances (`AdaptiveColor.raw`); only `ink` is hand-tuned per mode.

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

  /// Canonical seven-disc palette (red → orange → yellow → green → cyan →
  /// blue → purple) — the only place the spectrum survives, inside the
  /// medallion. Fixed (no lift) so the jewel stays the app-icon spectrum.
  static let discColors: [Color] = [
    fixed("#ef4444"), fixed("#f97316"), fixed("#eab308"),
    fixed("#22c55e"), fixed("#06b6d4"), fixed("#3b82f6"),
    fixed("#8b5cf6"),
  ]

  /// Heptagonal disc placement (unit square), shared with `AppIconPreview`
  /// so the emblem and the home-screen icon stay one mark.
  static let discCenters: [CGPoint] = [
    CGPoint(x: 0.50, y: 0.2235), CGPoint(x: 0.7171, y: 0.3256),
    CGPoint(x: 0.7709, y: 0.5631), CGPoint(x: 0.6206, y: 0.7505),
    CGPoint(x: 0.3794, y: 0.7505), CGPoint(x: 0.2291, y: 0.5631),
    CGPoint(x: 0.2829, y: 0.3256),
  ]

  /// Why support — what the money actually does. Note none of these is a
  /// feature you unlock: they're reasons the app can stay the way it is.
  static let reasons: [SeptenaPlusFeature] = [
    .init(id: "free",
          icon: "gift",
          title: "Keeps every feature free",
          detail: "Nothing here is held back for a paid tier. Your support is the reason there's no paywall — and the promise there never will be one."),
    .init(id: "independent",
          icon: "leaf",
          title: "Keeps it independent",
          detail: "No ads, no investors, no data sold. Septena answers to the people who use it, and that only works if some of them chip in."),
    .init(id: "next",
          icon: "cpu",
          title: "Pays the AI bill",
          detail: "Septena is built by one person with a lot of AI help, and the AI is the one part that was never free. Chipping in keeps the tokens flowing — and the updates coming."),
  ]

  /// The perks a supporter actually gets: two cosmetic marks plus one real
  /// head-start — early access to new builds. Deliberately small; the point
  /// is to support the app, not to buy in-app capability.
  static let perks: [SeptenaPlusFeature] = [
    .init(id: "badge",
          icon: "checkmark.seal",
          title: "A Supporter badge",
          detail: "A quiet mark on your profile and a foil ring on your avatar. Just for you — it changes nothing about what the app can do."),
    .init(id: "earlyaccess",
          icon: "bolt",
          title: "Get new versions first",
          detail: "Opt into TestFlight and get new builds weeks before they reach the App Store — first to try what's next. Every feature still lands free for everyone; you just get it sooner."),
    .init(id: "thanks",
          icon: "heart",
          title: "Our genuine thanks",
          detail: "You're keeping a private, independent app alive. That's the whole deal, and it matters more than any feature could."),
  ]

  /// Support tiers, annual first (the highlighted default). A supporter
  /// picks one; none unlocks more than any other — they're amounts, not
  /// plans. Lifetime is the one-time "Founding Supporter".
  static let tiers: [SupportTier] = [
    .init(id: "annual",   title: "Annual",
          price: "€77", cadence: "per year",
          note: "Two months free", highlighted: true),
    .init(id: "monthly",  title: "Monthly",
          price: "€7",  cadence: "per month",
          note: nil, highlighted: false),
    .init(id: "lifetime", title: "Founding Supporter",
          price: "€177", cadence: "one time",
          note: "Lifetime — for being here early", highlighted: false),
  ]
}
