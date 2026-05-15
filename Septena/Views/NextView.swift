import SwiftUI

// Dedicated screen for the daily "next" strip: chores, habits, supplements.
// Pulled out of Today so Today stays focused on tasks (mirrors the web app).

struct NextView: View {
  @EnvironmentObject var client: SeptenaClient
  @EnvironmentObject var theme: SectionTheme

  @StateObject private var model = NextItemsModel()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ScreenTitle(icon: "arrow.right",
                    iconTint: Theme.iconMuted,
                    title: "Next")

        if !model.hasAnyOpen && !model.hasAnyDone {
          Text("Nothing here yet")
            .font(.septenaMeta)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 40)
        }

        NextOpenSection(model: model)

        if model.hasAnyDone {
          Text("Done Today")
            .font(.septenaSectionTitle)
            .foregroundStyle(Theme.inkPrimary)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, Theme.sectionSpacing)
            .padding(.bottom, 6)
          NextDoneSection(model: model)
        }

        Spacer(minLength: 140)
      }
    }
    .background(Theme.paperBackground)
    .septenaInlineTitle()
    .task { await model.load(client: client) }
    .refreshable { await model.load(client: client) }
  }
}
