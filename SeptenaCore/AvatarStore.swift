import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

// The account avatar on this device (#857, backend/src/api/avatar.ts).
//
// - Caches the last `GET /v1/account` avatar (UserDefaults) and its photo
//   (Application Support), so the avatar draws at launch with no network.
// - Initials and emoji save locally at once and are sent with the time of
//   the edit (`updatedAt`); the server keeps the newer one. A photo uploads
//   only when online; until then the cropped JPEG waits on disk.
// - `flush()` sends what waits: at launch, on foreground, after a sync run
//   (the sign that the network is back) and after sign-in. Sign-out clears
//   everything.
// - Member photos of shared projects are cached by `photoId` (memory and
//   Caches). A new photo has a new id, so an entry never goes stale.

@MainActor
@Observable
final class AvatarStore {
  static let shared = AvatarStore()

  /// Why the last photo did not reach the server, for the editor and Account.
  enum PhotoProblem: Equatable {
    /// Waits for the network (`RegistryAvatar.photoPending`).
    case pending
    /// Over `RegistryAvatar.maxPhotoBytes` (`photoTooLarge`).
    case tooLarge
    /// The upload failed (`photoFailed`).
    case failed

    var message: String {
      switch self {
      case .pending: return RegistryAvatar.photoPending
      case .tooLarge: return RegistryAvatar.photoTooLarge
      case .failed: return RegistryAvatar.photoFailed
      }
    }
  }

  /// The avatar as the server last confirmed it.
  private(set) var serverAvatar: AccountAvatar?
  /// An initials or emoji edit not sent yet.
  private(set) var pendingEdit: AccountAvatarPatch?
  /// A photo removal not sent yet.
  private(set) var pendingRemove = false
  /// The cropped photo not uploaded yet, decoded for drawing.
  private(set) var pendingPhotoImage: CGImage?
  /// The account's photo, decoded, for `serverAvatar.photoId`.
  private(set) var photo: CGImage?
  private(set) var photoProblem: PhotoProblem?
  /// Decoded member photos by `photoId`.
  private(set) var memberPhotos: [String: CGImage] = [:]

  @ObservationIgnored private var hasPendingPhoto = false
  @ObservationIgnored private var flushing = false
  @ObservationIgnored private var memberPhotosInFlight: Set<String> = []
  @ObservationIgnored private var memberPhotosFailed: Set<String> = []

  private enum Key {
    static let avatar = "septena.avatar.account"
    static let photoId = "septena.avatar.photoId"
    static let pendingEdit = "septena.avatar.pendingEdit"
    static let pendingRemove = "septena.avatar.pendingRemove"
  }

  /// Posted on the main queue when a member photo arrives, so the AppKit
  /// shell can draw its member chips again.
  static let memberPhotosChanged = Notification.Name("septena.avatar.memberPhotosChanged")

  private init() {
    let defaults = UserDefaults.standard
    serverAvatar = defaults.data(forKey: Key.avatar).flatMap { try? JSONDecoder().decode(AccountAvatar.self, from: $0) }
    pendingEdit = defaults.data(forKey: Key.pendingEdit).flatMap { try? JSONDecoder().decode(AccountAvatarPatch.self, from: $0) }
    pendingRemove = defaults.bool(forKey: Key.pendingRemove)
    if let url = Self.pendingPhotoURL, let data = try? Data(contentsOf: url) {
      hasPendingPhoto = true
      pendingPhotoImage = Self.decode(data)
      photoProblem = .pending
    }
    if let id = serverAvatar?.photoId, id == defaults.string(forKey: Key.photoId),
       let url = Self.ownPhotoURL, let data = try? Data(contentsOf: url) {
      photo = Self.decode(data)
    }
  }

  // MARK: - What to draw

  /// The avatar to draw for this account: the server's, with the edits that
  /// wait applied on top. Nil before the first answer: the neutral initials.
  var avatar: AccountAvatar? {
    var a = serverAvatar
    if pendingRemove, var current = a {
      current.kindRaw = AccountAvatar.Kind.initials.rawValue
      current.photoId = nil
      current.emoji = nil
      a = current
    }
    if let edit = pendingEdit {
      var merged = a ?? AccountAvatar(kind: .initials, color: nil)
      merged.kindRaw = edit.kind
      if let color = edit.color { merged.color = color }
      if let initials = edit.initials { merged.initials = initials.isEmpty ? nil : initials }
      merged.emoji = edit.kind == AccountAvatar.Kind.emoji.rawValue ? edit.emoji : nil
      merged.photoId = nil
      a = merged
    }
    if pendingPhotoImage != nil {
      var withPhoto = a ?? AccountAvatar(kind: .initials, color: nil)
      withPhoto.kindRaw = AccountAvatar.Kind.photo.rawValue
      withPhoto.emoji = nil
      if (withPhoto.photoId ?? "").isEmpty { withPhoto.photoId = "pending" }
      a = withPhoto
    }
    return a
  }

  /// The photo to draw for `avatar`: the one waiting to upload, else the cached one.
  var displayPhoto: CGImage? { pendingPhotoImage ?? photo }

  /// True when the account's avatar is a photo (sent or waiting).
  var hasPhoto: Bool { avatar?.kind == .photo }

  var hasPending: Bool { pendingEdit != nil || pendingRemove || hasPendingPhoto }

  // MARK: - Edits

  /// Saves initials or an emoji. Shows at once; sent now or when online.
  func save(kind: AccountAvatar.Kind, color: String?, initials: String?, emoji: String?) {
    precondition(kind != .photo, "a photo goes through savePhoto")
    let edit = AccountAvatarPatch(
      kind: kind.rawValue,
      color: color,
      initials: initials,
      emoji: kind == .emoji ? emoji : nil,
      updatedAt: Self.nowMs()
    )
    // The newest edit replaces whatever waited.
    dropPendingPhoto()
    photoProblem = nil
    pendingRemove = false
    pendingEdit = edit
    persistPending()
    kick()
  }

  /// Keeps the cropped JPEG and uploads it when online. False when it is
  /// over the limit: nothing is kept.
  @discardableResult
  func savePhoto(_ jpeg: Data) -> Bool {
    guard jpeg.count <= RegistryAvatar.maxPhotoBytes else {
      photoProblem = .tooLarge
      return false
    }
    guard let url = Self.pendingPhotoURL, (try? jpeg.write(to: url, options: .atomic)) != nil else {
      photoProblem = .failed
      return false
    }
    hasPendingPhoto = true
    pendingPhotoImage = Self.decode(jpeg)
    pendingRemove = false
    photoProblem = .pending
    persistPending()
    kick()
    return true
  }

  /// Back to initials (keeps color and typed initials).
  func removePhoto() {
    dropPendingPhoto()
    photoProblem = nil
    pendingRemove = serverAvatar?.kind == .photo
    persistPending()
    kick()
  }

  // MARK: - Server

  /// Reads the avatar again (`GET /v1/account`), after sending what waits.
  /// Called when Settings ▸ Account opens and after sign-in.
  func refresh() async {
    guard TaskBackendClient.hasSession else { return }
    await flush()
    guard !hasPending else { return }
    do {
      let account = try await TaskBackendClient.shared.getAccount()
      // A sign-out or an edit while the call ran wins.
      guard TaskBackendClient.hasSession, !hasPending else { return }
      if let avatar = account.avatar { await adopt(avatar) }
    } catch {
      SeptenaLog.info("[Avatar] refresh failed: \(error.localizedDescription)")
    }
  }

  /// Sends the edits that wait, oldest kind first: initials or emoji, then
  /// the removal, then the photo.
  func flush() async {
    guard TaskBackendClient.hasSession, hasPending, !flushing else { return }
    flushing = true
    defer { flushing = false }
    let client = TaskBackendClient.shared

    if let edit = pendingEdit {
      do {
        let reply = try await client.patchAvatar(edit)
        if pendingEdit == edit { pendingEdit = nil; persistPending() }
        await adopt(reply.avatar)
      } catch {
        guard Self.isRefusal(error) else { return }
        // The server refuses this edit for good (it fails validation):
        // drop it, so it does not block the queue.
        SeptenaLog.info("[Avatar] edit refused: \(error.localizedDescription)")
        if pendingEdit == edit { pendingEdit = nil; persistPending() }
      }
    }

    if pendingRemove {
      do {
        let avatar = try await client.deleteAvatar()
        pendingRemove = false
        persistPending()
        await adopt(avatar)
      } catch {
        guard Self.isRefusal(error) else { return }
        pendingRemove = false
        persistPending()
      }
    }

    if hasPendingPhoto, let url = Self.pendingPhotoURL, let jpeg = try? Data(contentsOf: url) {
      do {
        let reply = try await client.putAvatarPhoto(jpeg)
        // The bytes just sent are the new photo: cache them under its id.
        if let id = reply.avatar.photoId, let own = Self.ownPhotoURL,
           (try? jpeg.write(to: own, options: .atomic)) != nil {
          UserDefaults.standard.set(id, forKey: Key.photoId)
          photo = pendingPhotoImage ?? Self.decode(jpeg)
        }
        dropPendingPhoto()
        photoProblem = nil
        await adopt(reply.avatar)
      } catch {
        switch error as? TaskBackendError {
        case .http(413, _)?:
          dropPendingPhoto()
          photoProblem = .tooLarge
        case .http(415, _)?:
          dropPendingPhoto()
          photoProblem = .failed
        case .network?:
          photoProblem = .pending
        default:
          // Kept: the next flush tries again.
          photoProblem = .failed
        }
        SeptenaLog.info("[Avatar] photo upload failed: \(error.localizedDescription)")
      }
    } else if hasPendingPhoto {
      dropPendingPhoto()
    }
  }

  /// Flushes in the background when something waits. Cheap when nothing does.
  func flushIfPending() {
    guard hasPending, !flushing else { return }
    kick()
  }

  /// After a sign-in. Another account than before: forget the old one first.
  func accountSignedIn(changedAccount: Bool) {
    if changedAccount { clear() }
    Task { await refresh() }
  }

  /// Sign-out or a deleted account: nothing of this account stays.
  func clear() {
    serverAvatar = nil
    pendingEdit = nil
    pendingRemove = false
    photo = nil
    photoProblem = nil
    memberPhotos = [:]
    memberPhotosFailed = []
    dropPendingPhoto()
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: Key.avatar)
    defaults.removeObject(forKey: Key.photoId)
    defaults.removeObject(forKey: Key.pendingEdit)
    defaults.removeObject(forKey: Key.pendingRemove)
    if let own = Self.ownPhotoURL { try? FileManager.default.removeItem(at: own) }
    if let dir = Self.memberCacheDirectory { try? FileManager.default.removeItem(at: dir) }
  }

  // MARK: - Member photos

  /// Loads a member's photo into `memberPhotos` (disk cache first, then the
  /// server). Call from a `.task(id: photoId)`, never from a view body.
  func loadMemberPhoto(shareID: String, member: ProjectShare.Member) async {
    guard let avatar = member.avatar, avatar.kind == .photo, let photoId = avatar.photoId,
          memberPhotos[photoId] == nil, !memberPhotosInFlight.contains(photoId),
          !memberPhotosFailed.contains(photoId) else { return }
    if let file = Self.memberPhotoURL(photoId), let data = try? Data(contentsOf: file), let image = Self.decode(data) {
      memberPhotos[photoId] = image
      NotificationCenter.default.post(name: Self.memberPhotosChanged, object: nil)
      return
    }
    guard TaskBackendClient.hasSession else { return }
    memberPhotosInFlight.insert(photoId)
    defer { memberPhotosInFlight.remove(photoId) }
    do {
      let data = try await TaskBackendClient.shared.memberAvatarPhoto(shareID: shareID, memberID: member.id, photoId: photoId)
      guard let image = Self.decode(data) else { memberPhotosFailed.insert(photoId); return }
      if let dir = Self.memberCacheDirectory, let file = Self.memberPhotoURL(photoId) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
      }
      memberPhotos[photoId] = image
      NotificationCenter.default.post(name: Self.memberPhotosChanged, object: nil)
    } catch {
      // A 404 (the member left, the photo changed) stays failed until next
      // launch; a network error tries again on the next draw.
      if Self.isRefusal(error) { memberPhotosFailed.insert(photoId) }
    }
  }

  // MARK: - Private

  private func adopt(_ avatar: AccountAvatar) async {
    serverAvatar = avatar
    if let data = try? JSONEncoder().encode(avatar) {
      UserDefaults.standard.set(data, forKey: Key.avatar)
    }
    guard avatar.kind == .photo, let id = avatar.photoId else {
      photo = nil
      UserDefaults.standard.removeObject(forKey: Key.photoId)
      if let own = Self.ownPhotoURL { try? FileManager.default.removeItem(at: own) }
      return
    }
    guard UserDefaults.standard.string(forKey: Key.photoId) != id || photo == nil else { return }
    do {
      let data = try await TaskBackendClient.shared.avatarPhoto(photoId: id)
      // A newer avatar landed while the photo downloaded.
      guard serverAvatar?.photoId == id, let image = Self.decode(data) else { return }
      if let own = Self.ownPhotoURL, (try? data.write(to: own, options: .atomic)) != nil {
        UserDefaults.standard.set(id, forKey: Key.photoId)
      }
      photo = image
    } catch {
      SeptenaLog.info("[Avatar] photo download failed: \(error.localizedDescription)")
    }
  }

  private func kick() {
    Task { await self.flush() }
  }

  private func dropPendingPhoto() {
    hasPendingPhoto = false
    pendingPhotoImage = nil
    if photoProblem == .pending { photoProblem = nil }
    if let url = Self.pendingPhotoURL { try? FileManager.default.removeItem(at: url) }
  }

  private func persistPending() {
    let defaults = UserDefaults.standard
    if let pendingEdit, let data = try? JSONEncoder().encode(pendingEdit) {
      defaults.set(data, forKey: Key.pendingEdit)
    } else {
      defaults.removeObject(forKey: Key.pendingEdit)
    }
    defaults.set(pendingRemove, forKey: Key.pendingRemove)
  }

  /// A 4xx the server will answer again the same way. 401 is not one: the
  /// client refreshes the session, and a session that ended throws
  /// `notSignedIn`.
  private static func isRefusal(_ error: Error) -> Bool {
    switch error as? TaskBackendError {
    case .http(let status, _)?: return (400..<500).contains(status) && status != 401 && status != 429
    case .badResponse?: return true
    default: return false
    }
  }

  private static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

  private static var avatarDirectory: URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    let dir = base.appendingPathComponent("Avatar", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static var ownPhotoURL: URL? { avatarDirectory?.appendingPathComponent("account.jpg") }
  private static var pendingPhotoURL: URL? { avatarDirectory?.appendingPathComponent("pending.jpg") }

  private static var memberCacheDirectory: URL? {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("MemberAvatars", isDirectory: true)
  }

  private static func memberPhotoURL(_ photoId: String) -> URL? {
    // The id is server-made; keep only safe characters for a file name.
    let safe = String(photoId.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
    guard !safe.isEmpty else { return nil }
    return memberCacheDirectory?.appendingPathComponent("\(safe).jpg")
  }

  /// Decodes image bytes, upright, no larger than the avatar photo size.
  nonisolated static func decode(_ data: Data, maxPixels: Int = RegistryAvatar.photoSize) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// JPEG bytes for `image` at `quality` (0...1).
  nonisolated static func jpeg(_ image: CGImage, quality: Double) -> Data? {
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
  }
}
