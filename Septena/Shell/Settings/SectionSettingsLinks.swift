import SwiftUI

/// A hand-picked route from a section's settings to an app-wide setting that
/// changes how that section works. The destination remains the single source
/// of truth; this is only a contextual way to reach it.
struct SectionSettingsRoute: Identifiable, Hashable {
  let destination: SettingsView.SettingsDestination
  let title: String
  let systemImage: String
  let detail: String

  var id: SettingsView.SettingsDestination { destination }
}

/// Section ownership is intentionally explicit. Do not infer relationships
/// from a matching icon or broad product category: a link belongs here only
/// when the connected app or global setting directly supplies data to, or is
/// directly configured by, that section.
enum SectionSettingsLinks {
  static func forSection(_ sectionKey: String) -> [SectionSettingsRoute] {
    switch sectionKey {
    case "tasks":
      [
        link(.connectedApp(.reminders),
             detail: "Choose the Reminders list to bring into your Inbox."),
        link(.connectedApp(.calendar),
             detail: "Choose which calendar events appear with Today and Upcoming."),
        link(.connectedApp(.things),
             detail: "Move a Things database into Tasks with a one-time import."),
        link(.claudeAI,
             title: "AI & Claude",
             systemImage: "brain.head.profile",
             detail: "Choose how Claude can create and organize tasks."),
      ]

    case "activity":
      [link(.connectedApp(.appleHealth),
            detail: "Grant the Apple Health access used for activity and recovery data.")]

    case "sleep":
      [link(.connectedApp(.oura),
            detail: "Connect the Oura account that supplies your sleep history.")]

    case "body":
      [link(.connectedApp(.withings),
            detail: "Connect the Withings scale that supplies body-composition trends.")]

    case "nutrition":
      [
        link(.connectedApp(.appleHealth),
             detail: "Choose whether meal, macro, and water entries are written to Apple Health."),
        link(.connectedApp(.photos),
             detail: "Allow the meal photos and image analysis used in your nutrition log."),
      ]

    case "hydration":
      [link(.connectedApp(.appleHealth),
            detail: "Choose whether your water entries are written to Apple Health.")]

    case "mood":
      [link(.connectedApp(.appleHealth),
            detail: "Choose whether mood check-ins are written to Apple Health.")]

    case "github":
      [link(.connectedApp(.github),
            detail: "Connect the GitHub account that supplies your contribution history.")]

    default:
      []
    }
  }

  private static func link(_ destination: SettingsView.SettingsDestination,
                           title: String? = nil,
                           systemImage: String? = nil,
                           detail: String) -> SectionSettingsRoute {
    switch destination {
    case .connectedApp(let app):
      return SectionSettingsRoute(destination: destination,
                                  title: title ?? app.title,
                                  systemImage: systemImage ?? app.systemImage,
                                  detail: detail)
    default:
      return SectionSettingsRoute(destination: destination,
                                  title: title ?? "Settings",
                                  systemImage: systemImage ?? "gear",
                                  detail: detail)
    }
  }
}

/// A compact, Settings-native group of links to the canonical global pages
/// that affect this one section. It deliberately contains no toggles or
/// editable controls, preventing a second copy of a setting from drifting.
struct SectionContextualSettings: View {
  let sectionKey: String

  private var links: [SectionSettingsRoute] {
    SectionSettingsLinks.forSection(sectionKey)
  }

  var body: some View {
    if !links.isEmpty {
      Section {
        ForEach(links) { link in
          NavigationLink(value: link.destination) {
            VStack(alignment: .leading, spacing: 3) {
              Label(link.title, systemImage: link.systemImage)
                .foregroundStyle(.primary)
              Text(link.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityHint(link.detail)
        }
      } header: {
        Label("Related Settings", systemImage: "slider.horizontal.3")
      } footer: {
        Text("These controls are shared across Septena. Open one to change its canonical setting without leaving this section's context.")
      }
    }
  }
}
