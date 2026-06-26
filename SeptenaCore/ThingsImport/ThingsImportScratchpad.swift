import Foundation

/// Copies a user-picked Things database into the app container so parsing is
/// reliable across sandbox security scopes, WAL sidecars, and re-parses when
/// options change.
enum ThingsImportScratchpad {

  static func prepareForParsing(source: URL) throws -> URL {
    let resolved = try ThingsImportParser.resolveDatabaseURL(source)
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("things-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let base = resolved.deletingPathExtension().lastPathComponent
    let dest = dir.appendingPathComponent("\(base).sqlite")
    try copyIfPresent(from: resolved, to: dest)

    let parent = resolved.deletingLastPathComponent()
    let stem = resolved.lastPathComponent
    for suffix in ["-wal", "-shm"] {
      let sidecar = parent.appendingPathComponent(stem + suffix)
      if FileManager.default.fileExists(atPath: sidecar.path) {
        try copyIfPresent(from: sidecar, to: dir.appendingPathComponent(dest.lastPathComponent + suffix))
      }
    }
    return dest
  }

  private static func copyIfPresent(from source: URL, to dest: URL) throws {
    guard FileManager.default.fileExists(atPath: source.path) else { return }
    if FileManager.default.fileExists(atPath: dest.path) {
      try FileManager.default.removeItem(at: dest)
    }
    try FileManager.default.copyItem(at: source, to: dest)
  }
}
