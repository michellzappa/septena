import Foundation

// Disk cache for the bag of "ambient" server responses that don't get
// SwiftData persistence — history endpoints, today-snapshots, summaries.
// Backed by UserDefaults blobs (JSON-encoded). Each view paints from the
// last known response on cold launch, then refreshes from the network in
// the background and overwrites the blob.
//
// Not for tasks / projects / areas — those have their own SwiftData
// mirror with delta sync. ResponseCache is the simple alternative for
// the long tail of dashboards that don't merit a full entity model.
enum ResponseCache {
  /// Namespace UserDefaults keys so cache entries don't collide with
  /// settings or anything else stored under the same suite.
  private static let prefix = "septena.cache."

  static func save<T: Encodable>(_ value: T, forKey key: String) {
    do {
      let data = try JSONEncoder().encode(value)
      UserDefaults.standard.set(data, forKey: prefix + key)
    } catch {
      SeptenaLog.error("ResponseCache.save \(key)", error)
    }
  }

  static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
    guard let data = UserDefaults.standard.data(forKey: prefix + key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  /// Drop a specific cached blob. No-op if it doesn't exist. Useful when
  /// the upstream data model changes shape and stale blobs would crash
  /// the decoder.
  static func clear(forKey key: String) {
    UserDefaults.standard.removeObject(forKey: prefix + key)
  }
}
