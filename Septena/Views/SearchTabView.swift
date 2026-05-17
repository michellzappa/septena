import SwiftUI

// Search tab — promotes QuickFind from a ⌘K sheet to a first-class
// destination. v1 wraps the existing QuickFindView inline; later it'll
// gain cross-module search (habits, chores, etc.) as those modules ship.

struct SearchTabView: View {
  var body: some View {
    NavigationStack {
      QuickFindView()
        .navigationTitle("Search")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }
  }
}
