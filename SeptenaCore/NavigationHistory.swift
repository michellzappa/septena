import Foundation

/// Back / Forward through the lists one window visited (⌘[ / ⌘], #849).
///
/// One value per window. It holds destination keys, not views: the shell
/// says what a key is (a `Route`, a sidebar key) and whether it still exists.
/// The same rules run on Android (`app.septena.core.NavigationHistory`); both
/// run `registry/shell-conformance/navigation-history.json`.
///
/// - A visit to a new destination pushes the one on screen onto the back
///   stack and clears the forward stack. A visit to the destination on screen
///   does nothing.
/// - Back and Forward move between the stacks. They never push.
/// - A destination that no longer exists (a deleted area or project) is
///   dropped when Back or Forward reaches it, and the step goes on past it.
/// - The back stack keeps at most `limit` entries (`registry/rules.json`
///   `navigationHistoryLimit`); the oldest goes first.
struct NavigationHistory<Entry: Equatable> {
  private(set) var back: [Entry] = []
  private(set) var forward: [Entry] = []
  private(set) var current: Entry?
  let limit: Int

  init(limit: Int = RegistryRules.navigationHistoryLimit) {
    self.limit = max(1, limit)
  }

  var canGoBack: Bool { !back.isEmpty }
  var canGoForward: Bool { !forward.isEmpty }

  /// The shell showed `entry`. Call it for every destination change,
  /// including the one Back or Forward caused: it is a no-op then.
  mutating func visit(_ entry: Entry) {
    guard entry != current else { return }
    if let current {
      back.append(current)
      if back.count > limit { back.removeFirst(back.count - limit) }
    }
    forward.removeAll()
    current = entry
  }

  /// The previous destination that still exists, or nil. Entries that no
  /// longer exist are dropped on the way.
  mutating func goBack(exists: (Entry) -> Bool = { _ in true }) -> Entry? {
    var source = back, target = forward
    defer { back = source; forward = target }
    return step(from: &source, to: &target, exists: exists)
  }

  /// The next destination that still exists, or nil.
  mutating func goForward(exists: (Entry) -> Bool = { _ in true }) -> Entry? {
    var source = forward, target = back
    defer { forward = source; back = target }
    return step(from: &source, to: &target, exists: exists)
  }

  private mutating func step(from source: inout [Entry], to target: inout [Entry],
                             exists: (Entry) -> Bool) -> Entry? {
    while let candidate = source.popLast() {
      guard exists(candidate), candidate != current else { continue }
      if let current {
        target.append(current)
        if target.count > limit { target.removeFirst(target.count - limit) }
      }
      current = candidate
      return candidate
    }
    return nil
  }
}
