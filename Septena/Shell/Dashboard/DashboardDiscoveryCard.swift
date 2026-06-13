import SwiftUI
import SwiftData

// Dashboard discovery card. Introduces the capabilities the first-run welcome
// deliberately leaves out — the Coach, Insights, and integrations like Apple
// Health — once the user is in the app, rather than front-loading them into
// onboarding. Each suggestion only appears while its capability is still
// undiscovered; acting on one enables it (or opens it) and drops the row, and
// the whole card can be dismissed.
//
// Timing: shows immediately for now. The natural next step is an engagement
// gate (e.g. only after the account has logged on a few distinct days) so it
// reads as "you've got the hang of this — here's more" rather than more
// onboarding; `shouldGate` is the single seam for that.

struct DashboardDiscoveryCard: View {
  /// Opens a section/meta destination through the dashboard's own `open(_:)`,
  /// so the card reuses the exact push-vs-sheet behaviour of a tile tap.
  let onOpen: (WeekDestination) -> Void

  @Environment(SettingsStore.self) private var store
  @Environment(SectionTheme.self) private var theme
  @Environment(NavigationState.self) private var nav
  @Environment(\.modelContext) private var modelContext

  /// Whole-card dismissal (device-local). Persists so the card doesn't return.
  @AppStorage("septena.discovery.dismissed") private var dismissed = false
  /// Insights isn't a section with an enabled flag, so its "discovered" state
  /// is tracked here — set once the user opens it from the card.
  @AppStorage("septena.discovery.insightsSeen") private var insightsSeen = false

  /// Suggestions acted on this session — hidden immediately without waiting on
  /// a store refresh, so a tapped row disappears at once.
  @State private var actedOn: Set<Suggestion> = []

  private enum Suggestion: String, CaseIterable, Hashable {
    case coach, insights, activity
  }

  // MARK: Derivation

  private func isEnabled(_ key: String) -> Bool {
    store.sections.first { $0.key == key }?.isEnabled ?? false
  }

  /// The undiscovered capabilities, in display order. A capability drops off
  /// once it's enabled (Coach/Activity) or seen (Insights), or acted on this
  /// session.
  private var suggestions: [Suggestion] {
    Suggestion.allCases.filter { s in
      guard !actedOn.contains(s) else { return false }
      switch s {
      case .coach:    return !isEnabled("goals")
      case .insights: return !insightsSeen
      case .activity: return !isEnabled("activity")
      }
    }
  }

  var body: some View {
    if !dismissed, !suggestions.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        header
        ForEach(suggestions, id: \.self) { row(for: $0) }
      }
      // Match the tile grid below: same white card surface and corner radius,
      // not a gray banner.
      .background(
        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
          .fill(Theme.secondaryGroupedBackground)
      )
      .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
  }

  // MARK: Pieces

  private var header: some View {
    HStack {
      Text("Discover more")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      Spacer()
      Button {
        withAnimation { dismissed = true }
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 14)
    .padding(.top, 12)
    .padding(.bottom, 4)
  }

  private func row(for s: Suggestion) -> some View {
    let info = presentation(for: s)
    return Button {
      act(on: s)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: info.icon)
          .font(.title3)
          .foregroundStyle(info.accent)
          .frame(width: 30, alignment: .center)
        VStack(alignment: .leading, spacing: 2) {
          Text(info.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
          Text(info.subtitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func presentation(for s: Suggestion) -> (icon: String, title: String, subtitle: String, accent: Color) {
    switch s {
    case .coach:
      return ("smallcircle.filled.circle", "Meet your Coach",
              "Set a goal over what you track.", theme.color(for: "goals"))
    case .insights:
      return ("chart.xyaxis.line", "See what connects",
              "Find correlations across your data.", .accentColor)
    case .activity:
      return ("figure.walk", "Connect Apple Health",
              "Add steps and movement from HealthKit.", theme.color(for: "activity"))
    }
  }

  // MARK: Actions

  private func act(on s: Suggestion) {
    withAnimation { _ = actedOn.insert(s) }
    switch s {
    case .coach:
      enableSection("goals")
      nav.pendingTab = .goals
    case .insights:
      insightsSeen = true
      onOpen(.insights)
    case .activity:
      // Enabling reveals the tile; opening the destination is what prompts the
      // HealthKit grant (the connect flow lives there, not here).
      enableSection("activity")
      onOpen(.activity)
    }
  }

  private func enableSection(_ key: String) {
    SettingsMirror.setSectionEnabled(key, true,
                                     context: modelContext,
                                     engine: SeptenaServices.shared.ckEngine)
    // Keep the in-memory store in step so every surface (and this card) sees
    // the enable now, not just after the next launch reload.
    store.sections = SettingsMirror.loadSections(context: modelContext)
    // The enable auto-assigned an accent; repaint the theme cache so the new
    // tile shows its color right away rather than the fallback gray.
    theme.paintFromCache()
  }
}
