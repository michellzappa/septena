import SwiftUI

// Menus rendered from `registry/actions.json` (ADR 0015, ADR 0020, #177).
//
// The registry owns WHICH items a menu holds, their order, titles, icons,
// roles and shortcuts. A shell owns only what each action DOES: it answers
// `bind(actionId)` with a handler (or nil to leave the item out) and fills
// the named slots (move destinations, text size steps). Both shells walk the
// same tree, so the SwiftUI and AppKit menus cannot drift apart.
//
// `RegistryMenuNode` is the resolved tree. `RegistryMenuContent` renders it in
// SwiftUI (context menus, menu bar commands); `KitRegistryMenu` renders it as
// an `NSMenu` in the AppKit shell.

/// The platform key the registry gates on (`availability.platforms`,
/// `shortcut.excludePlatforms`).
enum RegistryPlatform {
  static var current: String {
    #if os(macOS)
    return "macos"
    #elseif os(iOS)
    // Menus and swipes resolve on the main thread; `UIDevice` is main-actor.
    guard Thread.isMainThread else { return "ios" }
    let isPad = MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad }
    return isPad ? "ipados" : "ios"
    #else
    return "watchos"
    #endif
  }

  /// Desktop platforms use an action's `desktopTitle` (Rename instead of
  /// Edit Details…), in the menu bar and in context menus alike.
  static var isDesktop: Bool {
    ["macos", "windows", "web"].contains(current)
  }
}

/// Which of an action's registry titles a menu item shows.
enum RegistryTitleVariant: String {
  case base = "title"
  case active = "activeTitle"
  case plural = "pluralTitle"
  case add = "addTitle"
  case remove = "removeTitle"
  case short = "shortTitle"
  case desktop = "desktopTitle"
}

extension RegistryActions {
  /// The localized title of `id` in `variant`, falling back to the base title.
  /// The base title is the desktop title on a desktop platform.
  static func title(_ id: String, _ variant: RegistryTitleVariant = .base) -> String {
    let alternates = alternateTitles[id] ?? [:]
    if variant != .base, let title = alternates[variant.rawValue] { return title }
    if RegistryPlatform.isDesktop, let desktop = alternates[RegistryTitleVariant.desktop.rawValue] {
      return desktop
    }
    return titles[id] ?? id
  }

  /// The action's shortcut on this platform, nil when it has none here.
  static func shortcut(for id: String) -> RegistryShortcut? {
    guard let shortcut = shortcuts[id],
          !shortcut.excludePlatforms.contains(RegistryPlatform.current) else { return nil }
    return shortcut
  }

  /// True when the action exists on this platform (`availability.platforms`).
  static func isAvailableOnPlatform(_ id: String) -> Bool {
    guard let platforms = availability[id]?.platforms, !platforms.isEmpty else { return true }
    return platforms.contains(RegistryPlatform.current)
  }

  static func menu(_ id: String) -> [RegistryMenuItem] {
    contextMenus[id] ?? []
  }

  static func menuBarMenu(_ id: String) -> RegistryMenu? {
    menuBar.first { $0.id == id }
  }
}

/// What a shell supplies for one registry action in one menu.
struct RegistryActionBinding {
  /// nil disables the item (its key equivalent falls through).
  var perform: (() -> Void)?
  var variant: RegistryTitleVariant = .base
  /// A checkmark (state on).
  var isOn = false
  /// The action's registry shortcut is shown and bound. Off where another
  /// path owns the key (for example a focused list handles it).
  var showsShortcut = true

  init(variant: RegistryTitleVariant = .base, isOn: Bool = false,
       showsShortcut: Bool = true, perform: (() -> Void)?) {
    self.perform = perform
    self.variant = variant
    self.isOn = isOn
    self.showsShortcut = showsShortcut
  }
}

/// One resolved menu entry, ready to render.
indirect enum RegistryMenuNode: Identifiable {
  /// A registry action, or a slot entry (`actionId` nil) the shell built.
  case item(RegistryMenuEntry)
  case submenu(id: String, title: String, sfSymbol: String?, children: [RegistryMenuNode])
  case divider(id: String)

  var id: String {
    switch self {
    case .item(let entry): return entry.id
    case .submenu(let id, _, _, _): return "submenu.\(id)"
    case .divider(let id): return id
    }
  }

  var isDivider: Bool {
    if case .divider = self { return true }
    return false
  }
}

struct RegistryMenuEntry {
  let id: String
  let title: String
  let sfSymbol: String?
  var shortcut: RegistryShortcut?
  var isDestructive = false
  var isOn = false
  var perform: (() -> Void)?

  /// A slot entry: a dynamic item (a destination, a text size step).
  static func slot(id: String, title: String, sfSymbol: String? = nil, isOn: Bool = false,
                   perform: (() -> Void)?) -> RegistryMenuNode {
    .item(RegistryMenuEntry(id: "slot.\(id)", title: title, sfSymbol: sfSymbol,
                            shortcut: nil, isOn: isOn, perform: perform))
  }
}

enum RegistryMenuResolver {
  /// Walk registry menu items into a resolved tree. `bind` returns nil to
  /// leave an action out; a submenu with nothing left in it is dropped, and
  /// dividers never lead, trail or double up.
  static func resolve(_ items: [RegistryMenuItem],
                      bind: (String) -> RegistryActionBinding?,
                      slot: (String) -> [RegistryMenuNode] = { _ in [] }) -> [RegistryMenuNode] {
    var nodes: [RegistryMenuNode] = []
    for item in items {
      switch item.kind {
      case "action":
        guard RegistryActions.isAvailableOnPlatform(item.id), let binding = bind(item.id) else { continue }
        // A menu-bar item may name another title field (`titleField`); the
        // generator already put that title on the item. Variants win over it.
        let title = binding.variant == .base
          ? (RegistryPlatform.isDesktop ? RegistryActions.title(item.id) : (item.title ?? RegistryActions.title(item.id)))
          : RegistryActions.title(item.id, binding.variant)
        nodes.append(.item(RegistryMenuEntry(
          id: item.id,
          title: title,
          sfSymbol: item.sfSymbol,
          shortcut: binding.showsShortcut ? RegistryActions.shortcut(for: item.id) : nil,
          isDestructive: RegistryActions.destructive.contains(item.id),
          isOn: binding.isOn,
          perform: binding.perform)))
      case "submenu":
        let children = resolve(item.items, bind: bind, slot: slot)
        guard children.contains(where: { !$0.isDivider }) else { continue }
        nodes.append(.submenu(id: item.id, title: item.title ?? item.id,
                              sfSymbol: item.sfSymbol, children: children))
      case "slot":
        nodes.append(contentsOf: slot(item.id))
      case "divider":
        nodes.append(.divider(id: "\(item.id).\(nodes.count)"))
      default:
        continue
      }
    }
    return tidy(nodes)
  }

  /// Drop leading, trailing and repeated dividers.
  static func tidy(_ nodes: [RegistryMenuNode]) -> [RegistryMenuNode] {
    var out: [RegistryMenuNode] = []
    for node in nodes {
      if node.isDivider, out.last?.isDivider ?? true { continue }
      out.append(node)
    }
    while out.last?.isDivider == true { out.removeLast() }
    return out
  }
}

// MARK: - Shortcuts

extension RegistryShortcut {
  /// The registry shortcut as a SwiftUI binding (`primary` is ⌘).
  var keyboardShortcut: KeyboardShortcut {
    KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
  }

  var keyEquivalent: KeyEquivalent {
    switch key {
    case "delete": return .delete
    case "space": return .space
    case "return": return .return
    case "escape": return .escape
    case "tab": return .tab
    case "up": return .upArrow
    case "down": return .downArrow
    case "left": return .leftArrow
    case "right": return .rightArrow
    default: return KeyEquivalent(Character(key))
    }
  }

  var eventModifiers: EventModifiers {
    var flags: EventModifiers = []
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

// MARK: - SwiftUI renderer

/// Renders a resolved registry menu as SwiftUI menu content — inside
/// `.contextMenu`, a `Menu`, or a `CommandMenu`.
struct RegistryMenuContent: View {
  let nodes: [RegistryMenuNode]

  var body: some View {
    ForEach(nodes) { node in
      switch node {
      case .item(let entry):
        RegistryMenuButton(entry: entry)
      case .submenu(_, let title, let sfSymbol, let children):
        Menu {
          // AnyView: a view type cannot contain itself.
          AnyView(RegistryMenuContent(nodes: children))
        } label: {
          if let sfSymbol { Label(title, systemImage: sfSymbol) } else { Text(title) }
        }
      case .divider:
        Divider()
      }
    }
  }
}

private struct RegistryMenuButton: View {
  let entry: RegistryMenuEntry

  var body: some View {
    if entry.isOn {
      // A checked item: a Toggle draws the native checkmark in a menu.
      Toggle(isOn: Binding(get: { true }, set: { _ in entry.perform?() })) {
        Text(entry.title)
      }
      .keyboardShortcut(entry.shortcut?.keyboardShortcut)
      .disabled(entry.perform == nil)
    } else {
      Button(role: entry.isDestructive ? .destructive : nil) {
        entry.perform?()
      } label: {
        if let sfSymbol = entry.sfSymbol {
          Label(entry.title, systemImage: sfSymbol)
        } else {
          Text(entry.title)
        }
      }
      .keyboardShortcut(entry.shortcut?.keyboardShortcut)
      .disabled(entry.perform == nil)
    }
  }
}
