import Foundation
import Security

/// One small home for the generic-password Keychain dance that every credential
/// reader shares.
///
/// The one knob that matters here is `synchronizable`. Static
/// tokens are marked **synchronizable** so they ride
/// iCloud Keychain to the user's other devices — end-to-end encrypted, Apple
/// can't read them, and nothing touches a Septena server. Credentials
/// that rotate stay device-local to avoid a single-use-refresh-token
/// race between two synced devices, so they pass `synchronizable: false`.
///
/// `kSecAttrSynchronizable` can't be flipped on an existing item via
/// `SecItemUpdate`, so `store` writes the variant with the desired flag, then
/// deletes the other one — that keeps the attribute authoritative. Reads and
/// deletes use `kSecAttrSynchronizableAny` so they match whichever variant
/// happens to exist (important during the migration from the old local-only
/// items — see `makeSynchronizable`).
///
/// Every query names the data protection keychain. On macOS the default is
/// the legacy login keychain, whose items trust only the app *path* that made
/// them: after the rename from Septask.app the task backend's refresh token
/// asked for a password on every read, could not be replaced, and every new
/// sign-in was lost at the next refresh. The data protection keychain scopes
/// items by team and bundle id, so a rebuild or rename keeps them. iOS ignores the key.
public enum KeychainStore {

  /// Unsigned local builds have no application-identifier entitlement and
  /// cannot reach the data protection keychain; they fall back to the legacy
  /// one so they still run.
  nonisolated(unsafe) private static var useDataProtection = true

  private static func scoped(_ query: [String: Any]) -> CFDictionary {
    var q = query
    if useDataProtection { q[kSecUseDataProtectionKeychain as String] = true }
    return q as CFDictionary
  }

  /// Store (or replace) `value` under `account`. When `synchronizable` is true
  /// the item propagates via iCloud Keychain; a local item never leaves this
  /// device, not even in a backup. Replaces in place: when this fails, or the
  /// process dies here, the old value is still there. Returns false on failure.
  @discardableResult
  public static func store(_ value: String, account: String, synchronizable: Bool) -> Bool {
    let query: [String: Any] = [
      kSecClass as String:              kSecClassGenericPassword,
      kSecAttrAccount as String:        account,
      kSecAttrSynchronizable as String: synchronizable,
    ]
    let values: [String: Any] = [
      kSecValueData as String:      Data(value.utf8),
      kSecAttrAccessible as String: synchronizable
        ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    func write() -> OSStatus {
      let status = SecItemUpdate(scoped(query), values as CFDictionary)
      guard status == errSecItemNotFound else { return status }
      return SecItemAdd(scoped(query.merging(values) { $1 }), nil)
    }
    var status = write()
    if status == errSecMissingEntitlement {
      useDataProtection = false
      status = write()
    }
    guard status == errSecSuccess else { return false }
    // Clear the other variant so the flag is authoritative.
    var other = query
    other[kSecAttrSynchronizable as String] = !synchronizable
    SecItemDelete(scoped(other))
    return true
  }

  /// What a read found. `unavailable` is not `missing`: the keychain is locked
  /// (before the first unlock after a restart) or busy, and the item may exist.
  public enum ReadResult: Equatable {
    case found(String)
    case missing
    case unavailable(OSStatus)
  }

  /// Load the value for `account`, matching either a synced or a local item.
  public static func load(account: String) -> String? {
    guard case .found(let value) = read(account: account) else { return nil }
    return value
  }

  public static func read(account: String) -> ReadResult {
    let query: [String: Any] = [
      kSecClass as String:              kSecClassGenericPassword,
      kSecAttrAccount as String:        account,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
      kSecReturnData as String:         true,
      kSecMatchLimit as String:         kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    var status = SecItemCopyMatching(scoped(query), &item)
    if status == errSecMissingEntitlement {
      useDataProtection = false
      status = SecItemCopyMatching(scoped(query), &item)
    }
    if [errSecInteractionNotAllowed, errSecNotAvailable, errSecServiceNotAvailable].contains(status) {
      return .unavailable(status)
    }
    guard status == errSecSuccess, let data = item as? Data,
          let value = String(data: data, encoding: .utf8) else { return .missing }
    return .found(value)
  }

  /// Delete the value for `account`, matching either a synced or a local item.
  public static func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String:              kSecClassGenericPassword,
      kSecAttrAccount as String:        account,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
    ]
    if SecItemDelete(scoped(query)) == errSecMissingEntitlement {
      useDataProtection = false
      SecItemDelete(scoped(query))
    }
  }

  /// One-time, idempotent migration: if a *local-only* (non-synchronizable)
  /// item exists for `account` — i.e. a token entered before this device
  /// learned to sync — rewrite it as synchronizable so it starts propagating
  /// without the user re-pasting it. After the first call the local-only item
  /// is gone, so subsequent calls find nothing and no-op.
  public static func makeSynchronizable(account: String) {
    let query: [String: Any] = [
      kSecClass as String:              kSecClassGenericPassword,
      kSecAttrAccount as String:        account,
      kSecAttrSynchronizable as String: false,
      kSecReturnData as String:         true,
      kSecMatchLimit as String:         kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(scoped(query), &item) == errSecSuccess,
          let data = item as? Data,
          let value = String(data: data, encoding: .utf8) else { return }
    store(value, account: account, synchronizable: true)
  }
}
