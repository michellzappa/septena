import Foundation

// The app's release notes, read once from the bundled `changelog.json`
// (Septena/Resources/changelog.json — the canonical, hand-curated source that
// is ALSO mirrored to the website). This type is the in-app reader: it powers
// the "What's New" launch sheet and the Settings ▸ About ▸ What's New history.
//
// Authoring lives in changelog.json, not here. See docs/VERSIONING.md.

public struct ChangelogHighlight: Codable, Hashable, Identifiable, Sendable {
  /// Short, user-facing headline for one change.
  public var title: String
  /// Optional sentence of context shown beneath the title.
  public var detail: String?
  /// Optional `SectionManifest` key — drives the accent color on the row.
  /// `nil` for app-wide changes.
  public var section: String?

  public var id: String { title }
}

public struct ChangelogRelease: Codable, Hashable, Identifiable, Sendable {
  /// Marketing version, e.g. "0.1.0" (matches `CFBundleShortVersionString`).
  public var version: String
  /// The build number this release shipped as, when known.
  public var build: Int?
  /// Release date, `YYYY-MM-DD`.
  public var date: String
  /// Optional codename shown beside the version.
  public var name: String?
  /// Optional one-line summary of the release.
  public var summary: String?
  public var highlights: [ChangelogHighlight]

  public var id: String { version }
}

public enum Changelog {
  private struct File: Codable { var releases: [ChangelogRelease] }

  /// Every release, newest first. Decoded once from the bundled JSON; an
  /// absent or malformed file fails soft to an empty list so the app never
  /// crashes on a bad changelog.
  public static let releases: [ChangelogRelease] = load()

  /// The most recent release, or `nil` if the changelog is empty.
  public static var latest: ChangelogRelease? { releases.first }

  /// Releases strictly newer than the version the user last saw — the cut
  /// shown in the "What's New" sheet on update.
  public static func unseen(since seen: String) -> [ChangelogRelease] {
    releases.filter { compare($0.version, seen) == .orderedDescending }
  }

  /// SemVer-ish comparison of dotted version strings ("0.2.0" vs "0.1.3").
  /// Missing components count as 0; non-numeric suffixes are ignored.
  public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let a = parts(lhs), b = parts(rhs)
    for i in 0..<Swift.max(a.count, b.count) {
      let x = i < a.count ? a[i] : 0
      let y = i < b.count ? b[i] : 0
      if x != y { return x < y ? .orderedAscending : .orderedDescending }
    }
    return .orderedSame
  }

  private static func parts(_ s: String) -> [Int] {
    s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
  }

  private static func load() -> [ChangelogRelease] {
    guard let url = Bundle.main.url(forResource: "changelog", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(File.self, from: data)
    else { return [] }
    return file.releases.sorted { compare($0.version, $1.version) == .orderedDescending }
  }
}
