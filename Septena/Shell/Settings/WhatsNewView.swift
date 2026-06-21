import SwiftUI

// "What's New" — two entry points over the same `Changelog` data:
//   • `ChangelogList`  — bare list content, pushed inside Settings ▸ About.
//   • `WhatsNewSheet`  — a self-contained sheet (its own NavigationStack +
//                        Done button) shown automatically after an update.
//
// Highlights tagged with a section key pick up that section's accent color so
// the notes read in the same visual language as the rest of the app.

/// The release history as plain list content (no navigation wrapper). Used by
/// the Settings pane, which already supplies the NavigationStack + title.
struct ChangelogList: View {
  @Environment(SettingsStore.self) private var store
  var releases: [ChangelogRelease] = Changelog.releases

  var body: some View {
    Group {
      if releases.isEmpty {
        ContentUnavailableView("No release notes yet",
                               systemImage: "doc.text",
                               description: Text("Updates will show up here."))
      } else {
        List {
          ForEach(releases) { release in
            Section {
              ForEach(release.highlights) { highlight in
                HighlightRow(highlight: highlight, accent: accent(for: highlight.section))
              }
            } header: {
              ReleaseHeader(release: release)
            }
          }
        }
      }
    }
  }

  private func accent(for key: String?) -> Color {
    guard let key,
          let hex = store.sections.first(where: { $0.key == key })?.color,
          !hex.isEmpty
    else { return .accentColor }
    return parseHexColor(hex)
  }
}

/// The auto-presented update sheet: the unseen releases since `since`, wrapped
/// with its own chrome and a Done button.
struct WhatsNewSheet: View {
  @Environment(\.dismiss) private var dismiss
  let since: String

  var body: some View {
    NavigationStack {
      ChangelogList(releases: Changelog.unseen(since: since))
        .navigationTitle("What's New")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
    #if os(macOS)
    .frame(width: 480, height: 560)
    #endif
  }
}

// MARK: - Rows

private struct ReleaseHeader: View {
  let release: ChangelogRelease

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(release.name ?? "Version \(release.version)")
        .font(.headline)
        .foregroundStyle(.primary)
        .textCase(nil)
      Spacer()
      Text(trailing)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textCase(nil)
    }
    .padding(.bottom, 2)
  }

  /// Date plus the build (commit) number — the in-development entry leads with
  /// "In progress" since it has no release date of its own yet.
  private var trailing: String {
    let build = release.build.map { "Build \($0)" }
    let when = release.isUnreleased ? "In progress" : formattedDate
    return [when, build].compactMap { $0 }.joined(separator: " · ")
  }

  private var formattedDate: String {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.locale = Locale(identifier: "en_US_POSIX")
    guard let date = parser.date(from: release.date) else { return release.version }
    let out = DateFormatter()
    out.dateStyle = .medium
    out.timeStyle = .none
    return out.string(from: date)
  }
}

private struct HighlightRow: View {
  let highlight: ChangelogHighlight
  let accent: Color

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Circle()
        .fill(accent)
        .frame(width: 8, height: 8)
        .padding(.top, 6)
      VStack(alignment: .leading, spacing: 2) {
        Text(highlight.title)
          .font(.callout.weight(.semibold))
          .foregroundStyle(.primary)
        if let detail = highlight.detail, !detail.isEmpty {
          Text(detail)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 2)
  }
}
