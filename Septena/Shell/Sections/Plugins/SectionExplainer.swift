import SwiftUI

// Reusable explainer-only onboarding view. Plugins that have no
// catalog to seed (Mood, Gut, Tasks, Goals, Nutrition, …) use this
// rather than each rolling their own NavigationStack + close button.
//
// Honors the additive-only invariant trivially — no writes happen.

@MainActor
struct SectionExplainerView: View {
  let sectionKey: String
  let title: String
  let intro: String
  let bullets: [(String, String)]   // (lead, body) — lead is bold, body is plain
  let actionLabel: String
  let complete: () -> Void

  @Environment(SectionTheme.self) private var theme

  private var accent: Color { theme.color(for: sectionKey) }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text(intro)
            .foregroundStyle(.secondary)

          ForEach(Array(bullets.enumerated()), id: \.offset) { _, item in
            VStack(alignment: .leading, spacing: 4) {
              Text(item.0).font(.subheadline).bold()
              Text(item.1).font(.subheadline).foregroundStyle(.secondary)
            }
          }
        }
        .padding()
      }
      .navigationTitle(title)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .safeAreaInset(edge: .bottom) {
        Button(actionLabel) { complete() }
          .buttonStyle(.borderedProminent)
          .tint(accent)
          .frame(maxWidth: .infinity)
          .padding()
          .background(.bar)
      }
    }
  }
}
