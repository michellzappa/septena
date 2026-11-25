#if os(macOS)
import AppKit

// The floating Do of the Mac (docs/DO_SPEC.md §4.2): a small panel over the
// other apps while Septena is not the active app and this Mac shows the Do
// screen. A click opens the Do screen, a drag moves the panel, and a right
// click has the Do menu.
@MainActor
final class SeptaskKitDoFloat {
  static let shared = SeptaskKitDoFloat()

  private static let frameName = "septaskKit.do.float"
  private static let size = NSSize(width: 260, height: 48)

  private var panel: KitSurfacePanel?
  private let titleLabel = NSTextField(labelWithString: "")
  private let timeLabel = NSTextField(labelWithString: "")

  func start() {
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.sync() }
      }
    }
    sync()
  }

  func sync() {
    guard let doing = DoStore.shared.current, DoStore.shared.isFullHere, !NSApp.isActive else {
      panel?.orderOut(nil)
      return
    }
    let panel = ensurePanel()
    let time = SeptaskKitDo.timeText(doing)
    titleLabel.stringValue = doing.title
    timeLabel.stringValue = time
    panel.contentView?.setAccessibilityLabel("\(RegistryDoing.notice(title: doing.title)), \(time)")
    if !panel.isVisible { panel.orderFrontRegardless() }
  }

  private func ensurePanel() -> KitSurfacePanel {
    if let panel { return panel }
    let icon = NSImageView(image: NSImage(systemSymbolName: RegistryIcons.sfSymbol(for: "action.do"),
                                          accessibilityDescription: nil) ?? NSImage())
    titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    timeLabel.textColor = .secondaryLabelColor
    timeLabel.setContentHuggingPriority(.required, for: .horizontal)
    icon.setContentHuggingPriority(.required, for: .horizontal)

    let row = NSStackView(views: [icon, titleLabel, timeLabel])
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
    let body = SeptaskKitDoFloatView()
    row.translatesAutoresizingMaskIntoConstraints = false
    body.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      row.centerYAnchor.constraint(equalTo: body.centerYAnchor),
    ])

    let panel = KitSurfacePanel.make(size: Self.size, a11yTitle: RegistryActions.title(.taskDo))
    panel.install(body)
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    if !panel.setFrameUsingName(Self.frameName), let screen = NSScreen.main?.visibleFrame {
      panel.setFrameOrigin(NSPoint(x: screen.maxX - Self.size.width - 20, y: screen.minY + 20))
    }
    panel.setFrameAutosaveName(Self.frameName)
    self.panel = panel
    return panel
  }
}

/// The whole panel is one control: its labels never take the mouse.
private final class SeptaskKitDoFloatView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityPerformPress() -> Bool {
    SeptaskKitDo.shared.showHere()
    return true
  }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    let origin = window.frame.origin
    window.performDrag(with: event)
    if window.frame.origin == origin { SeptaskKitDo.shared.showHere() }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    DoStore.shared.current.map { SeptaskKitDo.shared.menu(for: $0) }
  }
}
#endif
