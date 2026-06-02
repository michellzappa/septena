import SwiftUI

// Reusable explainer onboarding view. Plugins that have no catalog to
// seed (Mood, Gut, Tasks, Goals, Nutrition, …) use this rather than
// each rolling their own NavigationStack + close button.
//
// Visual language matches the selection-based onboardings (Caffeine,
// Habits, Chores, Cannabis, Groceries, Supplements, Training):
//   - Hero header: large accent-tinted section glyph + title + intro
//   - Grouped Form with one Section per bullet (lead = header,
//     optional SF Symbol on the row, body inside)
//   - Bottom .bar with a single bordered-prominent primary button
//
// Honors the additive-only invariant trivially — no writes happen.
// `primaryAction` defaults to `complete`, so even when a plugin wants
// an action-oriented label ("Start logging", "Open Sleep") tapping it
// just dismisses the sheet; the destination view's empty state owns
// whatever the user actually does next.

/// Hero header shared by every section's onboarding sheet — the
/// explainer-only ones (SectionExplainerView) and the selection-based
/// ones (Caffeine, Habits, …) alike. Renders the accent-tinted section
/// glyph (from `SectionManifest.iconSymbol`), the section title, and a
/// short intro paragraph, all centered. Drop it inside a `Form` as the
/// first `Section { … }` with a clear background and zero insets to
/// get the same look in both onboarding families.
@MainActor
struct SectionOnboardingHero: View {
  let sectionKey: String
  let title: String
  let intro: String

  @Environment(SectionTheme.self) private var theme
  private var accent: Color { theme.color(for: sectionKey) }
  private var heroSymbol: String {
    SectionManifest.byKey[sectionKey]?.iconSymbol ?? "circle.fill"
  }

  var body: some View {
    VStack(spacing: 12) {
      ZStack {
        Circle()
          .fill(accent.opacity(0.15))
          .frame(width: 72, height: 72)
        Image(systemName: heroSymbol)
          .scaledFont(size: 32, weight: .semibold, relativeTo: .largeTitle)
          .foregroundStyle(accent)
      }
      .accessibilityHidden(true)

      Text(title)
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)

      Text(intro)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }
}

/// `Section { SectionOnboardingHero(…) }` wrapped with the row styling
/// every onboarding needs — clear background, no list insets — so each
/// call site is one line instead of four.
extension View {
  @MainActor
  func onboardingHeroSection() -> some View {
    self
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
  }
}

@MainActor
struct SectionExplainerView: View {
  struct Bullet: Identifiable {
    let id = UUID()
    let lead: String
    let body: String
    let icon: String?

    init(_ lead: String, _ body: String, icon: String? = nil) {
      self.lead = lead
      self.body = body
      self.icon = icon
    }
  }

  let sectionKey: String
  let title: String
  let intro: String
  let bullets: [Bullet]
  let primaryActionLabel: String
  let primaryAction: () -> Void
  let complete: () -> Void

  /// Convenience for the common case where the primary action is just
  /// "dismiss the onboarding."
  init(
    sectionKey: String,
    title: String,
    intro: String,
    bullets: [Bullet],
    primaryActionLabel: String,
    complete: @escaping () -> Void
  ) {
    self.sectionKey = sectionKey
    self.title = title
    self.intro = intro
    self.bullets = bullets
    self.primaryActionLabel = primaryActionLabel
    self.primaryAction = complete
    self.complete = complete
  }

  @Environment(SectionTheme.self) private var theme

  private var accent: Color { theme.color(for: sectionKey) }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SectionOnboardingHero(sectionKey: sectionKey, title: title, intro: intro)
            .onboardingHeroSection()
        }

        ForEach(bullets) { bullet in
          Section {
            HStack(alignment: .top, spacing: 12) {
              if let icon = bullet.icon {
                Image(systemName: icon)
                  .font(.title3)
                  .foregroundStyle(accent)
                  .frame(width: 28, alignment: .center)
                  .padding(.top, 2)
              }
              VStack(alignment: .leading, spacing: 4) {
                Text(bullet.lead)
                  .font(.subheadline.weight(.semibold))
                Text(bullet.body)
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 4)
          }
        }
      }
      .formStyle(.grouped)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { complete() }
        }
      }
      .safeAreaInset(edge: .bottom) {
        Button(primaryActionLabel) { primaryAction() }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(accent)
          .frame(maxWidth: .infinity)
          .padding()
          .background(.bar)
      }
    }
  }

}
