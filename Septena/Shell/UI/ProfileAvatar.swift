import SwiftUI

// Identity chrome shared by both shells' Settings (docs/SEPTASK.md): the
// monogram avatar and the free-tier badge. Extracted from SettingsPanes.swift
// so Septask's Account surface can mirror the full app's without compiling
// the whole Settings pane file. Pure presentation, no business logic.

/// Circular monogram avatar. Initials over a neutral fill; a supporter
/// gets the champagne-foil ring so the thanks reads as part of who they
/// are, not a buried setting.
struct ProfileAvatar: View {
  let name: String
  let isPlus: Bool
  var size: CGFloat = 56

  private var initials: String {
    let words = name.trimmingCharacters(in: .whitespaces).split(separator: " ")
    // A single short token is almost certainly typed-in initials ("MZ",
    // "abc") — show it verbatim. A longer single name → its first letter.
    // Multi-word → first letter of the first two words.
    if words.count <= 1 {
      let token = words.first.map(String.init) ?? ""
      return (token.count <= 3 ? token : String(token.prefix(1))).uppercased()
    }
    return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
  }

  var body: some View {
    ZStack {
      Circle().fill(Color.secondary.opacity(0.18))
      if initials.isEmpty {
        Image(systemName: "person.fill")
          .font(.system(size: size * 0.46))
          .foregroundStyle(.secondary)
      } else {
        Text(initials)
          .font(.system(size: size * 0.4, weight: .semibold))
          .foregroundStyle(.primary)
      }
    }
    .frame(width: size, height: size)
    .overlay {
      if isPlus {
        Circle().inset(by: -3).strokeBorder(SeptenaPlus.foilGradient, lineWidth: 2)
      }
    }
  }
}

/// The quiet counterpart to `SeptenaPlusBadge`, worn by a non-supporter. The
/// whole app is free, so this is a plain statement of fact, not a nudge — a
/// muted capsule with no foil, deliberately understated next to the supporter
/// mark. It only exists so the profile reads the same either way (a labelled
/// tier) instead of looking empty until you support.
struct FreeAccountBadge: View {
  var body: some View {
    Text("Free")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(.quaternary, in: Capsule())
  }
}
