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

/// The task checkbox — AppKit rendering of `TaskCheckbox`. Uses a standard
/// macOS `NSButton` checkbox (`setButtonType(.switch)`) for every standard open
/// and done state so light mode, dark mode, Liquid Glass, and the user's System
/// Settings accent work natively. Falls back to custom `NSBezierPath` drawing
/// only for open states the system control cannot express: dashed (unratified
/// proposal / New task placeholder) and gold (promoted to Today on off-Today
/// lists).
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

  /// Native macOS checkbox shown for every standard checkable state.
  private let standardBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  /// Non-interactive overlay above `standardBox` for the unread-context corner
  /// dot and fresh-agent cue ring.
  private let cueOverlay = KitCheckboxCueOverlay()

  var isDone = false { didSet { syncDisplay() } }
  var isDashed = false { didSet { syncDisplay() } }
  var isToday = false { didSet { syncDisplay() } }
  /// Days carried on Today as 0…1 (`SeptenaTask.todayTenureFill`). The box
  /// draws nothing for it: the cell fades its row instead (`TaskFade`). Kept
  /// for the VoiceOver hint only.
  var tenureFill: Double? = nil { didSet { refreshAccessibility() } }
  /// Unread agent context on a committed task — the haloed corner dot.
  var cornerDot = false { didSet { syncDisplay() } }
  /// A fresh, unacknowledged agent-created row — the cue ring.
  var agentCue = false { didSet { syncDisplay() } }
  var onToggle: (() -> Void)?

  override var isEnabled: Bool {
    didSet { standardBox.isEnabled = isEnabled }
  }

  private var usesStandardBox: Bool {
    if isDone && !AppearancePreferences.shared.isColorful { return false }
    return isDone || !isDashed
  }

  func refreshAppearance() {
    syncDisplay()
  }

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

    standardBox.title = ""
    standardBox.imagePosition = .imageOnly
    standardBox.controlSize = .regular
    standardBox.refusesFirstResponder = true
    standardBox.target = self
    standardBox.action = #selector(fireFromStandard)
    standardBox.translatesAutoresizingMaskIntoConstraints = false
    standardBox.kitA11yIgnore()

    cueOverlay.translatesAutoresizingMaskIntoConstraints = false
    cueOverlay.kitA11yIgnore()

    addSubview(standardBox)
    addSubview(cueOverlay)
    NSLayoutConstraint.activate([
      standardBox.centerXAnchor.constraint(equalTo: centerXAnchor),
      standardBox.centerYAnchor.constraint(equalTo: centerYAnchor),
      cueOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
      cueOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
      cueOverlay.topAnchor.constraint(equalTo: topAnchor),
      cueOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    syncDisplay()
  }

  required init?(coder: NSCoder) { fatalError("KitCheckboxView is code-only") }

  private func syncDisplay() {
    let useStandard = usesStandardBox
    standardBox.isHidden = !useStandard
    if useStandard {
      standardBox.state = isDone ? .on : .off
    }
    cueOverlay.cornerDot = !isDone && cornerDot
    cueOverlay.agentCue = !isDone && agentCue
    cueOverlay.isHidden = !cueOverlay.cornerDot && !cueOverlay.agentCue
    cueOverlay.needsDisplay = !cueOverlay.isHidden
    needsDisplay = true
    refreshAccessibility()
  }

  @objc private func fireFromStandard() {
    // Keep the native control synced to the model; `onToggle` drives `isDone`.
    standardBox.state = isDone ? .on : .off
    fire()
  }

  @objc private func fire() {
    // Celebrate on the way IN only, like SwiftUI's `playFeel()` — unchecking
    // is a correction, not an achievement. `isDone` is still the pre-toggle
    // state here, so this fires exactly once per completion.
    if !isDone { playPulse(color: SeptaskKitTheme.checkboxFill) }
    onToggle?()
  }

  // MARK: - Cue pulses

  /// The live ring, if one is mid-flight. Replaced rather than queued, so
  /// rapid checking never stacks motion (the SwiftUI feels have the same
  /// "ends at rest, nothing lingers" contract).
  private var pulseLayer: CAShapeLayer?

  /// One ring pulse from the box outward — the AppKit twin of `TaskCheckbox`'s
  /// `pulse(color:reach:)`, same numbers: 0.9 → `reach`, opacity 0.55 → 0,
  /// ease-out over 0.4s. `reach` is a multiple of the box; an ordinary check
  /// travels 1.9, a Today promote stays tighter at 1.6.
  ///
  /// A layer rather than `draw(_:)` because the ring has to leave the box's
  /// 22pt hit column, which a redraw inside `bounds` cannot do. `masksToBounds`
  /// is explicitly false for the same reason.
  func playPulse(color: NSColor, reach: CGFloat = 1.9) {
    guard !KitMotion.reduce else { return }
    wantsLayer = true
    layer?.masksToBounds = false
    pulseLayer?.removeFromSuperlayer()
    guard let host = layer else { return }

    let box = NSRect(x: (bounds.width - Self.boxSize) / 2,
                     y: (bounds.height - Self.boxSize) / 2,
                     width: Self.boxSize, height: Self.boxSize)
    let ring = CAShapeLayer()
    // Frame == bounds so the layer's own centre is the box's centre, which is
    // what makes `transform.scale` expand symmetrically around the box.
    ring.frame = bounds
    ring.path = CGPath(roundedRect: box, cornerWidth: Self.corner,
                       cornerHeight: Self.corner, transform: nil)
    ring.fillColor = nil
    effectiveAppearance.performAsCurrentDrawingAppearance {
      ring.strokeColor = color.cgColor
    }
    ring.lineWidth = Self.stroke
    ring.opacity = 0
    host.addSublayer(ring)
    pulseLayer = ring

    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.9
    scale.toValue = reach
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0.55
    fade.toValue = 0
    let group = CAAnimationGroup()
    group.animations = [scale, fade]
    group.duration = 0.4
    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
    ring.add(group, forKey: "pulse")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak ring, weak self] in
      ring?.removeFromSuperlayer()
      if self?.pulseLayer === ring { self?.pulseLayer = nil }
    }
  }

  /// The quiet amber ring for a task pinned to Today — SwiftUI's
  /// `playTodayPromotePulse()`, same colour and same tighter reach.
  func playTodayPromotePulse() {
    playPulse(color: SeptaskKitTheme.todayAccent, reach: 1.6)
  }

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
    guard !usesStandardBox else { return }

    let box = NSRect(x: (bounds.width - Self.boxSize) / 2,
                     y: (bounds.height - Self.boxSize) / 2,
                     width: Self.boxSize, height: Self.boxSize)
    if isDone {
      let path = NSBezierPath(roundedRect: box, xRadius: Self.corner, yRadius: Self.corner)
      SeptaskKitTheme.checkboxFill.setFill()
      path.fill()

      let check = NSBezierPath()
      check.lineWidth = 1.75
      check.lineCapStyle = .round
      check.lineJoinStyle = .round
      check.move(to: NSPoint(x: box.minX + box.width * 0.23, y: box.minY + box.height * 0.53))
      check.line(to: NSPoint(x: box.minX + box.width * 0.43, y: box.minY + box.height * 0.72))
      check.line(to: NSPoint(x: box.minX + box.width * 0.78, y: box.minY + box.height * 0.30))
      SeptaskKitTheme.checkboxCheck.setStroke()
      check.stroke()
      return
    }
    let inset = box.insetBy(dx: Self.stroke / 2, dy: Self.stroke / 2)
    let path = NSBezierPath(roundedRect: inset, xRadius: Self.corner, yRadius: Self.corner)
    path.lineWidth = Self.stroke
    if isDashed {
      // Unratified proposal — the readiness form from language v2.
      path.setLineDash([2.5, 2.0], count: 2, phase: 0)
    }
    SeptaskKitTheme.checkboxStroke.setStroke()
    path.stroke()
  }
}

/// Non-interactive overlay drawing the agent cue ring and unread-context corner
/// dot above `KitCheckboxView`'s standard checkbox control.
@MainActor
private final class KitCheckboxCueOverlay: NSView {
  var cornerDot = false
  var agentCue = false

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    let boxSize = KitCheckboxView.boxSize
    let corner: CGFloat = 3.5
    let box = NSRect(x: (bounds.width - boxSize) / 2,
                     y: (bounds.height - boxSize) / 2,
                     width: boxSize, height: boxSize)

    // Agent cue — a soft ring outside the box marking a fresh, unengaged
    // agent-created row. Clears when the row is acknowledged.
    if agentCue {
      let ring = NSBezierPath(roundedRect: box.insetBy(dx: -2.5, dy: -2.5),
                              xRadius: corner + 2, yRadius: corner + 2)
      ring.lineWidth = 1.4
      SeptaskKitTheme.todayAccent.withAlphaComponent(0.55).setStroke()
      ring.stroke()
    }

    // Unread-context dot, haloed so it reads on any row background.
    if cornerDot {
      let center = NSPoint(x: box.maxX + 1, y: box.minY - 1)
      let halo = NSRect(x: center.x - 3.4, y: center.y - 3.4, width: 6.8, height: 6.8)
      SeptaskKitTheme.cardSurface.setFill()
      NSBezierPath(ovalIn: halo).fill()
      let dot = NSRect(x: center.x - 2.1, y: center.y - 2.1, width: 4.2, height: 4.2)
      SeptaskKitTheme.todayAccent.setFill()
      NSBezierPath(ovalIn: dot).fill()
    }
  }
}

// MARK: - Chip

/// Non-interactive `NSGlassEffectView` backdrop for macOS 26/27 pills/chips so
/// clicks pass cleanly to the owning button or table row.
@MainActor
final class KitPassthroughGlassView: NSGlassEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A list-membership or status pill on a row (`☀ Today`, `# BFF`, `📁 Admin`)
/// — OS 26/27 frosted Liquid Glass capsule (falling back to solid `chipFill`
/// under Reduce Transparency).
@MainActor
final class KitChipView: NSView {
  private let glass = KitPassthroughGlassView()
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.masksToBounds = false

    glass.style = .regular
    glass.cornerRadius = 9
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)

    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.contentTintColor = SeptaskKitTheme.inkSecondary
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = SeptaskKitTheme.chip
    label.textColor = SeptaskKitTheme.inkSecondary
    label.lineBreakMode = .byTruncatingTail
    addSubview(icon)
    addSubview(label)
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 9),
      icon.heightAnchor.constraint(equalToConstant: 9),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      heightAnchor.constraint(equalToConstant: 18),
    ])
    syncGlass()
  }

  required init?(coder: NSCoder) { fatalError("KitChipView is code-only") }

  func configure(symbol: String, title: String) {
    var config = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
    config = config.applying(.init(paletteColors: [SeptaskKitTheme.inkSecondary]))
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    label.stringValue = title
    syncGlass()
  }

  /// A CGColor is a resolved snapshot, so the fill has to be re-resolved when
  /// the appearance flips (updateLayer only runs if the view opts in).
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    syncGlass()
  }

  private func syncGlass() {
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    glass.isHidden = reduce
    layer?.backgroundColor = reduce ? SeptaskKitTheme.chipFill.cgColor : NSColor.clear.cgColor
  }
}

/// The "→ Suggested" capsule — one tap files the row where the classifier
/// thinks it belongs (`TaskFilingSuggestions`). Same OS 26/27 frosted Liquid
/// Glass capsule as `KitChipView`.
@MainActor
final class KitSuggestionChipView: NSButton {
  var onApply: (() -> Void)?
  private let glass = KitPassthroughGlassView()

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 9
    isBordered = false
    setButtonType(.momentaryChange)
    // Keyboard focus stays on the table, same contract as the checkbox — this
    // must never become a Space-activated control on the selected row.
    refusesFirstResponder = true
    imagePosition = .imageLeading
    imageHugsTitle = true
    target = self
    action = #selector(fire)

    glass.style = .regular
    glass.cornerRadius = 9
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass, positioned: .below, relativeTo: nil)

    // An NSButton has no natural width in a `.fill` NSStackView — it absorbs
    // every spare point and the capsule stretched the whole row. `KitChipView`
    // never showed this because it is a plain NSView whose width falls out of
    // its label constraints; a control has to say it wants to hug.
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(equalToConstant: 18),
      // A long area name truncates rather than shoving the task title out of
      // the row — same contract as `KitChipView`'s truncating label.
      widthAnchor.constraint(lessThanOrEqualToConstant: 140),
    ])
    syncGlass()
  }

  required init?(coder: NSCoder) { fatalError("KitSuggestionChipView is code-only") }

  func configure(title: String) {
    var config = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
    config = config.applying(.init(paletteColors: [SeptaskKitTheme.inkSecondary]))
    image = NSImage(systemSymbolName: "arrow.turn.down.right",
                    accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    // `attributedTitle`, not `title`: a borderless NSButton paints its label
    // in the control's default color otherwise.
    attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: SeptaskKitTheme.chip,
        .foregroundColor: SeptaskKitTheme.inkSecondary,
      ])
    setAccessibilityLabel(String(localized: "File under \(title)",
                                 comment: "SeptaskKit: filing suggestion capsule"))
    syncGlass()
    window?.invalidateCursorRects(for: self)
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    syncGlass()
  }

  private func syncGlass() {
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    glass.isHidden = reduce
    layer?.backgroundColor = reduce ? SeptaskKitTheme.chipFill.cgColor : NSColor.clear.cgColor
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func accessibilityPerformPress() -> Bool {
    onApply?()
    return true
  }

  @objc private func fire() { onApply?() }
}

// MARK: - Borderless search field

/// A borderless `NSSearchField` that still lays its parts out correctly.
///
/// THE BUG THIS FIXES: `NSSearchFieldCell` derives the text rect from the
/// BEZEL, so `isBordered = false` collapses that geometry and the text starts
/// at x=0 — directly on top of the magnifying glass. Typing "vibe" into the
/// ⌘⇧M Move panel drew the word over the glyph.
///
/// Both panels want a large borderless field on a `.popover` material (no
/// search-box bezel), so the fix is to compute the three rects from `bounds`
/// explicitly rather than to restore a bezel we don't want. Overriding
/// `searchButtonRect` / `cancelButtonRect` / `searchTextRect` is the
/// documented customization point for exactly this — not a workaround.
///
/// Those three rects place the DRAWN text only. The field editor needs
/// `edit(withFrame:…)` / `select(withFrame:…)` as well, or the fix holds for
/// the placeholder and drops the moment the user types.
@MainActor
final class KitSearchFieldCell: NSSearchFieldCell {
  /// Square side reserved for each end control, and the gap between a control
  /// and the text. Sized off the type scale so the glyphs keep pace when the
  /// user changes text size.
  private var controlSide: CGFloat { max(18, (font?.pointSize ?? 16) + 4) }
  private let gap: CGFloat = 6

  private func centeredSquare(in rect: NSRect, atLeading: Bool) -> NSRect {
    let side = controlSide
    return NSRect(x: atLeading ? rect.minX : rect.maxX - side,
                  y: rect.midY - side / 2,
                  width: side, height: side)
  }

  override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
    centeredSquare(in: rect, atLeading: true)
  }

  override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
    // Only reserved once there is something to clear; otherwise the text may
    // run the full width.
    stringValue.isEmpty ? .zero : centeredSquare(in: rect, atLeading: false)
  }

  override func searchTextRect(forBounds rect: NSRect) -> NSRect {
    // Reserve BOTH ends always, even while the field is empty. The cancel
    // button appears the moment the first character lands, so a rect that only
    // reserved the trailing side once `stringValue` was non-empty made the text
    // rect change width mid-keystroke — and the field editor, whose frame is
    // set once when editing starts, kept the empty-field width and ran the last
    // characters under the cancel button.
    let inset = controlSide + gap
    return NSRect(x: rect.minX + inset, y: rect.minY,
                  width: max(0, rect.width - inset * 2),
                  height: rect.height)
  }

  // The rect overrides above place the DRAWN text. They do not place the FIELD
  // EDITOR, which is what you look at from the first keystroke on: AppKit sizes
  // that from the cell frame it is handed, so the typed string started at x=0
  // and ran over the magnifying glass while the placeholder above it sat
  // correctly inset. Hand the editor the same text rect the drawing path uses,
  // so the field reads identically before, during, and after editing.
  override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                     delegate: Any?, event: NSEvent?) {
    super.edit(withFrame: searchTextRect(forBounds: rect), in: controlView,
               editor: editor, delegate: delegate, event: event)
  }

  override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                       delegate: Any?, start: Int, length: Int) {
    super.select(withFrame: searchTextRect(forBounds: rect), in: controlView,
                 editor: editor, delegate: delegate, start: start, length: length)
  }
}

/// The borderless search field both floating panels use (⇧⌘F Quick Find and
/// ⌘⇧M Move). Exists so the two can't drift — they had identical setup and
/// therefore identical bugs.
@MainActor
final class KitSearchField: NSSearchField {
  override class var cellClass: AnyClass? {
    get { KitSearchFieldCell.self }
    set { super.cellClass = newValue }
  }

  /// The shared look: large type, no bezel, no focus ring, immediate results.
  /// Type comes from `KitSurface`, so a surface's field face is one number.
  func applyPanelStyle() {
    font = KitSurface.fieldFont
    isBordered = false
    drawsBackground = false
    focusRingType = .none
    sendsSearchStringImmediately = true
  }
}

// MARK: - Glyph images

/// Small cached images for the sidebar: the Reminders-style colored square
/// (`ColoredGlyph`), the project completion ring (`ProjectProgressIcon`), and
/// the area's muted dot (`SidebarAreaRow`).
@MainActor
enum KitGlyph {
  private static var cache: [String: NSImage] = [:]

  /// Bare SF Symbol centered in a square canvas — no background box.
  /// Drawn lazily inside `draw(size:)` so dynamic `NSColor`s re-resolve
  /// automatically when light/dark appearance flips; `cacheTag` distinguishes
  /// dynamic accent providers whose `.description` would otherwise collide.
  static func symbol(_ name: String, color: NSColor, cacheTag: String,
                     size: CGFloat = 18) -> NSImage? {
    let key = "s:\(name):\(cacheTag):\(size)"
    if let hit = cache[key] { return hit }
    guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return nil }
    let baseConfig = NSImage.SymbolConfiguration(pointSize: size * 0.68, weight: .semibold)
    let image = draw(size: NSSize(width: size, height: size)) { rect in
      let config = baseConfig.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
      guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
      else { return }
      let glyphSize = glyph.size
      let target = NSRect(x: rect.midX - glyphSize.width / 2,
                          y: rect.midY - glyphSize.height / 2,
                          width: glyphSize.width, height: glyphSize.height)
      glyph.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }
    cache[key] = image
    return image
  }

  /// `ColoredGlyph` — filled colored rounded square with a white SF Symbol.
  static func colored(symbol: String, color: NSColor, size: CGFloat = 17) -> NSImage? {
    let key = "c:\(symbol):\(color.description):\(size)"
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
    let key = "p:\(step):\(tint.description):\(diameter)"
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
    let key = "dot:\(diameter)"
    if let hit = cache[key] { return hit }
    let inset = diameter * (5.0 / 16)
    let image = draw(size: NSSize(width: diameter, height: diameter)) { rect in
      SeptaskKitTheme.iconMuted.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset)).fill()
    }
    cache[key] = image
    return image
  }

  /// Area emoji rendered into a square image so `NSButton` pills, inspector
  /// rows, and `NSMenuItem`s can show an area's custom emoji in the same
  /// leading icon slot as `areaDot` and `progress`.
  static func emoji(_ text: String, size: CGFloat = 15) -> NSImage {
    let key = "e:\(text):\(size)"
    if let hit = cache[key] { return hit }
    let image = draw(size: NSSize(width: size, height: size)) { rect in
      let attr = NSAttributedString(string: text,
                                    attributes: [.font: NSFont.systemFont(ofSize: size * 0.8)])
      let glyphSize = attr.size()
      attr.draw(at: NSPoint(x: rect.midX - glyphSize.width / 2,
                            y: rect.midY - glyphSize.height / 2))
    }
    image.isTemplate = false
    cache[key] = image
    return image
  }

  /// Canonical area glyph: the area's custom emoji when set, else the muted dot.
  static func area(emoji text: String?, diameter: CGFloat = 14) -> NSImage {
    if let text, !text.isEmpty {
      return emoji(text, size: diameter)
    }
    return areaDot(diameter: diameter)
  }

  /// Draws lazily, at display time, in the drawing view's effective appearance
  /// — the AppKit-documented way to build a custom image from dynamic
  /// `NSColor`s. AppKit re-invokes the handler when the hosting view's
  /// appearance changes, so a ring already on screen re-colors live.
  ///
  /// It used to `lockFocus` a bitmap under `NSApp.effectiveAppearance` and key
  /// the cache by that appearance name. That baked the colors at the moment of
  /// `configure`: the list reconfigures its cells on every data change, so it
  /// picked up the right ink soon after a switch, but the sidebar sets its row
  /// images only on a structure reload — its project rings kept the
  /// light-mode `secondaryLabelColor` (near-black) on the dark sidebar.
  private static func draw(size: NSSize, _ body: @escaping (NSRect) -> Void) -> NSImage {
    NSImage(size: size, flipped: false) { rect in
      body(rect)
      return true
    }
  }
}

// MARK: - Move destinations

/// The "Move to…" choices: no list, each area, then that area's projects, then
/// loose projects — sidebar order throughout (`StructureCache`). Built once
/// and shared by the context menu, the menu bar, and the ⌘M / ⌘⇧M popup so the
/// three can't drift.
@MainActor
enum KitMoveMenu {
  enum Destination: Equatable {
    case none
    case area(String)
    case project(String)
  }

  /// One row in the ⌘M / ⌘⇧M type-to-filter picker — areas AND projects, nested
  /// like SwiftUI `MovePickerSheet` (loose projects, then each area with its
  /// projects indented underneath).
  struct PickerRow {
    let title: String
    let target: Destination
    let emoji: String?
    /// Indent project rows that nest under an area.
    let indent: Bool
    /// Drives the project pie glyph; nil for area / Inbox rows.
    let projectId: String?
  }

  /// Full Move picker list — Inbox, loose projects, then each area with
  /// its active projects nested. Mirrors `MovePickerSheet`'s hierarchy.
  static func pickerDestinations(areas: [Area], projects: [Project]) -> [PickerRow] {
    let active = projects.filter { $0.status == .active }
    var rows: [PickerRow] = [
      PickerRow(title: TaskFilter.triage.title,
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
}

/// A table cell that draws the list's selection wash itself, on its own
/// fill, instead of relying on `KitCardRowView.drawBackground`.
@MainActor
protocol KitSelfSelectingCell: AnyObject {
  func rowNeedsRepaint()
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
/// Selection follows the card's shape, not the selection run: a row in the
/// middle of a card selects as a plain rectangle, the first row rounds only
/// its top, the last only its bottom, a lone row both. So a selection never
/// rounds a corner the card itself doesn't have, and neighbouring selected
/// rows always meet square.
@MainActor
final class KitCardRowView: NSTableRowView {
  /// Seed value other cells use for their leading/trailing constraint
  /// CONSTANTS at init — before their first `layout()` pass sweeps in the
  /// real width-dependent inset (`SeptaskKitLayout.inset(for:)`). Kept equal
  /// to the layout minimum so there's no visible jump on that first pass.
  static let horizontalInset: CGFloat = SeptaskKitLayout.minInset
  static let corner: CGFloat = 11

  /// A cell that paints its own selection (a standalone notice draws its
  /// fill on top of this row, so the row's wash would be hidden under it)
  /// repaints whenever the row does: selection, key-window and focus changes
  /// all reach the row as `needsDisplay = true`.
  override var needsDisplay: Bool {
    didSet {
      guard needsDisplay else { return }
      for case let cell as KitSelfSelectingCell in subviews { cell.rowNeedsRepaint() }
    }
  }

  var isCard = true { didSet { syncGlassBackdrop() } }
  var isFirstInGroup = true { didSet { syncGlassBackdrop() } }
  var isLastInGroup = true { didSet { syncGlassBackdrop() } }

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
  var isComposing = false { didSet { syncGlassBackdrop() } }

  /// A bare title field editor (⌘N / ⌘R) is live on this row. Same reason as
  /// `isComposing`: the wash behind an active text field reads as a selected
  /// cell with an input box dropped on it, and at a wide window the fill spans
  /// the whole card behind the caret. The composer path already dropped the
  /// wash; the field-editor path did not, so creating a task left you typing
  /// into a full-width blue band.
  var isEditingTitle = false { didSet { syncGlassBackdrop() } }

  /// Real hardware-accelerated frosted glass blur (`blendingMode = .withinWindow`)
  /// behind translucent task card slices when a Header Wash texture is active.
  private var glassBackdrop: NSVisualEffectView?
  private var glassMaskLayer: CAShapeLayer?
  private var glassOverlay: KitCardGlassOverlayView?

  private var usesGlassBackdrop: Bool {
    isCard
      && AppearancePreferences.shared.hasActiveTexture
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
      && !isComposing
  }

  func refreshAppearance() {
    syncGlassBackdrop()
    needsDisplay = true
  }

  private func ensureGlassBackdrop() {
    guard glassBackdrop == nil else { return }
    let effect = KitCardGlassStyle.makeBackdrop()
    let mask = CAShapeLayer()
    effect.layer?.mask = mask
    addSubview(effect, positioned: .below, relativeTo: nil)

    let overlay = KitCardGlassOverlayView()
    addSubview(overlay, positioned: .above, relativeTo: effect)

    glassBackdrop = effect
    glassMaskLayer = mask
    glassOverlay = overlay
  }

  private func syncGlassBackdrop() {
    let active = usesGlassBackdrop
    if active {
      ensureGlassBackdrop()
    }
    guard let effect = glassBackdrop, let mask = glassMaskLayer, let overlay = glassOverlay else {
      return
    }
    effect.isHidden = !active
    overlay.isHidden = !active
    guard active, bounds.width > 1, bounds.height > 1 else { return }

    let insetRect = bounds.insetBy(dx: SeptaskKitLayout.inset(for: bounds.width), dy: 0)
    effect.frame = insetRect
    // `NSVisualEffectView` is non-flipped (minY = bottom, maxY = top), so build
    // the slice mask in `effect.bounds` coordinates directly.
    let local = NSRect(origin: .zero, size: insetRect.size)
    let maskPath: NSBezierPath
    if !isFirstInGroup && !isLastInGroup {
      maskPath = NSBezierPath(rect: local)
    } else if isFirstInGroup && isLastInGroup {
      maskPath = NSBezierPath(roundedRect: local, xRadius: Self.corner, yRadius: Self.corner)
    } else {
      var r = local
      if !isLastInGroup {
        r.origin.y -= Self.corner
        r.size.height += Self.corner
      }
      if !isFirstInGroup {
        r.size.height += Self.corner
      }
      maskPath = NSBezierPath(roundedRect: r, xRadius: Self.corner, yRadius: Self.corner)
    }
    mask.frame = local
    mask.path = maskPath.cgPath

    overlay.frame = bounds
    overlay.slicePath = slicePath(roundTop: isFirstInGroup, roundBottom: isLastInGroup)
    overlay.isFirstInGroup = isFirstInGroup
    overlay.showSelection = isSelected && !isComposing && !isEditingTitle
    overlay.selectionEmphasized = septaskSelectionIsActive
    overlay.promoteWash = promoteWash
    overlay.needsDisplay = true
  }

  override func layout() {
    super.layout()
    syncGlassBackdrop()
    syncDropLine()
  }

  /// Insertion line while a task drag is hovering, on this row's `.top` or
  /// `.bottom` edge. Same bar as SwiftUI `TaskInsertionMark` — a position
  /// marker, not a row highlight, and not NSTableView's `.gap` feedback (that
  /// hole splits a per-row card into two).
  enum DropLine {
    case none, top, bottom
  }
  var dropLine: DropLine = .none {
    didSet { if oldValue != dropLine { syncDropLine() } }
  }

  /// A view above the cell, not a `drawBackground` pass: the glass backdrop
  /// and the cell would cover a drawn line.
  private var dropLineView: KitDropLineView?

  private func syncDropLine() {
    guard dropLine != .none else {
      dropLineView?.removeFromSuperview()
      return
    }
    let line = dropLineView ?? KitDropLineView()
    dropLineView = line
    if line.superview !== self { addSubview(line) }
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    let height = KitDropLineView.height
    line.frame = NSRect(x: inset, y: dropLine == .top ? 0 : bounds.height - height,
                        width: max(0, bounds.width - inset * 2), height: height)
  }

  /// Layer-backed tables paint a full-row selection fill that never goes
  /// through `drawSelection` — a second, rectangular highlight around the
  /// inset card. Selection is therefore drawn in `drawBackground` (same clip
  /// as the card) and `selectionHighlightStyle` is `.none` so AppKit's fill
  /// stays off. These overrides keep the wash in sync when focus moves.
  override var isSelected: Bool {
    get { super.isSelected }
    set { super.isSelected = newValue; syncGlassBackdrop(); needsDisplay = true }
  }
  override var isEmphasized: Bool {
    get { super.isEmphasized }
    set { super.isEmphasized = newValue; syncGlassBackdrop(); needsDisplay = true }
  }

  /// Selection emphasis is computed at draw time (`septaskSelectionIsActive`),
  /// so this row repaints when its window's key state flips.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    septaskObserveKeyWindow()
    syncGlassBackdrop()
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
      return
    }
    if usesGlassBackdrop {
      syncGlassBackdrop()
      return
    }
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: bounds).setClip()
    let slice = slicePath(roundTop: isFirstInGroup, roundBottom: isLastInGroup)
    SeptaskKitTheme.cardSurface.setFill()
    slice.fill()
    // Selection rides on the card (same clip, selection-run rounding) so it
    // cannot overhang as a second rectangle. Composer owns the surface.
    if isSelected && !isComposing && !isEditingTitle {
      SeptaskKitTheme.listSelectionFill(emphasized: septaskSelectionIsActive).setFill()
      slice.fill()
    }
    // Promote wash — SwiftUI's `playPromoteWash()`, same gold at the same
    // 0.22 peak, fading to nothing. It is NOT a second selection language:
    // it is transient (gone in ~0.45s), it is the app's temporal accent
    // rather than the selection token, and it never persists on a row.
    if promoteWash > 0 {
      SeptaskKitTheme.todayAccent.withAlphaComponent(promoteWash).setFill()
      slice.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  /// Current strength of the promote wash, 0 at rest.
  private var promoteWash: CGFloat = 0 { didSet { syncGlassBackdrop() } }
  private var promoteWashTimer: Timer?

  /// Play the one-shot gold wash for a task just pinned to Today. Stepped by a
  /// timer rather than a `CABasicAnimation` because this row draws itself in
  /// `drawBackground` — there is no layer property to animate.
  func playPromoteWash() {
    guard !KitMotion.reduce else { return }
    promoteWashTimer?.invalidate()
    promoteWash = 0.22
    needsDisplay = true
    let start = Date()
    let duration: TimeInterval = 0.45
    promoteWashTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
      MainActor.assumeIsolated {
        let progress = min(1, Date().timeIntervalSince(start) / duration)
        self.promoteWash = 0.22 * (1 - progress)
        self.needsDisplay = true
        if progress >= 1 {
          timer.invalidate()
          self.promoteWashTimer = nil
          self.promoteWash = 0
        }
      }
    }
  }

  /// Rows are reused, so a recycled row must not inherit a wash mid-flight.
  func cancelPromoteWash() {
    promoteWashTimer?.invalidate()
    promoteWashTimer = nil
    guard promoteWash != 0 else { return }
    promoteWash = 0
    needsDisplay = true
  }

  /// No-op: selection is painted in `drawBackground`. The table's
  /// `selectionHighlightStyle` is `.none`, so AppKit does not call this;
  /// kept empty so a style regression cannot restore the full-row fill.
  override func drawSelection(in dirtyRect: NSRect) {}

  /// Keep row content in its normal ink. AppKit flips cell text to white for
  /// an emphasized selection, which would be invisible on the neutral fill.
  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// The insertion bar of a task drag, the AppKit twin of SwiftUI's
/// `TaskInsertionMark`: same height, color and card-edge inset, flat like
/// every macOS card.
@MainActor
private final class KitDropLineView: NSView {
  static let height: CGFloat = 6

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    AppearancePreferences.shared.magicPlusNSColor.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
  }
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
  var extraTopMargin: CGFloat = 0 {
    didSet { if oldValue != extraTopMargin { needsLayout = true } }
  }

  /// The pill is a layer-backed subview at the bottom of the row view, not a
  /// drawing pass. With the outline's `selectionHighlightStyle` at `.none`
  /// (AppKit's own source-list selection flashed ink on the row being left
  /// and covered the area margin), a source-list row view runs neither
  /// `drawSelection` nor `drawBackground`, so drawn pills never showed. A
  /// subview always renders, under the cell.
  private let pill: NSView = {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.cornerRadius = 6
    view.layer?.cornerCurve = .continuous
    view.isHidden = true
    return view
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(pill, positioned: .below, relativeTo: nil)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    addSubview(pill, positioned: .below, relativeTo: nil)
  }

  /// See `KitCardRowView.viewDidMoveToWindow`.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    septaskObserveKeyWindow()
    refreshPill()
  }

  override var isSelected: Bool {
    get { super.isSelected }
    set { super.isSelected = newValue; refreshPill() }
  }
  override var isEmphasized: Bool {
    get { super.isEmphasized }
    set { super.isEmphasized = newValue; refreshPill() }
  }
  /// A task dragged ONTO this row (file into this list) gets the SAME pill as
  /// selection: one emphasis language on the sidebar, not the system's
  /// drop-target fill. The between-rows insertion line for reordering is
  /// separate and untouched.
  override var isTargetForDropOperation: Bool {
    get { super.isTargetForDropOperation }
    set { super.isTargetForDropOperation = newValue; refreshPill() }
  }
  /// Focus changes reach rows through `needsDisplay`
  /// (`septaskRefreshSelectionEmphasis`, the key-window observer), so the
  /// pill's emphasis follows that same signal.
  override var needsDisplay: Bool {
    didSet { if needsDisplay { refreshPill() } }
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshPill()
  }

  override func layout() {
    super.layout()
    pill.frame = pillRect
  }

  private func refreshPill() {
    let show = isSelected || isTargetForDropOperation
    pill.isHidden = !show
    guard show else { return }
    let emphasized = isTargetForDropOperation || septaskSelectionIsActive
    var color = SeptaskKitTheme.listSelectionFill(emphasized: emphasized).cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance {
      color = SeptaskKitTheme.listSelectionFill(emphasized: emphasized).cgColor
    }
    pill.layer?.backgroundColor = color
    pill.frame = pillRect
  }

  /// No-op: the pill subview shows selection.
  override func drawSelection(in dirtyRect: NSRect) {}
  /// No-op: the pill subview shows the drop target.
  override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {}

  /// The one pill rect both drawings use. It covers only the row's CONTENT
  /// band — `bounds` minus `extraTopMargin` — sitting at the BOTTOM of
  /// `bounds`, matching `SidebarCell`'s own bottom-anchored content (see its
  /// `contentBottomInset` comment). For a plain row (`extraTopMargin == 0`)
  /// this is just `bounds`, inset.
  private var pillRect: NSRect {
    let contentHeight = bounds.height - extraTopMargin
    // No vertical inset: neighbouring pills (selection, drop target) meet,
    // so a drag across the sidebar never crosses a dead gap.
    let verticalInset: CGFloat = 0
    // NSTableRowView is FLIPPED (minY is the row's visual TOP, not its
    // bottom) — the margin band is the first `extraTopMargin` points from
    // `minY`, so skipping it means starting the pill AFTER that, not at
    // `minY` itself. Getting this backwards is what put the pill floating
    // in the margin with the row's text sitting below it, outside the pill.
    return NSRect(x: bounds.minX + 8,
                  y: bounds.minY + extraTopMargin + verticalInset,
                  width: bounds.width - 16,
                  height: contentHeight - verticalInset * 2)
  }

  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Shared frosted-glass recipe for EVERY card surface in the AppKit task list
/// (grouped task cards in `KitCardRowView` and inline notices in
/// `KitNoticeFill`). One definition so notices and task cards never diverge in
/// material, veil opacity, or top specular rim — matching SwiftUI's unified
/// `TaskCardChrome` / `TaskListNotice` recipe.
@MainActor
enum KitCardGlassStyle {
  static let topRimHeight: CGFloat = 0.75

  static func makeBackdrop() -> KitPassthroughVisualEffectView {
    let effect = KitPassthroughVisualEffectView()
    effect.blendingMode = .withinWindow
    effect.state = .active
    effect.material = .headerView
    effect.wantsLayer = true
    return effect
  }

  static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
  }

  static func veilColor(isDark: Bool) -> NSColor {
    SeptaskKitTheme.cardSurface.withAlphaComponent(isDark ? 0.28 : 0.38)
  }

  static func topRimColor(isDark: Bool) -> NSColor {
    NSColor.white.withAlphaComponent(isDark ? 0.16 : 0.78)
  }
}

/// Non-interactive frosted `NSVisualEffectView` used behind task cards and
/// inline notices when a procedural Header Wash texture is active.
@MainActor
final class KitPassthroughVisualEffectView: NSVisualEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Translucent card veil, top specular glass rim, selection wash, and promote
/// flash drawn on top of `KitCardRowView`'s frosted `NSVisualEffectView` and
/// beneath the cell's text/controls.
@MainActor
private final class KitCardGlassOverlayView: NSView {
  var slicePath: NSBezierPath?
  var isFirstInGroup = false
  var showSelection = false
  var selectionEmphasized = false
  var promoteWash: CGFloat = 0

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let slice = slicePath else { return }
    let isDark = KitCardGlassStyle.isDark(effectiveAppearance)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: bounds).setClip()
    // Light frosted veil so the Header Wash frosts through legibly.
    KitCardGlassStyle.veilColor(isDark: isDark).setFill()
    slice.fill()
    if isFirstInGroup && !showSelection {
      NSGraphicsContext.saveGraphicsState()
      slice.addClip()
      let rim = NSRect(x: bounds.minX, y: bounds.minY,
                       width: bounds.width, height: KitCardGlassStyle.topRimHeight)
      KitCardGlassStyle.topRimColor(isDark: isDark).setFill()
      rim.fill()
      NSGraphicsContext.restoreGraphicsState()
    }
    if showSelection {
      SeptaskKitTheme.listSelectionFill(emphasized: selectionEmphasized).setFill()
      slice.fill()
    }
    if promoteWash > 0 {
      SeptaskKitTheme.todayAccent.withAlphaComponent(promoteWash).setFill()
      slice.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
  }
}
#endif
