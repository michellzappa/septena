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
  public var updatedAt: String?

  public init(username: String? = nil,
              displayName: String? = nil,
              avatarKey: String? = nil,
              bio: String? = nil,
              isPublic: Bool = false,
              updatedAt: String? = nil) {
    self.username = username
    self.displayName = displayName
    self.avatarKey = avatarKey
    self.bio = bio
    self.isPublic = isPublic
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
  public let createdAt: String
  public let updatedAt: String
}

public struct CommunityFeatureComment: Decodable, Sendable, Identifiable, Equatable {
  public let id: String
  public let authorRole: String
  public let body: String
  public let isPinned: Bool
  public let createdAt: String
}

public struct CommunityFeatureDetail: Decodable, Sendable, Equatable {
  public let feature: CommunityFeature
  public let comments: [CommunityFeatureComment]
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

  public init(container: CKContainer = .default(), session: URLSession = .shared) {
    self.container = container
    self.session = session
  }

  public nonisolated var appAttestSupported: Bool {
    AppAttestClient.shared.isSupported
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
                             baseURL: URL = CommunityEndpoint.baseURL) async throws -> CommunityFeatureDetail {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/features/\(id)/comments"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let data = try JSONEncoder().encode(PostSupportMessageBody(body: body, isInternal: false))
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

  private func attachCommunityAuth(_ req: inout URLRequest, body: Data, baseURL: URL) async throws {
    guard let userRecordName = try await cloudKitUserRecordName() else {
      throw ClientError.cloudKitUserUnavailable
    }
    req.setValue(userRecordName, forHTTPHeaderField: "X-Septena-CloudKit-User")

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
}
