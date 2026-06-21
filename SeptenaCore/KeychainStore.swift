import Foundation
import Security

/// One small home for the generic-password Keychain dance that every provider
/// (Oura / GitHub / Readwise / Community) used to copy-paste verbatim.
///
/// The one knob that matters here is `synchronizable`. Static personal-access
/// tokens (Oura, GitHub, Readwise) are marked **synchronizable** so they ride
/// iCloud Keychain to the user's other devices — end-to-end encrypted, Apple
/// can't read them, and nothing touches a Septena server. OAuth credentials
/// that rotate (Withings) stay device-local to avoid a single-use-refresh-token
/// race between two synced devices, so they pass `synchronizable: false`.
///
/// `kSecAttrSynchronizable` can't be flipped on an existing item via
/// `SecItemUpdate`, so `store` deletes any existing variant first and re-adds
/// with the desired flag — that keeps the attribute authoritative. Reads and
/// deletes use `kSecAttrSynchronizableAny` so they match whichever variant
/// happens to exist (important during the migration from the old local-only
/// items — see `makeSynchronizable`).
public enum KeychainStore {

  /// Store (or replace) `value` under `account`. When `synchronizable` is true
  /// the item propagates via iCloud Keychain.
  public static func store(_ value: String, account: String, synchronizable: Bool) {
    delete(account: account)  // clear any existing variant so the flag is authoritative
    let query: [String: Any] = [
      kSecClass as String:              kSecClassGenericPassword,
      kSecAttrAccount as String:        account,
      kSecValueData as String:          Data(value.utf8),
      kSecAttrAccessible as String:     kSecAttrAccessibleAfterFirstUnlock,
      kSecAttrSynchronizable as String: synchronizable,
    ]
    SecItemAdd(query as CFDictionary, nil)
  }

  /// Load the value for `account`, matching either a synced or a local item.
  public static func load(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String:              kSecClassGenericPassword,
      kSecAttrAccount as String:        account,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
      kSecReturnData as String:         true,
      kSecMatchLimit as String:         kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Delete the value for `account`, matching either a synced or a local item.
  public static func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String:              kSecClassGenericPassword,
      kSecAttrAccount as String:        account,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
    ]
    SecItemDelete(query as CFDictionary)
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
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let value = String(data: data, encoding: .utf8) else { return }
    store(value, account: account, synchronizable: true)
  }
}
