import Foundation
import Security

// MARK: - CommunityAccess

/// Whether the device can actually transact with the community Worker. The
/// Worker runs `ATTEST_MODE=enforce`, so a request needs a genuineness proof:
/// an App Attest assertion (iOS) or a Sign in with Apple session (native macOS,
/// where App Attest doesn't exist). iCloud is required for identity either way.
public enum CommunityAccess: Sendable, Equatable {
  /// No iCloud account — community surfaces can't author anything.
  case unavailable
  /// iCloud is present but this device has no App Attest and no Apple session
  /// yet. Prompt Sign in with Apple to unlock the features.
  case needsAppleSignIn
  /// Ready to read and write.
  case ready
}

// MARK: - CommunitySession

/// Keychain-backed store for the Sign in with Apple session token the Worker
/// mints (see `apple.ts`). Keyed by Worker host so a dev/prod base URL don't
/// share a token. The token is the App-Attest substitute on macOS: present it
/// in `X-Septena-Session` and the Worker accepts the write.
///
/// Same Keychain pattern as `GitHubProvider` / `OuraProvider`.
public enum CommunitySession {
  private static func account(forHost host: String) -> String {
    "septena.community.session.\(host)"
  }

  public static func token(forHost host: String) -> String? {
    load(account: account(forHost: host))
  }

  public static func exists(forHost host: String) -> Bool {
    token(forHost: host) != nil
  }

  public static func store(_ token: String, forHost host: String) {
    store(token, account: account(forHost: host))
  }

  public static func delete(forHost host: String) {
    delete(account: account(forHost: host))
  }

  private static func store(_ token: String, account: String) {
    let data = Data(token.utf8)
    let baseQuery: [String: Any] = [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrAccount as String: account,
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var addQuery = baseQuery
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      SecItemAdd(addQuery as CFDictionary, nil)
    }
  }

  private static func load(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrAccount as String: account,
      kSecReturnData as String:  true,
      kSecMatchLimit as String:  kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

public extension Notification.Name {
  /// Posted when the Sign in with Apple session is created or cleared, so
  /// settings panes can re-evaluate `CommunityClient.access()`.
  static let septenaCommunityAuthChanged = Notification.Name("septena.community.auth.changed")
}
