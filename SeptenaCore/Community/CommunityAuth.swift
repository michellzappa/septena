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

  // The Apple session token is a stable bearer credential, so it rides iCloud
  // Keychain to the user's other devices (see `KeychainStore`); the current
  // session begins syncing the next time it's minted.
  private static func store(_ token: String, account: String) {
    KeychainStore.store(token, account: account, synchronizable: true)
  }

  private static func load(account: String) -> String? {
    KeychainStore.load(account: account)
  }

  private static func delete(account: String) {
    KeychainStore.delete(account: account)
  }
}

public extension Notification.Name {
  /// Posted when the Sign in with Apple session is created or cleared, so
  /// settings panes can re-evaluate `CommunityClient.access()`.
  static let septenaCommunityAuthChanged = Notification.Name("septena.community.auth.changed")
}
