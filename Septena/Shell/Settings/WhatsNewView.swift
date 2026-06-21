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
  @State private var showLegend = false

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
    // The dot-color key used to live as a section at the bottom of the list,
    // which sank out of reach as releases piled up. It's a top-right ⓘ popover
    // now — always one tap away, anchored to the button.
    .toolbar {
      if !legendItems.isEmpty {
        ToolbarItem(placement: .primaryAction) {
          Button { showLegend.toggle() } label: {
            Image(systemName: "info.circle")
          }
          .accessibilityLabel("What the dots mean")
          .popover(isPresented: $showLegend) { legendPopover }
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

  /// A key explaining the colored dots: each highlight is dotted with the
  /// color of the section it touches (Nutrition, Sleep, …), so the notes read
  /// in the app's own visual language. Only lists the sections that actually
  /// appear in the shown releases, in first-seen order, plus "General" for
  /// app-wide changes with no section. Shown from the top-right ⓘ button.
  private var legendPopover: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("What the dots mean").font(.headline)
      ForEach(legendItems, id: \.label) { item in
        HStack(spacing: 10) {
          Circle().fill(item.color).frame(width: 8, height: 8)
          Text(item.label).font(.callout)
        }
      }
      Text("Each note is dotted with the color of the section it belongs to.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding()
    .frame(maxWidth: 280, alignment: .leading)
    #if os(iOS)
    .presentationCompactAdaptation(.popover)
    #endif
  }

  private var legendItems: [(label: String, color: Color)] {
    var keys: [String] = []
    var hasGeneral = false
    for release in releases {
      for highlight in release.highlights {
        if let key = highlight.section, !key.isEmpty {
          if !keys.contains(key) { keys.append(key) }
        } else {
          hasGeneral = true
        }
      }
    }
    var items: [(label: String, color: Color)] = keys.map { key in
      let stored = store.sections.first(where: { $0.key == key })?.label ?? ""
      return (SectionManifest.displayLabel(key: key, stored: stored), accent(for: key))
    }
    if hasGeneral { items.append((String(localized: "General"), .accentColor)) }
    return items
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
      Text(displayName)
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

  /// The latest, not-yet-numbered entry is shipped in the running build — so it
  /// reads "Latest", not "In development". Released entries keep their name.
  private var displayName: String {
    if release.isUnreleased { return String(localized: "Latest") }
    return release.name ?? "Version \(release.version)"
  }

  /// Date plus the build (commit) number — the same for every entry, including
  /// the latest (the cron stamps its date each time work lands).
  private var trailing: String {
    let build = release.build.map { "Build \($0)" }
    return [formattedDate, build].compactMap { $0 }.joined(separator: " · ")
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
