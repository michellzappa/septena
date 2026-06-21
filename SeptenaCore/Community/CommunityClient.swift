import CloudKit
import Foundation

// MARK: - CommunityEndpoint

/// Worker endpoint for Septena support, feature requests, comments, and public
/// profile identity. Defaults to the planned production hostname; override with
/// UserDefaults while running `wrangler dev`.
public enum CommunityEndpoint {
  public static let defaultBaseURL = URL(string: "https://community.septena.app")!

  public static var baseURL: URL {
    if let s = UserDefaults.standard.string(forKey: "septena.community.baseURL"),
       let u = URL(string: s) {
      return u
    }
    return defaultBaseURL
  }
}

// MARK: - Models

public struct CommunityMe: Decodable, Sendable {
  public struct User: Decodable, Sendable {
    public let role: String
    public let isBanned: Bool
    public let userHash: String?
  }

  public let user: User
  public let profile: CommunityProfile
}

public struct CommunityProfile: Codable, Sendable, Equatable {
  public var username: String?
  public var displayName: String?
  public var avatarKey: String?
  public var bio: String?
  public var isPublic: Bool
  /// The member's Septena+ patronage tier ("annual"/"monthly"/"lifetime"), or
  /// nil for the free tier. Server-owned and read-only here — set via
  /// `CommunityClient.updateSupporterTier(_:)`, not the profile editor.
  public var supporterTier: String?
  /// ISO-8601 timestamp of when a support tier was first set; nil when free.
  public var supporterSince: String?
  public var updatedAt: String?

  public init(username: String? = nil,
              displayName: String? = nil,
              avatarKey: String? = nil,
              bio: String? = nil,
              isPublic: Bool = false,
              supporterTier: String? = nil,
              supporterSince: String? = nil,
              updatedAt: String? = nil) {
    self.username = username
    self.displayName = displayName
    self.avatarKey = avatarKey
    self.bio = bio
    self.isPublic = isPublic
    self.supporterTier = supporterTier
    self.supporterSince = supporterSince
    self.updatedAt = updatedAt
  }
}

public struct CommunitySupportTicket: Decodable, Sendable, Identifiable, Equatable {
  public let id: String
  public let createdAt: String
  public let updatedAt: String
  public let lastMessageAt: String
  public let status: String
  public let category: String
  public let subject: String
  public let metadata: CommunitySupportMetadata
}

public struct CommunitySupportMessage: Decodable, Sendable, Identifiable, Equatable {
  public let id: String
  public let ticketID: String
  public let authorRole: String
  public let body: String
  public let isInternal: Bool
  public let createdAt: String
}

public struct CommunitySupportThread: Decodable, Sendable, Equatable {
  public let ticket: CommunitySupportTicket
  public let messages: [CommunitySupportMessage]
}

public struct CommunitySupportMetadata: Codable, Sendable, Equatable {
  public var appVersion: String?
  public var build: String?
  public var platform: String?
  public var osVersion: String?
  public var deviceModel: String?
  public var appLocale: String?

  public init(appVersion: String? = nil,
              build: String? = nil,
              platform: String? = nil,
              osVersion: String? = nil,
              deviceModel: String? = nil,
              appLocale: String? = nil) {
    self.appVersion = appVersion
    self.build = build
    self.platform = platform
    self.osVersion = osVersion
    self.deviceModel = deviceModel
    self.appLocale = appLocale
  }

  public static var current: CommunitySupportMetadata {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String
    let build = info["CFBundleVersion"] as? String
    let locale = Locale.autoupdatingCurrent.identifier
    #if os(macOS)
    let platform = "macOS"
    #else
    let platform = "iOS"
    #endif
    return CommunitySupportMetadata(
      appVersion: version,
      build: build,
      platform: platform,
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      deviceModel: nil,
      appLocale: locale
    )
  }
}

// MARK: - Feature requests (roadmap)

/// Author identity, present only for contributors who made their profile public.
public struct CommunityAuthor: Decodable, Sendable, Equatable {
  public let username: String?
  public let displayName: String?
  /// The author's community role ("user"/"maintainer"/"moderator"), for the
  /// member badge. Absent on older worker responses → decodes to nil.
  public let role: String?
  /// The author's Septena+ tier ("annual"/"monthly"/"lifetime"), or nil/none.
  public let supporterTier: String?

  /// Best display string: name, else @handle.
  public var label: String? {
    if let n = displayName, !n.isEmpty { return n }
    if let u = username, !u.isEmpty { return "@\(u)" }
    return nil
  }
}

public struct CommunityFeature: Decodable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let detail: String?
  public let status: String
  public let maintainerNote: String?
  public let isLocked: Bool
  public let voteCount: Int
  public let commentCount: Int
  public let hasVoted: Bool
  public let author: CommunityAuthor?
  public let createdAt: String
  public let updatedAt: String
}

public struct CommunityFeatureComment: Decodable, Sendable, Identifiable, Equatable {
  public let id: String
  public let parentId: String?
  public let authorRole: String
  public let author: CommunityAuthor?
  public let body: String
  public let isPinned: Bool
  public let status: String?
  public let createdAt: String
}

public struct CommunityFeatureDetail: Decodable, Sendable, Equatable {
  public let feature: CommunityFeature
  public let comments: [CommunityFeatureComment]
}

// MARK: - Testimonials

public struct CommunityTestimonial: Decodable, Sendable, Identifiable, Equatable {
  public let id: String
  public let body: String
  public let rating: Int?
  public let status: String
  public let isFeatured: Bool
  public let author: CommunityAuthor?
  public let createdAt: String
  public let updatedAt: String
}

// MARK: - CommunityClient

public actor CommunityClient {
  public enum ClientError: Error {
    case cloudKitUserUnavailable
    case badResponse(Int)
    case encoding
  }

  public static let shared = CommunityClient()

  private let container: CKContainer
  private let session: URLSession

  // Must be the app's real container, NOT `CKContainer.default()`: `.default()`
  // resolves to `iCloud.<main-bundle-id>`, which on the Mac app
  // (`com.septena.cloud.mac`) is a container the app isn't entitled to — so
  // accountStatus never reports `.available` and community surfaces wrongly show
  // "sign in to iCloud" for a signed-in user. The rest of the app keys on this
  // explicit identifier (see CKEngine). Resolved in-body because a public init's
  // default-argument value can't reference the internal `SeptenaCloudKit`.
  public init(container: CKContainer? = nil, session: URLSession = .shared) {
    self.container = container ?? CKContainer(identifier: SeptenaCloudKit.containerIdentifier)
    self.session = session
  }

  public nonisolated var appAttestSupported: Bool {
    AppAttestClient.shared.isSupported
  }

  /// Whether the iCloud account that authors community writes is reachable.
  /// App Attest is NOT required — it rides along best-effort when the device
  /// supports it (see `attachCommunityAuth`), so community surfaces gate on
  /// this (iCloud) rather than on attestation. That's what lets an
  /// enclave-less Mac use feedback / the roadmap / support.
  public func accountAvailable() async -> Bool {
    (try? await cloudKitUserRecordName()) != nil
  }

  /// Whether a Sign in with Apple session token is stored for this Worker host.
  public nonisolated func hasAppleSession(for baseURL: URL = CommunityEndpoint.baseURL) -> Bool {
    CommunitySession.exists(forHost: baseURL.host ?? "")
  }

  /// What the device can do with the community Worker. The Worker enforces
  /// attestation, so writing needs either App Attest (iOS) or a Sign in with
  /// Apple session (native macOS) on top of iCloud — see `CommunityAccess`.
  public func access(for baseURL: URL = CommunityEndpoint.baseURL) async -> CommunityAccess {
    guard await accountAvailable() else { return .unavailable }
    if appAttestSupported || hasAppleSession(for: baseURL) { return .ready }
    return .needsAppleSignIn
  }

  /// Exchange an Apple identity token for a Worker session (the App-Attest
  /// substitute on macOS). Stores the session in the Keychain on success and
  /// posts `.septenaCommunityAuthChanged`. Purely additive — it changes no app
  /// data; it only unlocks community writes on this device.
  public func signInWithApple(identityToken: String,
                              baseURL: URL = CommunityEndpoint.baseURL) async throws {
    guard let userRecordName = try await cloudKitUserRecordName() else {
      throw ClientError.cloudKitUserUnavailable
    }
    var req = URLRequest(url: baseURL.appendingPathComponent("api/auth/apple"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(userRecordName, forHTTPHeaderField: "X-Septena-CloudKit-User")
    let body = try JSONEncoder().encode(AppleSignInBody(identityToken: identityToken))
    req.httpBody = body
    let resp = try await send(req, as: AppleSessionResponse.self)
    CommunitySession.store(resp.sessionToken, forHost: baseURL.host ?? "")
    NotificationCenter.default.post(name: .septenaCommunityAuthChanged, object: nil)
  }

  /// Clear the Apple session on this device. Signing out removes nothing but the
  /// session token — community contributions and all app data stay put.
  public nonisolated func signOutApple(baseURL: URL = CommunityEndpoint.baseURL) {
    CommunitySession.delete(forHost: baseURL.host ?? "")
    NotificationCenter.default.post(name: .septenaCommunityAuthChanged, object: nil)
  }

  public func me(baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunityMe {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/me"))
    req.httpMethod = "GET"
    try await attachCommunityAuth(&req, body: Data(), baseURL: baseURL)
    return try await send(req, as: CommunityMe.self)
  }

  public func updateProfile(_ profile: CommunityProfile,
                            baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunityMe {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/me/profile"))
    req.httpMethod = "PATCH"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body = try JSONEncoder().encode(ProfileUpdate(profile))
    req.httpBody = body
    try await attachCommunityAuth(&req, body: body, baseURL: baseURL)
    return try await send(req, as: CommunityMe.self)
  }

  /// Report the caller's current Septena+ patronage tier so their community
  /// profile can show a "Supporter" badge. Pass nil to clear it (free tier).
  /// Client-asserted: the worker trusts the attested/session channel — the
  /// badge gates nothing. See `SupportStore.syncSupporterToCommunity`.
  @discardableResult
  public func updateSupporterTier(_ tier: String?,
                                  baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunityMe {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/me/support"))
    req.httpMethod = "PUT"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body = try JSONEncoder().encode(SupporterUpdate(tier: tier))
    req.httpBody = body
    try await attachCommunityAuth(&req, body: body, baseURL: baseURL)
    return try await send(req, as: CommunityMe.self)
  }

  public func supportTickets(baseURL: URL = CommunityEndpoint.baseURL) async throws -> [CommunitySupportTicket] {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/support/tickets"))
    req.httpMethod = "GET"
    try await attachCommunityAuth(&req, body: Data(), baseURL: baseURL)
    return try await send(req, as: SupportTicketList.self).tickets
  }

  public func createSupportTicket(category: String,
                                  subject: String,
                                  body: String,
                                  metadata: CommunitySupportMetadata = .current,
                                  baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunitySupportThread {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/support/tickets"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let payload = CreateSupportTicketBody(category: category, subject: subject, body: body, metadata: metadata)
    let data = try JSONEncoder().encode(payload)
    req.httpBody = data
    try await attachCommunityAuth(&req, body: data, baseURL: baseURL)
    return try await send(req, as: CommunitySupportThread.self)
  }

  public func supportTicket(id: String,
                            baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunitySupportThread {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/support/tickets/\(id)"))
    req.httpMethod = "GET"
    try await attachCommunityAuth(&req, body: Data(), baseURL: baseURL)
    return try await send(req, as: CommunitySupportThread.self)
  }

  public func postSupportMessage(ticketID: String,
                                 body: String,
                                 isInternal: Bool = false,
                                 baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunitySupportThread {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/support/tickets/\(ticketID)/messages"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let payload = PostSupportMessageBody(body: body, isInternal: isInternal)
    let data = try JSONEncoder().encode(payload)
    req.httpBody = data
    try await attachCommunityAuth(&req, body: data, baseURL: baseURL)
    return try await send(req, as: CommunitySupportThread.self)
  }

  /// Maintainer-only: change a ticket's status (e.g. close / reopen). The
  /// worker rejects this with 403 for non-maintainer callers.
  public func setSupportTicketStatus(id: String,
                                     status: String,
                                     baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunitySupportThread {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/support/tickets/\(id)"))
    req.httpMethod = "PATCH"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let data = try JSONEncoder().encode(SetTicketStatusBody(status: status))
    req.httpBody = data
    try await attachCommunityAuth(&req, body: data, baseURL: baseURL)
    return try await send(req, as: CommunitySupportThread.self)
  }

  // MARK: Feature requests

  public func features(baseURL: URL = CommunityEndpoint.baseURL) async throws -> [CommunityFeature] {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/features"))
    req.httpMethod = "GET"
    try await attachCommunityAuth(&req, body: Data(), baseURL: baseURL)
    return try await send(req, as: FeatureList.self).features
  }

  public func feature(id: String,
                      baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunityFeatureDetail {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/features/\(id)"))
    req.httpMethod = "GET"
    try await attachCommunityAuth(&req, body: Data(), baseURL: baseURL)
    return try await send(req, as: CommunityFeatureDetail.self)
  }

  public func createFeature(title: String,
                            detail: String?,
                            baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunityFeatureDetail {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/features"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let data = try JSONEncoder().encode(CreateFeatureBody(title: title, detail: detail))
    req.httpBody = data
    try await attachCommunityAuth(&req, body: data, baseURL: baseURL)
    return try await send(req, as: CommunityFeatureDetail.self)
  }

  public func voteFeature(id: String,
                          voted: Bool,
                          baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunityFeatureDetail {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/features/\(id)/vote"))
    req.httpMethod = voted ? "POST" : "DELETE"
    try await attachCommunityAuth(&req, body: Data(), baseURL: baseURL)
    return try await send(req, as: CommunityFeatureDetail.self)
  }

  public func commentFeature(id: String,
                             body: String,
                             parentId: String? = nil,
                             baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunityFeatureDetail {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/features/\(id)/comments"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let data = try JSONEncoder().encode(FeatureCommentBody(body: body, parentId: parentId))
    req.httpBody = data
    try await attachCommunityAuth(&req, body: data, baseURL: baseURL)
    return try await send(req, as: CommunityFeatureDetail.self)
  }

  /// Maintainer-only: hide / unhide / delete / pin a comment.
  public func moderateComment(featureID: String,
                              commentID: String,
                              status: String? = nil,
                              isPinned: Bool? = nil,
                              baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunityFeatureDetail {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/features/\(featureID)/comments/\(commentID)"))
    req.httpMethod = "PATCH"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let data = try JSONEncoder().encode(ModerateCommentBody(status: status, isPinned: isPinned))
    req.httpBody = data
    try await attachCommunityAuth(&req, body: data, baseURL: baseURL)
    return try await send(req, as: CommunityFeatureDetail.self)
  }

  /// Maintainer-only: change status, set a maintainer note, or lock the thread.
  public func updateFeature(id: String,
                            status: String? = nil,
                            maintainerNote: String? = nil,
                            isLocked: Bool? = nil,
                            baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunityFeatureDetail {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/features/\(id)"))
    req.httpMethod = "PATCH"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let data = try JSONEncoder().encode(UpdateFeatureBody(status: status, maintainerNote: maintainerNote, isLocked: isLocked))
    req.httpBody = data
    try await attachCommunityAuth(&req, body: data, baseURL: baseURL)
    return try await send(req, as: CommunityFeatureDetail.self)
  }

  // MARK: Testimonials

  public func myTestimonial(baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunityTestimonial? {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/me/testimonial"))
    req.httpMethod = "GET"
    try await attachCommunityAuth(&req, body: Data(), baseURL: baseURL)
    return try await send(req, as: TestimonialEnvelope.self).testimonial
  }

  public func putTestimonial(body: String,
                             rating: Int?,
                             baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunityTestimonial? {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/me/testimonial"))
    req.httpMethod = "PUT"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let data = try JSONEncoder().encode(PutTestimonialBody(body: body, rating: rating))
    req.httpBody = data
    try await attachCommunityAuth(&req, body: data, baseURL: baseURL)
    return try await send(req, as: TestimonialEnvelope.self).testimonial
  }

  public func deleteTestimonial(baseURL: URL = CommunityEndpoint.baseURL) async throws {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/me/testimonial"))
    req.httpMethod = "DELETE"
    try await attachCommunityAuth(&req, body: Data(), baseURL: baseURL)
    _ = try await send(req, as: TestimonialEnvelope.self)
  }

  public func testimonials(baseURL: URL = CommunityEndpoint.baseURL) async throws -> [CommunityTestimonial] {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/testimonials"))
    req.httpMethod = "GET"
    try await attachCommunityAuth(&req, body: Data(), baseURL: baseURL)
    return try await send(req, as: TestimonialList.self).testimonials
  }

  /// Maintainer-only: approve / hide / feature a testimonial.
  public func moderateTestimonial(id: String,
                                  status: String? = nil,
                                  isFeatured: Bool? = nil,
                                  baseURL: URL = CommunityEndpoint.baseURL) async throws -> [CommunityTestimonial] {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/testimonials/\(id)"))
    req.httpMethod = "PATCH"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let data = try JSONEncoder().encode(ModerateTestimonialBody(status: status, isFeatured: isFeatured))
    req.httpBody = data
    try await attachCommunityAuth(&req, body: data, baseURL: baseURL)
    return try await send(req, as: TestimonialList.self).testimonials
  }

  private func attachCommunityAuth(_ req: inout URLRequest, body: Data, baseURL: URL) async throws {
    guard let userRecordName = try await cloudKitUserRecordName() else {
      throw ClientError.cloudKitUserUnavailable
    }
    req.setValue(userRecordName, forHTTPHeaderField: "X-Septena-CloudKit-User")

    // Sign in with Apple session — the genuineness proof on devices without App
    // Attest (native macOS). Sent whenever present; the Worker uses whichever of
    // session / attestation verifies.
    if let session = CommunitySession.token(forHost: baseURL.host ?? "") {
      req.setValue(session, forHTTPHeaderField: "X-Septena-Session")
    }

    if let attestation = await AppAttestClient.shared.assertion(forBody: body, baseURL: baseURL, session: session) {
      req.setValue(attestation.keyId, forHTTPHeaderField: "X-Attest-Key-Id")
      req.setValue(attestation.assertionB64, forHTTPHeaderField: "X-Attest-Assertion")
      req.setValue(attestation.challenge, forHTTPHeaderField: "X-Attest-Challenge")
    }
  }

  private func cloudKitUserRecordName() async throws -> String? {
    let status = try await container.accountStatus()
    guard status == .available else { return nil }
    return try await container.userRecordID().recordName
  }

  private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
    let (data, response) = try await session.data(for: req)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else { throw ClientError.badResponse(code) }
    return try JSONDecoder().decode(T.self, from: data)
  }

  private struct AppleSignInBody: Encodable {
    let identityToken: String
  }

  private struct AppleSessionResponse: Decodable {
    let sessionToken: String
    let expiresAt: Double?
  }

  private struct ProfileUpdate: Encodable {
    let username: String?
    let displayName: String?
    let bio: String?
    let isPublic: Bool

    init(_ profile: CommunityProfile) {
      self.username = profile.username
      self.displayName = profile.displayName
      self.bio = profile.bio
      self.isPublic = profile.isPublic
    }
  }

  // nil `tier` is omitted by JSONEncoder, which the worker reads as "clear the
  // tier" (free) — the same as sending an explicit null.
  private struct SupporterUpdate: Encodable {
    let tier: String?
  }

  private struct SupportTicketList: Decodable {
    let tickets: [CommunitySupportTicket]
  }

  private struct CreateSupportTicketBody: Encodable {
    let category: String
    let subject: String
    let body: String
    let metadata: CommunitySupportMetadata
  }

  private struct PostSupportMessageBody: Encodable {
    let body: String
    let isInternal: Bool
  }

  private struct SetTicketStatusBody: Encodable {
    let status: String
  }

  private struct FeatureList: Decodable {
    let features: [CommunityFeature]
  }

  private struct CreateFeatureBody: Encodable {
    let title: String
    let detail: String?
  }

  private struct UpdateFeatureBody: Encodable {
    let status: String?
    let maintainerNote: String?
    let isLocked: Bool?
  }

  private struct FeatureCommentBody: Encodable {
    let body: String
    let parentId: String?
  }

  private struct ModerateCommentBody: Encodable {
    let status: String?
    let isPinned: Bool?
  }

  private struct TestimonialEnvelope: Decodable {
    let testimonial: CommunityTestimonial?
  }

  private struct TestimonialList: Decodable {
    let testimonials: [CommunityTestimonial]
  }

  private struct PutTestimonialBody: Encodable {
    let body: String
    let rating: Int?
  }

  private struct ModerateTestimonialBody: Encodable {
    let status: String?
    let isFeatured: Bool?
  }
}
