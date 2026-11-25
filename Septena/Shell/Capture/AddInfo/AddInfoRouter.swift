import SwiftUI

// The quick-add sheet's draft text, one per presentation.

@MainActor
@Observable
final class AddInfoRouter {
  var query: String = ""
}
