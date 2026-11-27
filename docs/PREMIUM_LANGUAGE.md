# The premium language

Status: current (2026-11-27). Owner: mz. Applies to every surface that names a
paid plan: the plan page, the plan sheet, onboarding (the trial step), upsell
lines, the account card, and the website's plan cards.

One visual and verbal language for Plus and Pro, built from platform
primitives. When a surface talks about a plan, it uses these pieces and no
others.

## The pieces

| Piece | What it is | Apple | Android | Data |
|---|---|---|---|---|
| **Plan mark** | A rounded-square tile (corner 27% of the side, continuous). Plus: brand fill, ink glyph `plans.plus`. Pro: label-color fill, brand glyph `plans.pro` (infinity). Free has no mark. | `PlanMark` | `PlanMark` | `icons.json` |
| **Wordmark** | "Septena" in the text color, the plan name in the brand color, same weight. | `PlanWordmark` | `PlanWordmark` | `plans.json` `cards[].title`, `shortName`, `proName` |
| **Plan head** | Mark, wordmark, one line under it (the plan's card line, or its date: "Pro through …"). | `PlanHead` | `PlanHead` | `cards[].detail`, `status` |
| **Benefit row** | A 30 pt Settings-style tile in the benefit's own color with a white glyph, a semibold title, one line of detail. Text wraps; it never truncates. | `PlanBenefitRow`, `BenefitTile` | `PlanBenefitRow` | `plans.json` `benefits` |

Code: `Septena/Shell/UI/PlanLanguage.swift`,
`android/app/src/main/kotlin/app/septena/android/ui/PlanLanguage.kt`,
`web/src/components/PlanLanguage.tsx` (with `web/src/lib/plans.ts`; colors as
CSS variables `--brand`, `--plan-*`). The web reads the words from the
generated `PLAN_UI`.

## Color

- **Brand** is the Magic Plus color: Persimmon under Colorful (the default),
  the chosen fruit under any other accent (`magicPlusSwiftUIColor`,
  `LocalMagicPlusColors`). Never system blue for a plan.
- **Benefit tiles** keep their semantic color under Colorful
  (`tokens.json` `multicolorGlyphs`: devices blue, agents Persimmon, files
  teal, history indigo) and take the accent under every other fruit, like
  the Today sun.

## Words

- A benefit is an outcome, not a feature name: "Every device, always
  current", "Three agents at work", "A year of history". One short title,
  one line of detail that says what the reader gets.
- A benefit with a limit states that plan's value; the generator checks it
  against `limits` (a number, its word, or "no limit" for null).
- Pro lists only what it adds, then "Everything in Plus".
- Every word lives in `registry/plans.json` and goes through the humanizer
  skill. No em dashes.

## Layout rules

- **No comparison grid in the app.** A phone cannot fit four columns. The
  app shows the account's benefits ("Your plan includes") and each plan
  above it as head, benefits, price, one button. "Compare every plan" links
  to the website's table (`plans.json` `compareURL`).
- **Why first, price last** in the sheet: the moment, the plan picker, the
  benefits, then StoreKit's price (spec §7.1).
- A plan page shows only plans above the account's plan. Pro shows its own
  benefits and Manage, nothing to buy.

## Never

- Sparkles, crowns, diamonds, stars or gradients that are not the brand tile.
- A lock or a badge on a feature (banned in the plans strategy: a limit
  shows as a quiet line where it is, never as a badge).
- A plan-only "not yet" line, or copy that asks the reader to write in
  (ADR 0059).
- A custom store UI. StoreKit draws prices and the purchase button.

## Onboarding

The first run's trial step uses the same pieces: `PlanHead(.plus)` and the
Plus benefit rows, so the trial reads as the plan the reader will see in
Settings and in the sheet.
