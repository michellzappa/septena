#if os(macOS)
import AppKit

/// Solid page-background host for the AppKit task list, sitting behind the
/// Header Wash and transparent `NSScrollView` so dark/light appearance switches
/// repaint live without stale cached `CGColor`s.
@MainActor
final class KitPageBackdropView: NSView {
  override var isOpaque: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    SeptaskKitTheme.pageBackground.setFill()
    dirtyRect.fill()
  }
}

/// AppKit procedural Header Wash view pinned to the top edge of the macOS task
/// list (behind the unified title bar and top task cards). See ADR 0019 and
/// `docs/CUSTOMIZATION_SPEC.md`.
///
/// Renders via the exact same `HeaderWashEngine` CoreGraphics renderer used on
/// iOS/iPadOS, with automatic 20fps `slowDrift` timer lifecycle that pauses
/// whenever the window loses key/visibility, Reduce Motion is enabled, or Low
/// Power Mode is active.
@MainActor
final class KitHeaderWashView: NSView {
  var projectID: String? = nil {
    didSet {
      guard oldValue != projectID else { return }
      needsDisplay = true
    }
  }

  var dayISO: String = SeptenaDate.today {
    didSet {
      guard oldValue != dayISO else { return }
      needsDisplay = true
    }
  }

  var fadeHeight: CGFloat = 235

  private var driftTimer: Timer?
  private var motionAnchor = Date()
  private var elapsedPhase: Double = 0
  private var observers: [NSObjectProtocol] = []

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    setAccessibilityElement(false)
    installObservers()
  }

  required init?(coder: NSCoder) { fatalError("KitHeaderWashView is code-only") }

  deinit {
    driftTimer?.invalidate()
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  func reloadConfig() {
    isHidden = !AppearancePreferences.shared.hasActiveTexture
    updateMotionTimer()
    needsDisplay = true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    isHidden = !AppearancePreferences.shared.hasActiveTexture
    updateMotionTimer()
    needsDisplay = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let prefs = AppearancePreferences.shared
    guard prefs.hasActiveTexture, bounds.width > 1, bounds.height > 1 else { return }
    guard let cg = NSGraphicsContext.current?.cgContext else { return }

    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
    let params = HeaderWashParams(
      style: prefs.canvasTexture,
      isDark: isDark,
      accent: prefs.accentRGB(isDark: isDark),
      intensity: prefs.textureIntensity,
      seed: AppearancePreferences.resolvedSeed(dayISO: dayISO, projectID: projectID),
      phase: shouldAnimate ? elapsedPhase : 0,
      fadeHeight: fadeHeight,
      mini: false,
      increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    )
    HeaderWashEngine.draw(in: cg, size: bounds.size, params: params)
  }

  // MARK: - Motion Lifecycle

  private var shouldAnimate: Bool {
    guard AppearancePreferences.shared.isSlowDrift else { return false }
    guard let window, window.isVisible, window.occlusionState.contains(.visible) else { return false }
    guard window.isKeyWindow || NSApp.isActive else { return false }
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
    guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
    return true
  }

  private func updateMotionTimer() {
    if shouldAnimate {
      guard driftTimer == nil else { return }
      motionAnchor = Date().addingTimeInterval(-elapsedPhase)
      let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          guard self.shouldAnimate else {
            self.stopTimer()
            return
          }
          self.elapsedPhase = max(0, Date().timeIntervalSince(self.motionAnchor))
          self.needsDisplay = true
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      driftTimer = timer
    } else {
      stopTimer()
      if !AppearancePreferences.shared.isSlowDrift {
        elapsedPhase = 0
      }
    }
  }

  private func stopTimer() {
    driftTimer?.invalidate()
    driftTimer = nil
  }

  private func installObservers() {
    let nc = NotificationCenter.default
    for name in [
      Notification.Name.septenaAppearanceChanged,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didChangeOcclusionStateNotification,
      NSApplication.didBecomeActiveNotification,
      NSApplication.didResignActiveNotification,
      .NSProcessInfoPowerStateDidChange,
    ] {
      observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.reloadConfig() }
      })
    }
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reloadConfig() }
    })
  }
}
#endif
