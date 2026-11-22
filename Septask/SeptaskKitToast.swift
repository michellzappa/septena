#if os(macOS)
import AppKit
import SwiftUI

// The AppKit task list's toast (DesignSpec §6.5): the temporary "Moved to …",
// "Deferred to …", "… deleted" confirmation, with Undo where the SwiftUI
// lists offer it. It is NOT a second toast: it hosts the shared
// `SeptenaToastCapsule` (Septena/Shell/UI/Accessibility.swift), so the glass
// capsule, the copy (`RegistryToasts`), the 7 s timer, Reduce Motion and
// "a new toast replaces the current one" are the SwiftUI shell's, by
// construction. The sync indicator in the title bar is hosted the same way.

/// Hosts the shared capsule, sized to it (`intrinsicContentSize`), so the view
/// covers only the capsule and never the rows around it. With no toast
/// showing it takes no clicks at all.
final class KitToastHost: NSHostingView<SeptenaToastCapsule> {
  private let store: SeptenaToastStore

  init(store: SeptenaToastStore) {
    self.store = store
    super.init(rootView: SeptenaToastCapsule(store: store))
    sizingOptions = [.intrinsicContentSize]
    translatesAutoresizingMaskIntoConstraints = false
  }

  @MainActor @preconcurrency required init(rootView: SeptenaToastCapsule) {
    fatalError("init(rootView:) is not used; use init(store:)")
  }

  @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    store.current == nil ? nil : super.hitTest(point)
  }
}
#endif
