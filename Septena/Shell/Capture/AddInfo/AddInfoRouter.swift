import SwiftUI

// Lightweight palette state. Mirrors the webapp's single-level page stack:
// nil = root list, otherwise a section page. Query is shared across all
// pages so typing on root flows seamlessly into a pushed page.

@MainActor
@Observable
final class AddInfoRouter {
  var page: AddInfoSection? = nil
  var query: String = ""

  func push(_ section: AddInfoSection) {
    page = section
    query = ""
    Haptics.pick()
  }

  func pop() {
    page = nil
    query = ""
    Haptics.pick()
  }
}
