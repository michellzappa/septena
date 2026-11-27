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

  private var initials: String { PersonInitials.of(name) }

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

/// The members of a shared project as initials, at the end of the
/// project title (docs/PROJECT_SHARING_SPEC.md §8).
struct MemberAvatars: View {
  static let limit = 3
  let share: ProjectShare
  var size: CGFloat = 26

  var body: some View {
    HStack(spacing: 4) {
      ForEach(share.members.prefix(Self.limit)) { circle($0.initials) }
      if share.members.count > Self.limit { circle("+\(share.members.count - Self.limit)") }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(share.membersLabel)
  }

  private func circle(_ text: String) -> some View {
    Text(text)
      .font(.system(size: size * 0.4, weight: .semibold))
      .foregroundStyle(Theme.inkSecondary)
      .frame(width: size, height: size)
      .background(Color.secondary.opacity(0.18), in: Circle())
  }
}

/// The quiet counterpart to `SeptenaPlusBadge`, worn by a free account. A
/// plain statement of fact, not a nudge: a muted capsule with no foil, so the
/// profile names its plan either way (ADR 0023).
struct FreeAccountBadge: View {
  var body: some View {
    Text(RegistryPlans.card("free")?.title ?? "")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(.quaternary, in: Capsule())
  }
}

/// Compact "Plus" or "Pro" pill worn on the profile of a paid account. Ink
/// capsule with a champagne-foil hairline and a small foil mark. The server
/// decides the plan (`PlanStatus`); this badge only shows it.
struct SeptenaPlusBadge: View {
  var isPro = false

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: isPro ? RegistryIcons.sfSymbols["plans.pro"] ?? "infinity" : "plus")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(SeptenaPlus.foil)
      Text(isPro ? RegistryPlans.proName : RegistryPlans.shortName)
        .foregroundStyle(.white)
    }
    .font(.caption2.weight(.bold))
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(SeptenaPlus.ink, in: Capsule())
    .overlay(Capsule().strokeBorder(SeptenaPlus.foil.opacity(0.5), lineWidth: 0.75))
  }
}
