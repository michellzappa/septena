#if os(macOS)
import AppKit

// The menu bar item of an open Do (docs/DO_SPEC.md §5): the Do symbol and the
// time, on every Mac, also the one that shows the Do screen. A stale Do has
// none. `SeptaskKitDo` calls `sync` on each change and each minute.
@MainActor
final class SeptaskKitDoStatusItem: NSObject, NSMenuDelegate {
  static let shared = SeptaskKitDoStatusItem()

  private var item: NSStatusItem?

  func sync() {
    guard let doing = DoStore.shared.current, !doing.isStale else {
      if let item { NSStatusBar.system.removeStatusItem(item) }
      item = nil
      return
    }
    let time = SeptaskKitDo.timeText(doing)
    let button = ensureItem().button
    button?.title = time
    button?.toolTip = RegistryDoing.notice(title: doing.title)
    button?.setAccessibilityLabel("\(RegistryDoing.notice(title: doing.title)), \(time)")
  }

  private func ensureItem() -> NSStatusItem {
    if let item { return item }
    let made = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    made.button?.image = NSImage(systemSymbolName: RegistryIcons.sfSymbol(for: "action.do"),
                                 accessibilityDescription: nil)
    made.button?.imagePosition = .imageLeading
    made.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    made.menu = menu
    item = made
    return made
  }

  /// Built on each open, so the menu always acts on the Do it names.
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    guard let doing = DoStore.shared.current else { return }
    menu.addItem(.sectionHeader(title: doing.title))
    let actions = SeptaskKitDo.shared.menu(for: doing)
    for entry in actions.items {
      actions.removeItem(entry)
      menu.addItem(entry)
    }
    menu.addItem(.separator())
    menu.addItem(KitClosureMenuItem(entry: RegistryMenuEntry(
      id: RegistryActionID.appSeptenaWindow.rawValue,
      title: RegistryActions.title(.appSeptenaWindow),
      sfSymbol: RegistryActions.sfSymbols[.appSeptenaWindow],
      perform: { SeptaskKitDo.shared.showShell() })))
  }
}
#endif
