import SwiftUI

// Identity chrome shared by both shells' Settings (docs/SEPTASK.md): the
// account avatar (#857) and the free-tier badge. Extracted from SettingsPanes.swift
// so Septena's Account surface can mirror the full app's without compiling
// the whole Settings pane file. Pure presentation, no business logic.

/// One avatar circle (#857): a photo clipped to the circle, one emoji on
/// the palette color, or initials (white on the palette color). No avatar or
/// an unknown color: initials over the neutral fill, as before avatars. A
/// photo that has not loaded draws the initials until it does.
struct AvatarCircle: View {
  let avatar: AccountAvatar?
  let name: String
  var photo: CGImage?
  var size: CGFloat
  /// Ink for initials on the neutral fill.
  var neutralInk: Color = .primary

  private var palette: RegistryAvatarColor? { avatar?.palette }

  private var fill: Color {
    if let palette { return AdaptiveColor.dual(light: palette.lightHex, dark: palette.darkHex) }
    return Color.secondary.opacity(0.18)
  }

  private var letters: String { avatar?.letters(for: name) ?? PersonInitials.of(name) }

  var body: some View {
    ZStack {
      Circle().fill(fill)
      if avatar?.kind == .photo, let photo {
        Image(decorative: photo, scale: 1)
          .resizable()
          .scaledToFill()
          .frame(width: size, height: size)
          .clipShape(Circle())
      } else if avatar?.kind == .emoji, let emoji = avatar?.emoji {
        Text(emoji)
          .font(.system(size: size * 0.52))
      } else if letters.isEmpty {
        Image(systemName: "person.fill")
          .font(.system(size: size * 0.46))
          .foregroundStyle(palette == nil ? Color.secondary : Color.white)
      } else {
        Text(letters)
          .font(.system(size: size * 0.4, weight: .semibold))
          .foregroundStyle(palette == nil ? neutralInk : .white)
          .minimumScaleFactor(0.6)
          .lineLimit(1)
      }
    }
    .frame(width: size, height: size)
  }
}

/// The account's avatar (`AvatarStore`); a supporter gets the champagne-foil
/// ring so the thanks reads as part of who they are, not a buried setting.
/// The avatar editor passes its draft in `preview`.
struct ProfileAvatar: View {
  let name: String
  let isPlus: Bool
  var size: CGFloat = 56
  /// The editor's draft. Nil: the account's avatar from `AvatarStore`.
  var preview: AvatarPreview? = nil

  var body: some View {
    AvatarCircle(avatar: preview?.avatar ?? AvatarStore.shared.avatar,
                 name: name,
                 photo: preview == nil ? AvatarStore.shared.displayPhoto : preview?.photo,
                 size: size)
      .overlay {
        if isPlus {
          Circle().inset(by: -3).strokeBorder(SeptenaPlus.foilGradient, lineWidth: 2)
        }
      }
  }
}

/// What the avatar editor shows before it saves.
struct AvatarPreview {
  var avatar: AccountAvatar
  var photo: CGImage?
}

/// The members of a shared project as avatars, at the end of the project
/// title (docs/PROJECT_SHARING_SPEC.md §8).
struct MemberAvatars: View {
  static let limit = 3
  let share: ProjectShare
  var size: CGFloat = 26

  var body: some View {
    HStack(spacing: 4) {
      ForEach(share.members.prefix(Self.limit)) { member in
        MemberAvatarCircle(shareID: share.id, member: member, size: size)
      }
      if share.members.count > Self.limit {
        Text("+\(share.members.count - Self.limit)")
          .font(.system(size: size * 0.4, weight: .semibold))
          .foregroundStyle(Theme.inkSecondary)
          .frame(width: size, height: size)
          .background(Color.secondary.opacity(0.18), in: Circle())
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(share.membersLabel)
  }
}

/// One member of a shared project. Loads a photo avatar by its `photoId`.
struct MemberAvatarCircle: View {
  let shareID: String
  let member: ProjectShare.Member
  var size: CGFloat = 26

  private var photoId: String? { member.avatar?.kind == .photo ? member.avatar?.photoId : nil }

  var body: some View {
    AvatarCircle(avatar: member.avatar,
                 name: member.name,
                 photo: photoId.flatMap { AvatarStore.shared.memberPhotos[$0] },
                 size: size,
                 neutralInk: Theme.inkSecondary)
      .task(id: photoId) {
        guard photoId != nil else { return }
        await AvatarStore.shared.loadMemberPhoto(shareID: shareID, member: member)
      }
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
