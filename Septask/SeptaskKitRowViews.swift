#if os(macOS)
import AppKit

// Drawing primitives shared by the AppKit shell's rows and sidebar — the
// AppKit renderings of the SwiftUI components they name. Geometry constants
// are copied from those views deliberately (they're the spec), and each says
// which one it mirrors so a change there has an obvious landing site here.
//
// These draw with NSBezierPath rather than hosting the SwiftUI originals:
// a hosting view per row is the classic AppKit scroll-perf trap, and speed is
// the whole reason this shell exists. Everything below is a leaf glyph.

// MARK: - Checkbox

/// The task checkbox — AppKit rendering of `TaskCheckbox` (macOS geometry:
/// 14pt rounded square, 3.5 corner, 1.2 stroke). Forms: open, dashed
/// (unratified proposal), gold (promoted to Today), filled + check (done).
@MainActor
final class KitCheckboxView: NSView {
  static let boxSize: CGFloat = 14
  private static let corner: CGFloat = 3.5
  private static let stroke: CGFloat = 1.2

  var isDone = false { didSet { needsDisplay = true } }
  var isDashed = false { didSet { needsDisplay = true } }
  var isToday = false { didSet { needsDisplay = true } }
  /// Today tenure dial (0…1) — gold interior deepening one seventh per carried
  /// day (`SeptenaTask.todayTenureFill`). nil = no dial.
  var tenureFill: Double? = nil { didSet { needsDisplay = true } }
  /// Unread agent context on a committed task — the haloed corner dot.
  var cornerDot = false { didSet { needsDisplay = true } }
  /// A fresh, unacknowledged agent-created row — the cue ring.
  var agentCue = false { didSet { needsDisplay = true } }
  var onToggle: (() -> Void)?

  /// Matches `TaskCheckbox.tenureMaxOpacity`: never fully opaque, so an aged
  /// Today task can't read as a solid/done box.
  private static let tenureMaxOpacity: CGFloat = 0.7

  override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }

  /// Keyboard focus stays on the table — mirrors `.focusable(false)` on the
  /// SwiftUI checkbox, so Space can never activate a completion.
  override var acceptsFirstResponder: Bool { false }

  override func mouseDown(with event: NSEvent) {
    // Swallow the press so a click on the box doesn't also start a row drag.
  }

  override func mouseUp(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if bounds.contains(point) { onToggle?() }
  }

  override func draw(_ dirtyRect: NSRect) {
    let box = NSRect(x: (bounds.width - Self.boxSize) / 2,
                     y: (bounds.height - Self.boxSize) / 2,
                     width: Self.boxSize, height: Self.boxSize)

    if isDone {
      SeptaskKitTheme.checkboxFill.setFill()
      NSBezierPath(roundedRect: box, xRadius: Self.corner, yRadius: Self.corner).fill()
      drawCheck(in: box)
      return
    }

    // Tenure dial sits BEHIND the outline: the interior tints gold and
    // deepens with days carried on Today, while the box keeps its pure form.
    if let tenureFill, tenureFill > 0 {
      let strength = CGFloat(min(1, max(0, tenureFill))) * Self.tenureMaxOpacity
      SeptaskKitTheme.todayAccent.withAlphaComponent(strength).setFill()
      NSBezierPath(roundedRect: box, xRadius: Self.corner, yRadius: Self.corner).fill()
    }

    let inset = box.insetBy(dx: Self.stroke / 2, dy: Self.stroke / 2)
    let path = NSBezierPath(roundedRect: inset, xRadius: Self.corner, yRadius: Self.corner)
    path.lineWidth = Self.stroke
    if isDashed {
      // Unratified proposal — the readiness form from language v2.
      path.setLineDash([2.5, 2.0], count: 2, phase: 0)
    }
    (isToday ? SeptaskKitTheme.todayAccent : SeptaskKitTheme.checkboxStroke).setStroke()
    path.stroke()

    // Agent cue — a soft ring outside the box marking a fresh, unengaged
    // agent-created row. Clears when the row is acknowledged.
    if agentCue {
      let ring = NSBezierPath(roundedRect: box.insetBy(dx: -2.5, dy: -2.5),
                              xRadius: Self.corner + 2, yRadius: Self.corner + 2)
      ring.lineWidth = 1.4
      SeptaskKitTheme.todayAccent.withAlphaComponent(0.55).setStroke()
      ring.stroke()
    }

    // Unread-context dot, haloed so it reads on any row background.
    if cornerDot {
      let center = NSPoint(x: box.maxX + 1, y: box.maxY + 1)
      let halo = NSRect(x: center.x - 3.4, y: center.y - 3.4, width: 6.8, height: 6.8)
      SeptaskKitTheme.cardSurface.setFill()
      NSBezierPath(ovalIn: halo).fill()
      let dot = NSRect(x: center.x - 2.1, y: center.y - 2.1, width: 4.2, height: 4.2)
      SeptaskKitTheme.todayAccent.setFill()
      NSBezierPath(ovalIn: dot).fill()
    }
  }

  /// The check mark inside a completed box (`checkSize` 9 in TaskCheckbox).
  private func drawCheck(in box: NSRect) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: box.minX + box.width * 0.26, y: box.midY + box.height * 0.02))
    path.line(to: NSPoint(x: box.minX + box.width * 0.44, y: box.minY + box.height * 0.26))
    path.line(to: NSPoint(x: box.minX + box.width * 0.76, y: box.maxY - box.height * 0.28))
    path.lineWidth = 1.6
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSColor.white.setStroke()
    path.stroke()
  }
}

// MARK: - Chip

/// A list-membership chip on a row ("# BFF", "📁 Admin") — AppKit rendering of
/// the SwiftUI row's trailing list capsule. Symbols follow `Route.icon`:
/// `number` for a project, `folder` for an area.
@MainActor
final class KitChipView: NSView {
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 5
    layer?.backgroundColor = SeptaskKitTheme.chipFill.cgColor

    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.contentTintColor = SeptaskKitTheme.inkSecondary
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = SeptaskKitTheme.chip
    label.textColor = SeptaskKitTheme.inkSecondary
    label.lineBreakMode = .byTruncatingTail
    addSubview(icon)
    addSubview(label)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 9),
      icon.heightAnchor.constraint(equalToConstant: 9),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      heightAnchor.constraint(equalToConstant: 16),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitChipView is code-only") }

  func configure(symbol: String, title: String) {
    var config = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
    config = config.applying(.init(paletteColors: [SeptaskKitTheme.inkSecondary]))
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    label.stringValue = title
  }

  /// A CGColor is a resolved snapshot, so the fill has to be re-resolved when
  /// the appearance flips (updateLayer only runs if the view opts in).
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = SeptaskKitTheme.chipFill.cgColor
  }
}

// MARK: - Glyph images

/// Small cached images for the sidebar: the Reminders-style colored square
/// (`ColoredGlyph`), the project completion ring (`ProjectProgressIcon`), and
/// the area's muted dot (`SidebarAreaRow`).
@MainActor
enum KitGlyph {
  private static var cache: [String: NSImage] = [:]

  /// `ColoredGlyph` — filled colored rounded square with a white SF Symbol.
  static func colored(symbol: String, color: NSColor, size: CGFloat = 17) -> NSImage? {
    let key = cacheKey("c:\(symbol):\(color.description):\(size)")
    if let hit = cache[key] { return hit }
    // The symbol is tinted white by its own palette configuration — compositing
    // a white fill over it afterwards would flood the whole glyph rect instead.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.58, weight: .semibold)
      .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    else { return nil }

    let image = draw(size: NSSize(width: size, height: size)) { rect in
      color.setFill()
      NSBezierPath(roundedRect: rect, xRadius: size * 0.28, yRadius: size * 0.28).fill()
      let glyphSize = glyph.size
      let target = NSRect(x: rect.midX - glyphSize.width / 2,
                          y: rect.midY - glyphSize.height / 2,
                          width: glyphSize.width, height: glyphSize.height)
      glyph.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }
    cache[key] = image
    return image
  }

  /// `ProjectProgressIcon` — faint track ring under an arc that starts at 12
  /// o'clock and sweeps clockwise (diameter 14, line width 2.5).
  static func progress(_ value: Double, tint: NSColor = .secondaryLabelColor) -> NSImage {
    let clamped = value.isFinite ? max(0, min(1, value)) : 0
    // Quantized so scrolling a long sidebar reuses cache entries.
    let step = (clamped * 20).rounded() / 20
    let key = cacheKey("p:\(step):\(tint.description)")
    if let hit = cache[key] { return hit }

    let diameter: CGFloat = 14, lineWidth: CGFloat = 2.5
    let image = draw(size: NSSize(width: diameter + lineWidth, height: diameter + lineWidth)) { rect in
      let circle = NSRect(x: lineWidth / 2, y: lineWidth / 2, width: diameter, height: diameter)
      let track = NSBezierPath(ovalIn: circle)
      track.lineWidth = lineWidth
      tint.withAlphaComponent(0.22).setStroke()
      track.stroke()

      guard step > 0 else { return }
      let arc = NSBezierPath()
      arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                    radius: diameter / 2,
                    startAngle: 90,
                    endAngle: 90 - 360 * CGFloat(step),
                    clockwise: true)
      arc.lineWidth = lineWidth
      arc.lineCapStyle = .round
      tint.setStroke()
      arc.stroke()
    }
    cache[key] = image
    return image
  }

  /// `SidebarAreaRow`'s filler dot — deliberately solid, so it never reads as
  /// a checkable or progress ring.
  static func areaDot() -> NSImage {
    let key = cacheKey("dot")
    if let hit = cache[key] { return hit }
    let image = draw(size: NSSize(width: 16, height: 16)) { rect in
      SeptaskKitTheme.iconMuted.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5)).fill()
    }
    cache[key] = image
    return image
  }

  /// These are bitmaps with semantic colors baked in, so light and dark need
  /// separate entries — a dynamic NSColor describes itself identically in
  /// both, which would otherwise serve a dark-mode ring in light mode.
  private static func cacheKey(_ base: String) -> String {
    base + "|" + NSApp.effectiveAppearance.name.rawValue
  }

  private static func draw(size: NSSize, _ body: (NSRect) -> Void) -> NSImage {
    let image = NSImage(size: size)
    // Resolve semantic colors against the appearance the key was built for.
    NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
      image.lockFocus()
      body(NSRect(origin: .zero, size: size))
      image.unlockFocus()
    }
    return image
  }
}

// MARK: - Recurrence choices

/// The repeat cadences offered in the AppKit shell, as a menu (context menu
/// submenu) or a popup's items (inspector). A short closed set — anything
/// more exotic is still editable in the SwiftUI repeat sheet.
@MainActor
enum KitRecurrenceMenu {
  /// Menu order, with the rule each row writes. `nil` clears recurrence.
  static let choices: [(title: String, rule: Recurrence?)] = [
    ("Never", nil),
    ("Daily", Recurrence(unit: .day, interval: 1)),
    ("Weekly", Recurrence(unit: .week, interval: 1)),
    ("Every 2 Weeks", Recurrence(unit: .week, interval: 2)),
    ("Monthly", Recurrence(unit: .month, interval: 1)),
  ]

  static func build(target: AnyObject, action: Selector) -> NSMenu {
    let menu = NSMenu()
    for (index, choice) in choices.enumerated() {
      let item = NSMenuItem(title: choice.title, action: action, keyEquivalent: "")
      item.target = target
      item.tag = index
      menu.addItem(item)
    }
    return menu
  }

  static func recurrence(for item: NSMenuItem) -> Recurrence? {
    guard choices.indices.contains(item.tag) else { return nil }
    return choices[item.tag].rule
  }

  /// Which row represents a task's current rule — an interval this menu
  /// doesn't offer falls back to "Never" showing unselected rather than
  /// silently mislabeling the task.
  static func index(of recurrence: Recurrence?) -> Int {
    guard let recurrence else { return 0 }
    return choices.firstIndex {
      $0.rule?.unit == recurrence.unit && $0.rule?.interval == recurrence.interval
    } ?? -1
  }
}

// MARK: - Move destinations

/// The "Move to…" choices: no list, each area, then that area's projects, then
/// loose projects — sidebar order throughout (`StructureCache`). Built once
/// and shared by the context menu, the menu bar, and the ⌘⇧M popup so the
/// three can't drift.
@MainActor
enum KitMoveMenu {
  enum Destination: Equatable {
    case none
    case area(String)
    case project(String)
  }

  static func destinations(areas: [Area], projects: [Project]) -> [(title: String, target: Destination)] {
    var result: [(String, Destination)] = [("No List", .none)]
    let byArea = Dictionary(grouping: projects.filter { $0.deletedAt == nil },
                            by: { $0.area ?? "" })
    for area in areas {
      result.append((area.title, .area(area.id)))
      for project in byArea[area.id] ?? [] {
        // Indented so the nesting reads without a submenu per area.
        result.append(("    " + project.title, .project(project.id)))
      }
    }
    for project in byArea[""] ?? [] {
      result.append((project.title, .project(project.id)))
    }
    return result
  }

  static func build(areas: [Area], projects: [Project],
                    target: AnyObject, action: Selector) -> NSMenu {
    let menu = NSMenu()
    for (index, entry) in destinations(areas: areas, projects: projects).enumerated() {
      let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
      item.target = target
      item.tag = index
      menu.addItem(item)
      if index == 0 { menu.addItem(.separator()) }
    }
    return menu
  }

  static func destination(for item: NSMenuItem,
                          areas: [Area], projects: [Project]) -> Destination? {
    let all = destinations(areas: areas, projects: projects)
    guard all.indices.contains(item.tag) else { return nil }
    return all[item.tag].target
  }
}

// MARK: - Card row background

/// The grouped-card surface the SwiftUI list draws its rows on: white card,
/// gray page behind, rounded only at the ends of a run of rows. Selection
/// draws inside the card so the highlight can't overhang it.
@MainActor
final class KitCardRowView: NSTableRowView {
  /// Seed value other cells use for their leading/trailing constraint
  /// CONSTANTS at init — before their first `layout()` pass sweeps in the
  /// real width-dependent inset (`SeptaskKitLayout.inset(for:)`). Kept equal
  /// to the layout minimum so there's no visible jump on that first pass.
  static let horizontalInset: CGFloat = SeptaskKitLayout.minInset
  static let corner: CGFloat = 11

  var isCard = true
  var isFirstInGroup = true
  var isLastInGroup = true

  private func cardPath() -> NSBezierPath {
    var rect = bounds.insetBy(dx: SeptaskKitLayout.inset(for: bounds.width), dy: 0)
    // Rounded only at the run's ends: over-extend past the row on the joined
    // side so that side's corners fall outside the clipped drawn area and
    // read as square. `NSTableRowView` is FLIPPED (origin top-left, y grows
    // downward), so "joined above" (not first) extends upward — origin AND
    // height — while "joined below" (not last) extends only the height.
    if !isFirstInGroup {
      rect.origin.y -= Self.corner
      rect.size.height += Self.corner
    }
    if !isLastInGroup {
      rect.size.height += Self.corner
    }
    return NSBezierPath(roundedRect: rect, xRadius: Self.corner, yRadius: Self.corner)
  }

  override func drawBackground(in dirtyRect: NSRect) {
    guard isCard else {
      super.drawBackground(in: dirtyRect)
      return
    }
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: bounds).setClip()
    SeptaskKitTheme.cardSurface.setFill()
    cardPath().fill()
    NSGraphicsContext.restoreGraphicsState()
  }

  override func drawSelection(in dirtyRect: NSRect) {
    guard isCard, selectionHighlightStyle != .none else {
      super.drawSelection(in: dirtyRect)
      return
    }
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: bounds).setClip()
    // One neutral fill, focused or not — `Theme.listSelectionFill`. NOT the
    // emphasized `.selectedContentBackgroundColor`: that follows the app
    // accent, and this app's accent is adaptive INK (black in light mode), so
    // the standard treatment paints a black bar. Neutral is also the repo's
    // canonical selection language (docs/DesignSpec.md §4.5).
    SeptaskKitTheme.listSelectionFill.setFill()
    cardPath().fill()
    NSGraphicsContext.restoreGraphicsState()
  }

  /// Keep row content in its normal ink. AppKit flips cell text to white for
  /// an emphasized selection, which would be invisible on the neutral fill.
  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Source-list selection: the same neutral token, drawn INSET and rounded —
/// the sidebar/palette shape of the app's selection language, versus the
/// full-bleed card shape the task list uses.
@MainActor
final class KitSidebarRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    // Vertical inset bumped from 1 to 3 — at 1 the pill touched the row's
    // top/bottom edges almost exactly, so a taller (top-of-section) row's
    // selection stretched full-height instead of floating with margin.
    let rect = bounds.insetBy(dx: 8, dy: 3)
    SeptaskKitTheme.listSelectionFill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
  }

  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
#endif
