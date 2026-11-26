// Contact Support (ADR 0054, docs/SUPPORT_SPEC.md §4). The app sends through
// api.septena.app, which forwards to the Septena workspace in Starlings and
// keeps the conversation, so replies show here. Wire: docs/IDENTIFIERS.md
// "Support wire".

import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Wire shapes of `/v1/support/*` (backend/src/support/routes.ts).
enum SupportWire {
  static let keyHeader = "X-Septena-Support-Key"
  /// Matches the backend's limit (`MESSAGE_MAX_CHARS`).
  static let messageMaxChars = 4_000

  struct Diagnostics: Encodable, Sendable, Equatable {
    var platform: String
    var osVersion: String?
    var deviceModel: String?
    var appVersion: String?
    var build: Int?
    var signedIn: Bool?
    var lastSyncAt: String?
    var lastSyncError: String?
    var storeFailures: Int?
  }

  struct Outgoing: Encodable, Sendable {
    let message_id: String
    let text: String
    let email: String?
    let diagnostics: Diagnostics?
  }

  struct Message: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let direction: String
    let text: String
    let authorName: String?
    let createdAt: Double
    let readAt: Double?

    var isReply: Bool { direction == "out" }
  }

  struct Sent: Decodable, Sendable { let message: Message }

  struct Conversation: Decodable, Sendable {
    let messages: [Message]
    let unread: Int
  }

  enum SendError: Error, Equatable {
    case emailRequired
    case rateLimited
  }
}

/// The app side of Contact Support: the conversation, the unread count and
/// sending. One instance; every surface (Settings row, Mac and iPad Help
/// menu, the sheet and the window) reads it.
@MainActor
@Observable
final class SupportCenter {
  static let shared = SupportCenter()

  enum SendState: Equatable {
    case idle
    case sending
    case sent
    case failed(String)
  }

  private(set) var messages: [SupportWire.Message] = []
  private(set) var unread = 0
  private(set) var sendState: SendState = .idle
  /// The iPad Help menu presents the screen as a sheet on the main window.
  var isPresentingSheet = false

  private static let keyAccount = "com.septena.support.key"

  /// True when sending needs an email: signed out.
  var needsEmail: Bool { !TaskBackendClient.hasSession }

  /// The support key: 32 random bytes, base64url, made once and kept in the
  /// Keychain on this device. The backend keeps only its hash.
  private func supportKey() -> String {
    if let key = KeychainStore.load(account: Self.keyAccount), key.count == 43 { return key }
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let key = Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    _ = KeychainStore.store(key, account: Self.keyAccount, synchronizable: false)
    return key
  }

  /// Reads the conversation and the unread count. A failure keeps what was
  /// shown: the screen still works and the next open tries again.
  func refresh() async {
    do {
      let conversation = try await TaskBackendClient.shared.supportConversation(supportKey: supportKey())
      messages = conversation.messages
      unread = conversation.unread
    } catch {
      // Unread stays as it was; nothing to tell the user on a background read.
    }
  }

  /// Marks the replies read once the screen shows them.
  func markRead() async {
    guard unread > 0 else { return }
    do {
      try await TaskBackendClient.shared.markSupportRead(supportKey: supportKey())
      unread = 0
    } catch {
      // The dot stays until a read lands.
    }
  }

  /// Sends one message. Returns true when the backend stored it; on failure
  /// the caller keeps the text in the field.
  @discardableResult
  func send(text: String, email: String?, includeDiagnostics: Bool) async -> Bool {
    let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SupportWire.messageMaxChars))
    guard !trimmed.isEmpty, sendState != .sending else { return false }
    let address = email?.trimmingCharacters(in: .whitespacesAndNewlines)
    if needsEmail, (address ?? "").isEmpty {
      sendState = .failed(RegistrySupport.emailRequired)
      return false
    }
    sendState = .sending
    let outgoing = SupportWire.Outgoing(
      message_id: UUID().uuidString.lowercased(),
      text: trimmed,
      email: needsEmail ? address : nil,
      diagnostics: includeDiagnostics ? Self.diagnostics() : nil
    )
    do {
      let stored = try await TaskBackendClient.shared.sendSupportMessage(outgoing, supportKey: supportKey())
      if !messages.contains(where: { $0.id == stored.id }) { messages.append(stored) }
      sendState = .sent
      return true
    } catch SupportWire.SendError.emailRequired {
      sendState = .failed(RegistrySupport.emailRequired)
    } catch SupportWire.SendError.rateLimited {
      sendState = .failed(RegistrySupport.tooManyMessages)
    } catch {
      sendState = .failed(RegistrySupport.sendFailed)
    }
    return false
  }

  func resetSendState() {
    if sendState != .sending { sendState = .idle }
  }

  /// What "Include diagnostics" adds (spec §4). Never task content.
  static func diagnostics() -> SupportWire.Diagnostics {
    let info = Bundle.main.infoDictionary
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let engine = TaskSyncEngine.shared
    let iso = ISO8601DateFormatter()
    return SupportWire.Diagnostics(
      platform: platform,
      osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
      deviceModel: deviceModel,
      appVersion: info?["CFBundleShortVersionString"] as? String,
      build: (info?["CFBundleVersion"] as? String).flatMap(Int.init),
      signedIn: TaskBackendClient.hasSession,
      lastSyncAt: engine.lastPull.map { iso.string(from: $0) },
      lastSyncError: engine.lastError.map { String($0.prefix(80)) },
      storeFailures: StoreHealthState.shared.saveFailures
    )
  }

  private static var platform: String {
    #if os(macOS)
    return "macos"
    #else
    return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
    #endif
  }

  /// The hardware model id (for example `iPhone17,1`, `Mac16,10`).
  private static var deviceModel: String? {
    #if os(macOS)
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    return String(cString: buffer)
    #else
    var system = utsname()
    uname(&system)
    let model = withUnsafeBytes(of: &system.machine) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return model.isEmpty ? nil : model
    #endif
  }
}
