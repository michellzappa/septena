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
///
/// A real `NSButton`, not a hand-tracked `NSView`. Same lesson as
/// `KitDisclosureView` / `KitScreenTitleCell`: `NSTableView`'s mouseDown
/// tracking loop eats mouseUp before a custom view's pair can fire, so
/// checkbox taps were intermittent. An `NSControl` brings its own tracking.
@MainActor
final class KitCheckboxView: NSButton {
  static let boxSize: CGFloat = 14
  /// Matches `Theme.checkboxTap` on macOS — the hit column, not the glyph.
  static let tapSize: CGFloat = 22
  private static let corner: CGFloat = 3.5
  private static let stroke: CGFloat = 1.2

  var isDone = false { didSet { needsDisplay = true; refreshAccessibility() } }
  var isDashed = false { didSet { needsDisplay = true; refreshAccessibility() } }
  var isToday = false { didSet { needsDisplay = true; refreshAccessibility() } }
  /// Today tenure dial (0…1) — gold interior deepening one seventh per carried
  /// day (`SeptenaTask.todayTenureFill`). nil = no dial.
  var tenureFill: Double? = nil { didSet { needsDisplay = true; refreshAccessibility() } }
  /// Unread agent context on a committed task — the haloed corner dot.
  var cornerDot = false { didSet { needsDisplay = true; refreshAccessibility() } }
  /// A fresh, unacknowledged agent-created row — the cue ring.
  var agentCue = false { didSet { needsDisplay = true; refreshAccessibility() } }
  var onToggle: (() -> Void)?

  /// Matches `TaskCheckbox.tenureMaxOpacity`: never fully opaque, so an aged
  /// Today task can't read as a solid/done box.
  private static let tenureMaxOpacity: CGFloat = 0.7

  override var intrinsicContentSize: NSSize {
    NSSize(width: Self.tapSize, height: Self.tapSize)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isBordered = false
    bezelStyle = .inline
    title = ""
    imagePosition = .imageOnly
    target = self
    action = #selector(fire)
    // Keyboard focus stays on the table — mirrors `.focusable(false)` on the
    // SwiftUI checkbox, so Space can never activate a completion.
    refusesFirstResponder = true
    refreshAccessibility()
  }

  required init?(coder: NSCoder) { fatalError("KitCheckboxView is code-only") }

  @objc private func fire() { onToggle?() }

  /// VoiceOver: real checkbox role + shared `TaskA11y` vocabulary. Press
  /// activates `onToggle` (same as a mouse click on the box).
  private func refreshAccessibility() {
    kitA11yElement(
      role: .checkBox,
      label: TaskA11y.checkboxLabel(),
      value: TaskA11y.checkboxValue(isDone: isDone),
      help: TaskA11y.checkboxHelp(isDone: isDone,
                                  isDashed: isDashed,
                                  isToday: isToday,
                                  tenureFill: tenureFill,
                                  agentCue: agentCue,
                                  cornerDot: cornerDot))
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
    if isToday {
      SeptaskKitTheme.todayAccent.setStroke()
    } else if let tenureFill, tenureFill > 0 {
      // Matches TaskCheckbox exactly: when the pinned badge ISN'T shown (the
      // Today screen suppresses it — redundant there), the outline itself
      // fades gray→gold in lockstep with the tenure fill instead of jumping
      // straight to solid gold, so there's no step-change on day 1.
      let strength = CGFloat(min(1, max(0, tenureFill))) * Self.tenureMaxOpacity
      SeptaskKitTheme.checkboxStroke.blended(withFraction: strength,
                                             of: SeptaskKitTheme.todayAccent)?.setStroke()
        ?? SeptaskKitTheme.checkboxStroke.setStroke()
    } else {
      SeptaskKitTheme.checkboxStroke.setStroke()
    }
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
    // Visual top-right — `isFlipped` swaps which edge is "top" (NSButton
    // is flipped; the old NSView subclass was not).
    if cornerDot {
      let topY = isFlipped ? box.minY - 1 : box.maxY + 1
      let center = NSPoint(x: box.maxX + 1, y: topY)
      let halo = NSRect(x: center.x - 3.4, y: center.y - 3.4, width: 6.8, height: 6.8)
      SeptaskKitTheme.cardSurface.setFill()
      NSBezierPath(ovalIn: halo).fill()
      let dot = NSRect(x: center.x - 2.1, y: center.y - 2.1, width: 4.2, height: 4.2)
      SeptaskKitTheme.todayAccent.setFill()
      NSBezierPath(ovalIn: dot).fill()
    }
  }

  /// The check mark inside a completed box (`checkSize` 9 in TaskCheckbox).
  /// Fractions are top-down visual (0 = top of box) so the glyph stays upright
  /// whether the view is flipped (`NSButton`) or not.
  private func drawCheck(in box: NSRect) {
    func y(_ fromTop: CGFloat) -> CGFloat {
      isFlipped
        ? box.minY + box.height * fromTop
        : box.maxY - box.height * fromTop
    }
    let path = NSBezierPath()
    path.move(to: NSPoint(x: box.minX + box.width * 0.26, y: y(0.48)))
    path.line(to: NSPoint(x: box.minX + box.width * 0.44, y: y(0.74)))
    path.line(to: NSPoint(x: box.minX + box.width * 0.76, y: y(0.28)))
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
  /// o'clock and sweeps clockwise (diameter 14 by default, line width scaled
  /// to match — the group header passes a bigger `diameter` for its chunkier
  /// icon).
  static func progress(_ value: Double, tint: NSColor = .secondaryLabelColor,
                       diameter: CGFloat = 14) -> NSImage {
    let clamped = value.isFinite ? max(0, min(1, value)) : 0
    // Quantized so scrolling a long sidebar reuses cache entries.
    let step = (clamped * 20).rounded() / 20
    let key = cacheKey("p:\(step):\(tint.description):\(diameter)")
    if let hit = cache[key] { return hit }

    let lineWidth = diameter * (2.5 / 14)
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
  /// a checkable or progress ring. `diameter` scales the whole image (dot
  /// inset stays proportional) — the group header passes a bigger one.
  static func areaDot(diameter: CGFloat = 16) -> NSImage {
    let key = cacheKey("dot:\(diameter)")
    if let hit = cache[key] { return hit }
    let inset = diameter * (5.0 / 16)
    let image = draw(size: NSSize(width: diameter, height: diameter)) { rect in
      SeptaskKitTheme.iconMuted.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset)).fill()
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

  /// One row in the ⌘⇧M type-to-filter picker — areas AND projects, nested
  /// like SwiftUI `MovePickerSheet` (loose projects, then each area with its
  /// projects indented underneath).
  struct PickerRow {
    let title: String
    let target: Destination
    let emoji: String?
    /// Indent project rows that nest under an area.
    let indent: Bool
    /// Drives the project pie glyph; nil for area / No List rows.
    let projectId: String?
  }

  /// Context-menu / submenu targets — areas only. A long flat `NSMenu` of
  /// every project is unwieldy; the type-to-filter modal
  /// (`pickerDestinations`) is where projects live.
  /// `emoji` rides alongside `title` rather than getting folded into it —
  /// `build()` prefixes the menu title with it (a plain `NSMenuItem` has no
  /// icon-column slot of its own); `SeptaskKitMoveModal` swaps its icon
  /// column glyph for it instead, same "emoji replaces the generic glyph,
  /// never both" rule `KitScreenTitleCell`/`SidebarCell` already follow.
  static func destinations(areas: [Area], projects: [Project])
    -> [(title: String, target: Destination, emoji: String?)] {
    [(String(localized: "No List", comment: "SeptaskKit: move destination"), .none, nil)]
      + areas.map { ($0.title, .area($0.id), $0.emoji) }
  }

  /// Full Move picker list — No List, loose projects, then each area with
  /// its active projects nested. Mirrors `MovePickerSheet`'s hierarchy.
  static func pickerDestinations(areas: [Area], projects: [Project]) -> [PickerRow] {
    let active = projects.filter { $0.status == .active }
    var rows: [PickerRow] = [
      PickerRow(title: String(localized: "No List", comment: "SeptaskKit: move destination"),
                target: .none, emoji: nil, indent: false, projectId: nil)
    ]
    for project in active where project.area == nil {
      rows.append(PickerRow(title: project.title, target: .project(project.id),
                            emoji: nil, indent: false, projectId: project.id))
    }
    for area in areas {
      rows.append(PickerRow(title: area.title, target: .area(area.id),
                            emoji: area.emoji, indent: false, projectId: nil))
      for project in active where project.area == area.id {
        rows.append(PickerRow(title: project.title, target: .project(project.id),
                              emoji: nil, indent: true, projectId: project.id))
      }
    }
    return rows
  }

  static func build(areas: [Area], projects: [Project],
                    target: AnyObject, action: Selector) -> NSMenu {
    let menu = NSMenu()
    for (index, entry) in destinations(areas: areas, projects: projects).enumerated() {
      let title = entry.emoji.map { "\($0)  \(entry.title)" } ?? entry.title
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
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

// MARK: - Selection emphasis

/// Whether this row's selection should read as ACTIVE — the accent wash —
/// rather than parked in the neutral gray.
///
/// Deliberately NOT `NSTableRowView.isEmphasized`. That flag is state AppKit
/// PUSHES down onto each row view, so every row keeps its own copy of what is
/// really one list-wide fact. Both tables here run `selectionHighlightStyle =
/// .none` and recycle row views through `makeView(withIdentifier:)`, so a row
/// view dequeued after the last push keeps whatever answer it last held and
/// the copies drift apart: the selection painted blue on one task and gray on
/// another, and arrowing could not clear it, because moving the selection only
/// samples a different stale copy. A key-window round trip repainted every
/// visible row at once, which is why clicking away and back appeared to fix it.
///
/// Emphasis belongs to the LIST, not to a row, so compute it on demand from
/// the two conditions that define it and keep no copy to go stale.
extension NSTableRowView {
  var septaskSelectionIsActive: Bool {
    guard let window, window.isKeyWindow,
          let table = septaskEnclosingTableView,
          let responder = window.firstResponder as? NSView
    else { return false }
    // The field editor for an inline rename is a DESCENDANT of the table, so
    // a row being renamed still counts as focused (AppKit's flag said no).
    return responder === table || responder.isDescendant(of: table)
  }

  private var septaskEnclosingTableView: NSTableView? {
    var view: NSView? = superview
    while let current = view {
      if let table = current as? NSTableView { return table }
      view = current.superview
    }
    return nil
  }

  /// Key-state changes move `septaskSelectionIsActive` without touching the
  /// row, so the row has to be told to repaint. Registered per row view in
  /// `viewDidMoveToWindow`; NotificationCenter holds observers weakly, so
  /// there is nothing to unregister on dealloc.
  @objc func septaskRedrawSelection() { needsDisplay = true }

  func septaskObserveKeyWindow() {
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      center.removeObserver(self, name: name, object: nil)
      guard let window else { continue }
      center.addObserver(self, selector: #selector(septaskRedrawSelection),
                         name: name, object: window)
    }
  }
}

extension NSTableView {
  /// Repaint every on-screen row's selection. Focus changes are list-wide, so
  /// this is how a first-responder change reaches the rows.
  func septaskRefreshSelectionEmphasis() {
    enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
  }
}

// MARK: - Card row background

/// The grouped-card surface the SwiftUI list draws its rows on: white card,
/// gray page behind, rounded only at the ends of a run of rows. Selection
/// draws inside the card so the highlight can't overhang it.
///
/// Contiguous multi-selection is its OWN rounding run, independent of the
/// card group: square where selected rows meet, rounded at the ends of the
/// selection. Using the card-group flags for selection (the old path) left
/// every selected row fully rounded — the scalloped "kissing circles" look
/// at each selected-row junction.
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

  /// Contiguous selected neighbors on the same card. The list controller
  /// refreshes these on every selection change (and in `rowViewForRow`) so a
  /// row that was the end of a selection run re-squares when the next row
  /// joins it — painting only in `drawSelection` would leave the old rounded
  /// end stale.
  var joinsSelectedAbove = false
  var joinsSelectedBelow = false

  /// The inline composer is open on this row. Things drops the blue selection
  /// wash while editing — the expanded row stays on the white card so the
  /// title reads as integrated text, not a selected cell with a field on top.
  var isComposing = false

  /// A bare title field editor (⌘N / ⌘R) is live on this row. Same reason as
  /// `isComposing`: the wash behind an active text field reads as a selected
  /// cell with an input box dropped on it, and at a wide window the fill spans
  /// the whole card behind the caret. The composer path already dropped the
  /// wash; the field-editor path did not, so creating a task left you typing
  /// into a full-width blue band.
  var isEditingTitle = false

  /// Insertion line while a task drag is hovering. `.top` / `.bottom` sit on
  /// this row's edge (the drop is `.above` a row, or after the last row).
  /// Mirrors SwiftUI `TaskReorderDrop`'s 3pt capsule — a position marker,
  /// not a row highlight, and not NSTableView's `.gap` feedback (that hole
  /// splits a per-row card into two).
  enum DropLine {
    case none, top, bottom
  }
  var dropLine: DropLine = .none {
    didSet { if oldValue != dropLine { needsDisplay = true } }
  }

  /// Layer-backed tables paint a full-row selection fill that never goes
  /// through `drawSelection` — a second, rectangular highlight around the
  /// inset card. Selection is therefore drawn in `drawBackground` (same clip
  /// as the card) and `selectionHighlightStyle` is `.none` so AppKit's fill
  /// stays off. These overrides keep the wash in sync when focus moves.
  override var isSelected: Bool {
    get { super.isSelected }
    set { super.isSelected = newValue; needsDisplay = true }
  }
  override var isEmphasized: Bool {
    get { super.isEmphasized }
    set { super.isEmphasized = newValue; needsDisplay = true }
  }

  /// Selection emphasis is computed at draw time (`septaskSelectionIsActive`),
  /// so this row repaints when its window's key state flips.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    septaskObserveKeyWindow()
    needsDisplay = true
  }

  /// Uneven rounded rect for a card/selection slice. A fully-joined slice
  /// (both ends square) is a plain rect — exact edge, no antialiased curve
  /// for a neighbor to disagree with. One-sided joins over-extend the square
  /// end past this row's bounds so that corner falls outside the clip;
  /// `NSTableRowView` is flipped (minY = top), so "join above" extends
  /// origin.y upward.
  private func slicePath(roundTop: Bool, roundBottom: Bool) -> NSBezierPath {
    let inset = bounds.insetBy(dx: SeptaskKitLayout.inset(for: bounds.width), dy: 0)
    if !roundTop && !roundBottom {
      return NSBezierPath(rect: inset)
    }
    if roundTop && roundBottom {
      return NSBezierPath(roundedRect: inset, xRadius: Self.corner, yRadius: Self.corner)
    }
    var rect = inset
    if !roundTop {
      rect.origin.y -= Self.corner
      rect.size.height += Self.corner
    }
    if !roundBottom {
      rect.size.height += Self.corner
    }
    return NSBezierPath(roundedRect: rect, xRadius: Self.corner, yRadius: Self.corner)
  }

  override func drawBackground(in dirtyRect: NSRect) {
    guard isCard else {
      super.drawBackground(in: dirtyRect)
      drawDropLine()
      return
    }
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: bounds).setClip()
    SeptaskKitTheme.cardSurface.setFill()
    slicePath(roundTop: isFirstInGroup, roundBottom: isLastInGroup).fill()
    // Selection rides on the card (same clip, selection-run rounding) so it
    // cannot overhang as a second rectangle. Composer owns the surface.
    if isSelected && !isComposing && !isEditingTitle {
      SeptaskKitTheme.listSelectionFill(emphasized: septaskSelectionIsActive).setFill()
      slicePath(roundTop: !joinsSelectedAbove, roundBottom: !joinsSelectedBelow).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    drawDropLine()
  }

  /// No-op: selection is painted in `drawBackground`. The table's
  /// `selectionHighlightStyle` is `.none`, so AppKit does not call this;
  /// kept empty so a style regression cannot restore the full-row fill.
  override func drawSelection(in dirtyRect: NSRect) {}

  /// 3pt capsule on the drop edge — SwiftUI `TaskReorderDrop.insertionLine`.
  /// Horizontal inset matches that overlay's 20pt pad inside the card.
  private func drawDropLine() {
    guard dropLine != .none else { return }
    let thickness: CGFloat = 3
    let inset = SeptaskKitLayout.inset(for: bounds.width) + 20
    let y: CGFloat = dropLine == .top ? 0 : bounds.height - thickness
    let rect = NSRect(x: inset, y: y,
                      width: max(0, bounds.width - inset * 2),
                      height: thickness)
    SeptaskKitTheme.inkPrimary.setFill()
    NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2).fill()
  }

  /// Keep row content in its normal ink. AppKit flips cell text to white for
  /// an emphasized selection, which would be invisible on the neutral fill.
  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Source-list selection: same `listSelectionFill(emphasized:)` token as the
/// task list, drawn INSET and rounded — the sidebar/palette shape versus the
/// full-bleed card shape.
@MainActor
final class KitSidebarRowView: NSTableRowView {
  /// Extra height `heightOfRowByItem` adds ABOVE a top-level area/loose-
  /// project row — its section-start margin. The selection pill must not
  /// cover that band, or a selected area reads as if the blank space above
  /// it were selected too. 0 for every other row (the common case). Set
  /// alongside this row view in `outlineView(_:rowViewForItem:)`.
  var extraTopMargin: CGFloat = 0

  /// See `KitCardRowView.viewDidMoveToWindow`.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    septaskObserveKeyWindow()
    needsDisplay = true
  }

  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    // The pill covers only the row's CONTENT band — `bounds` minus
    // `extraTopMargin` — sitting at the BOTTOM of `bounds`, matching
    // `SidebarCell`'s own bottom-anchored content (see its
    // `contentBottomInset` comment). For a plain row (`extraTopMargin == 0`)
    // this is just `bounds` itself, same as before.
    let contentHeight = bounds.height - extraTopMargin
    // Vertical inset bumped from 3 down to 1 — was reading a bit thin
    // against the row; this puts ~20% more selected pixels above/below.
    let verticalInset: CGFloat = 1
    // NSTableRowView is FLIPPED (minY is the row's visual TOP, not its
    // bottom) — the margin band is the first `extraTopMargin` points from
    // `minY`, so skipping it means starting the pill AFTER that, not at
    // `minY` itself. Getting this backwards is what put the pill floating
    // in the margin with the row's text sitting below it, outside the pill.
    let rect = NSRect(x: bounds.minX + 8,
                      y: bounds.minY + extraTopMargin + verticalInset,
                      width: bounds.width - 16,
                      height: contentHeight - verticalInset * 2)
    SeptaskKitTheme.listSelectionFill(emphasized: septaskSelectionIsActive).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
  }

  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
#endif
