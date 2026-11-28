import Foundation

// The account's avatar (#857): a photo, one emoji, or initials on a color
// from `registry/tokens.json` `avatarColors`. Wire shape and routes:
// backend/src/store/avatar.ts and backend/src/api/avatar.ts. The same shape
// rides on every member of a shared project (`ProjectShare.Member.avatar`).
//
// Decoding is lenient on purpose: an unknown kind draws initials, an unknown
// color draws the default color (Persimmon), and a missing field takes its default. A
// newer server must never make an avatar (or the share row that carries it)
// fail to decode.

extension RegistryAvatarColor {
  /// The palette entry for an id. A missing or unknown id is the default
  /// color (Persimmon, `tokens.json` `avatarColors.default`).
  static func resolve(_ id: String?) -> RegistryAvatarColor {
    let all = RegistryTokens.avatarColors
    return all.first { $0.id == id }
      ?? all.first { $0.id == RegistryTokens.avatarDefaultColorId }
      ?? all[0]
  }
}

struct AccountAvatar: Codable, Hashable, Sendable {
  enum Kind: String, Sendable, CaseIterable {
    case photo, emoji, initials
  }

  /// The kind as the server sent it. Unknown values stay, so a round trip
  /// does not lose them; `kind` reads them as initials.
  var kindRaw: String
  /// An id from `RegistryTokens.avatarColors`, or nil.
  var color: String?
  /// One to three letters the person typed. Nil: derive them from the name.
  var initials: String?
  /// One emoji grapheme, when the kind is emoji.
  var emoji: String?
  /// Changes with every new photo. Cache key, and `?v=` on the photo URL.
  var photoId: String?
  /// ms since 1970. 0 is the default avatar nobody set.
  var updatedAt: Double

  init(kind: Kind, color: String?, initials: String? = nil, emoji: String? = nil,
       photoId: String? = nil, updatedAt: Double = 0) {
    self.kindRaw = kind.rawValue
    self.color = color
    self.initials = initials
    self.emoji = emoji
    self.photoId = photoId
    self.updatedAt = updatedAt
  }

  var kind: Kind {
    switch Kind(rawValue: kindRaw) {
    case .emoji where !(emoji ?? "").isEmpty: return .emoji
    case .photo where !(photoId ?? "").isEmpty: return .photo
    default: return .initials
    }
  }

  /// The palette entry for `color`. An unknown or missing id is the default.
  var palette: RegistryAvatarColor { RegistryAvatarColor.resolve(color) }

  /// The letters to draw: the typed initials, else the ones from the name.
  func letters(for name: String) -> String {
    if let initials, !initials.isEmpty { return initials.uppercased() }
    return PersonInitials.of(name)
  }

  private enum CodingKeys: String, CodingKey {
    case kind, color, initials, emoji, photoId, updatedAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    kindRaw = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? Kind.initials.rawValue
    color = try? c.decodeIfPresent(String.self, forKey: .color)
    initials = try? c.decodeIfPresent(String.self, forKey: .initials)
    emoji = try? c.decodeIfPresent(String.self, forKey: .emoji)
    photoId = try? c.decodeIfPresent(String.self, forKey: .photoId)
    updatedAt = (try? c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? 0
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(kindRaw, forKey: .kind)
    try c.encodeIfPresent(color, forKey: .color)
    try c.encodeIfPresent(initials, forKey: .initials)
    try c.encodeIfPresent(emoji, forKey: .emoji)
    try c.encodeIfPresent(photoId, forKey: .photoId)
    try c.encode(updatedAt, forKey: .updatedAt)
  }
}

/// Body of `PATCH /v1/account/avatar` (initials or emoji; a photo goes
/// through `PUT`). The server schema is strict, so only these keys exist.
/// `initials: ""` clears typed initials; nil keeps them.
struct AccountAvatarPatch: Codable, Hashable, Sendable {
  var kind: String
  var color: String?
  var initials: String?
  var emoji: String?
  /// When the person made the edit on this device, ms since 1970. An edit
  /// sent late that is older than the stored one changes nothing.
  var updatedAt: Int?
}

/// Wire shape of `GET /v1/account`.
struct BackendAccount: Decodable, Sendable {
  let userId: String
  let avatar: AccountAvatar?
}

/// Wire shape of `PATCH` / `PUT` / `DELETE /v1/account/avatar`. `applied` is
/// false when a newer edit already won: adopt the avatar the server sent.
struct BackendAvatarReply: Decodable, Sendable {
  let avatar: AccountAvatar
  let applied: Bool?
}
