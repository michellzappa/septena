import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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
    // Menus resolve on the main thread; `UIDevice` is main-actor.
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
  static func title(_ id: RegistryActionID, _ variant: RegistryTitleVariant = .base) -> String {
    let alternates = alternateTitles[id] ?? [:]
    if variant != .base, let title = alternates[variant.rawValue] { return title }
    if RegistryPlatform.isDesktop, let desktop = alternates[RegistryTitleVariant.desktop.rawValue] {
      return desktop
    }
    return titles[id] ?? id.rawValue
  }

  /// The action's shortcut on this platform, nil when it has none here.
  static func shortcut(for id: RegistryActionID) -> RegistryShortcut? {
    guard let shortcut = shortcuts[id],
          !shortcut.excludePlatforms.contains(RegistryPlatform.current) else { return nil }
    return shortcut
  }

  /// True when the action exists on this platform: `availability.platforms`
  /// lists it and its capability ships here (`registry/capabilities.json`,
  /// ADR 0015). A planned feature shows no menu item.
  static func isAvailableOnPlatform(_ id: RegistryActionID) -> Bool {
    guard let availability = availability[id] else { return true }
    let platform = RegistryPlatform.current
    if !availability.platforms.isEmpty, !availability.platforms.contains(platform) { return false }
    return RegistryCapabilities.isAvailable(availability.featureId, on: platform)
  }

  static func menu(_ id: RegistryContextMenuID) -> [RegistryMenuItem] {
    contextMenus[id] ?? []
  }

  static func menuBarMenu(_ id: RegistryMenuBarID) -> RegistryMenu? {
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

/// Dynamic list icon for area / project destination slots so dropdown menus
/// display the same custom emoji, fallback area dot, or project progress ring
/// as the sidebar.
enum RegistryMenuIcon: Equatable {
  case area(emoji: String?)
  case project(progress: Double)
}

struct RegistryMenuEntry {
  let id: String
  let title: String
  let sfSymbol: String?
  var listIcon: RegistryMenuIcon? = nil
  var shortcut: RegistryShortcut?
  var isDestructive = false
  var isOn = false
  var perform: (() -> Void)?

  /// A slot entry: a dynamic item (a destination, a text size step).
  static func slot(id: String, title: String, sfSymbol: String? = nil,
                   listIcon: RegistryMenuIcon? = nil, isOn: Bool = false,
                   perform: (() -> Void)?) -> RegistryMenuNode {
    .item(RegistryMenuEntry(id: "slot.\(id)", title: title, sfSymbol: sfSymbol,
                            listIcon: listIcon, shortcut: nil, isOn: isOn, perform: perform))
  }
}

enum RegistryMenuResolver {
  /// Walk registry menu items into a resolved tree. `bind` returns nil to
  /// leave an action out; a submenu with nothing left in it is dropped, and
  /// dividers never lead, trail or double up.
  static func resolve(_ items: [RegistryMenuItem],
                      bind: (RegistryActionID) -> RegistryActionBinding?,
                      slot: (String) -> [RegistryMenuNode] = { _ in [] }) -> [RegistryMenuNode] {
    var nodes: [RegistryMenuNode] = []
    for item in items {
      switch item.kind {
      case "action":
        guard let actionId = item.actionId,
              RegistryActions.isAvailableOnPlatform(actionId),
              let binding = bind(actionId) else { continue }
        // A menu-bar item may name another title field (`titleField`); the
        // generator already put that title on the item. Variants win over it.
        let title = binding.variant == .base
          ? (RegistryPlatform.isDesktop ? RegistryActions.title(actionId) : (item.title ?? RegistryActions.title(actionId)))
          : RegistryActions.title(actionId, binding.variant)
        nodes.append(.item(RegistryMenuEntry(
          id: item.id,
          title: title,
          sfSymbol: item.sfSymbol,
          shortcut: binding.showsShortcut ? RegistryActions.shortcut(for: actionId) : nil,
          isDestructive: RegistryActions.destructive.contains(actionId),
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
        itemLabel
      }
      .keyboardShortcut(entry.shortcut?.keyboardShortcut)
      .disabled(entry.perform == nil)
    } else {
      Button(role: entry.isDestructive ? .destructive : nil) {
        entry.perform?()
      } label: {
        itemLabel
      }
      .keyboardShortcut(entry.shortcut?.keyboardShortcut)
      .disabled(entry.perform == nil)
    }
  }

  @ViewBuilder
  private var itemLabel: some View {
    if let listIcon = entry.listIcon {
      Label {
        Text(entry.title)
      } icon: {
        RegistryMenuGlyph.iconView(for: listIcon)
      }
    } else if let sfSymbol = entry.sfSymbol {
      Label(entry.title, systemImage: sfSymbol)
    } else {
      Text(entry.title)
    }
  }
}

@MainActor
private enum RegistryMenuGlyph {
  @ViewBuilder
  static func iconView(for listIcon: RegistryMenuIcon) -> some View {
    switch listIcon {
    case .area(let emoji):
      if let emoji, !emoji.isEmpty {
        emojiImage(emoji)
      } else {
        areaDotImage
      }
    case .project(let progress):
      projectProgressImage(progress)
    }
  }

  #if os(macOS)
  private static func emojiImage(_ text: String) -> some View {
    let size: CGFloat = 15
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size * 0.8)])
      let glyphSize = attr.size()
      attr.draw(at: NSPoint(x: rect.midX - glyphSize.width / 2,
                            y: rect.midY - glyphSize.height / 2))
      return true
    }
    img.isTemplate = false
    return Image(nsImage: img).renderingMode(.original)
  }

  private static var areaDotImage: some View {
    let size: CGFloat = 14
    let inset = size * (5.0 / 16)
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset)).fill()
      return true
    }
    img.isTemplate = true
    return Image(nsImage: img).renderingMode(.template)
  }

  private static func projectProgressImage(_ value: Double) -> some View {
    let clamped = value.isFinite ? max(0, min(1, value)) : 0
    let diameter: CGFloat = 12
    let lineWidth = diameter * (2.5 / 14)
    let canvas = diameter + lineWidth
    let img = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
      let circle = NSRect(x: lineWidth / 2, y: lineWidth / 2, width: diameter, height: diameter)
      let track = NSBezierPath(ovalIn: circle)
      track.lineWidth = lineWidth
      NSColor.black.withAlphaComponent(0.25).setStroke()
      track.stroke()
      if clamped > 0 {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                      radius: diameter / 2,
                      startAngle: 90,
                      endAngle: 90 - 360 * CGFloat(clamped),
                      clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        arc.stroke()
      }
      return true
    }
    img.isTemplate = true
    return Image(nsImage: img).renderingMode(.template)
  }
  #elseif canImport(UIKit)
  private static func emojiImage(_ text: String) -> some View {
    let size: CGFloat = 18
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    let img = renderer.image { _ in
      let attr = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: size * 0.78)])
      let glyphSize = attr.size()
      attr.draw(at: CGPoint(x: (size - glyphSize.width) / 2,
                            y: (size - glyphSize.height) / 2))
    }.withRenderingMode(.alwaysOriginal)
    return Image(uiImage: img).renderingMode(.original)
  }

  private static var areaDotImage: some View {
    let size: CGFloat = 16
    let inset = size * (5.0 / 16)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    let img = renderer.image { ctx in
      UIColor.black.setFill()
      ctx.cgContext.fillEllipse(in: CGRect(x: inset, y: inset,
                                           width: size - inset * 2, height: size - inset * 2))
    }.withRenderingMode(.alwaysTemplate)
    return Image(uiImage: img).renderingMode(.template)
  }

  private static func projectProgressImage(_ value: Double) -> some View {
    let clamped = value.isFinite ? max(0, min(1, value)) : 0
    let diameter: CGFloat = 14
    let lineWidth: CGFloat = 2.4
    let canvas = diameter + lineWidth
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas))
    let img = renderer.image { ctx in
      let cg = ctx.cgContext
      let center = CGPoint(x: canvas / 2, y: canvas / 2)
      let radius = diameter / 2
      cg.setLineWidth(lineWidth)
      cg.setStrokeColor(UIColor.black.withAlphaComponent(0.25).cgColor)
      cg.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
      cg.strokePath()
      if clamped > 0 {
        cg.setLineCap(.round)
        cg.setStrokeColor(UIColor.black.cgColor)
        let start = -CGFloat.pi / 2
        let end = start + CGFloat(clamped) * .pi * 2
        cg.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        cg.strokePath()
      }
    }.withRenderingMode(.alwaysTemplate)
    return Image(uiImage: img).renderingMode(.template)
  }
  #else
  private static func emojiImage(_ text: String) -> some View {
    Text(text)
  }

  private static var areaDotImage: some View {
    Image(systemName: RegistryIcons.sfSymbol(for: "place.area"))
  }

  private static func projectProgressImage(_ value: Double) -> some View {
    Image(systemName: RegistryIcons.sfSymbol(for: "place.project"))
  }
  #endif
}
