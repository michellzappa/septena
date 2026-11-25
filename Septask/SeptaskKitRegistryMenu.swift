#if os(macOS)
import AppKit

/// Renders a resolved registry menu (`RegistryMenuNode`, see
/// `Septena/Shell/UI/RegistryMenu.swift`) as an `NSMenu` for the AppKit shell.
/// The SwiftUI shell renders the same tree with `RegistryMenuContent`, so the
/// two shells show the same items, titles, icons and key equivalents.
///
/// Menus are built fresh on every open from the current selection, so no item
/// state is cached and nothing needs revalidating.
@MainActor
enum KitRegistryMenu {
  static func build(_ nodes: [RegistryMenuNode]) -> NSMenu {
    let menu = NSMenu()
    // Enabled state comes from the binding (nil handler = disabled), not
    // from responder-chain validation.
    menu.autoenablesItems = false
    for node in nodes {
      switch node {
      case .item(let entry):
        menu.addItem(KitClosureMenuItem(entry: entry))
      case .submenu(_, let title, let sfSymbol, let children):
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = sfSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        parent.submenu = build(children)
        menu.addItem(parent)
      case .divider:
        menu.addItem(.separator())
      }
    }
    return menu
  }

  /// Resolve and build in one step.
  static func build(_ items: [RegistryMenuItem],
                    bind: (String) -> RegistryActionBinding?,
                    slot: (String) -> [RegistryMenuNode] = { _ in [] }) -> NSMenu {
    build(RegistryMenuResolver.resolve(items, bind: bind, slot: slot))
  }
}

/// An `NSMenuItem` that runs a closure. The item is its own target.
@MainActor
final class KitClosureMenuItem: NSMenuItem {
  private let handler: (() -> Void)?

  init(entry: RegistryMenuEntry) {
    handler = entry.perform
    super.init(title: entry.title, action: #selector(fire), keyEquivalent: "")
    target = self
    isEnabled = entry.perform != nil
    state = entry.isOn ? .on : .off
    switch entry.listIcon {
    case .area(let emoji):
      image = KitGlyph.area(emoji: emoji, diameter: 14)
    case .project(let progress):
      image = KitGlyph.progress(progress, tint: SeptaskKitTheme.inkSecondary, diameter: 12)
    case nil:
      image = entry.sfSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }
    if let shortcut = entry.shortcut {
      keyEquivalent = shortcut.appKitKeyEquivalent
      keyEquivalentModifierMask = shortcut.appKitModifiers
    }
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  @objc private func fire() { handler?() }
}

extension RegistryShortcut {
  /// The key equivalent string `NSMenuItem` expects.
  var appKitKeyEquivalent: String {
    switch key {
    case "delete": return "\u{8}"
    case "space": return " "
    case "return": return "\r"
    case "escape": return "\u{1b}"
    case "tab": return "\t"
    default: return key
    }
  }

  var appKitModifiers: NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    for modifier in modifiers {
      switch modifier {
      case "primary": flags.insert(.command)
      case "shift": flags.insert(.shift)
      case "alt": flags.insert(.option)
      case "ctrl": flags.insert(.control)
      default: break
      }
    }
    return flags
  }
}
#endif
