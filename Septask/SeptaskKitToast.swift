#if os(macOS)
import AppKit

// Bottom glass-capsule toast for the AppKit shell (DesignSpec §6.5).
//
// Consumes the SAME `SeptenaToast` / `SeptenaToastStore` contract as SwiftUI's
// `.septenaToastOverlay` (Septena/Shell/UI/Accessibility.swift) — one payload
// type, one 7 s auto-dismiss timer, one copy source. A new toast always
// replaces the current one in place (never stacks); Reduce Motion collapses
// the slide/fade to an instant show/hide.

/// Observes a `SeptenaToastStore` and renders its active toast as a single
/// bottom glass capsule inside a host container view.
@MainActor
final class SeptaskKitToastPresenter {
  let store: SeptenaToastStore

  private weak var container: NSView?
  private let capsule = KitToastCapsuleView()
  private var bottomConstraint: NSLayoutConstraint?
  private var observers: [NSObjectProtocol] = []
  private var isObserving = false
  private var presentedID: UUID?
  private var transitionGeneration = 0

  /// Resting distance from the container's bottom edge (matches SwiftUI's
  /// `.padding(.bottom, 16)`).
  private static let visibleBottomInset: CGFloat = -16
  /// Slight downward slide offset when entering/exiting (ignored under Reduce
  /// Motion).
  private static let hiddenBottomOffset: CGFloat = 12
  private static let enterDuration: TimeInterval = 0.22
  private static let exitDuration: TimeInterval = 0.16

  init(store: SeptenaToastStore) {
    self.store = store
    capsule.onUndo = { [weak self] in
      self?.store.performUndo()
    }
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  /// Install the single capsule view at the bottom center of `hostView` and
  /// start following `store.current`.
  func attach(to hostView: NSView) {
    container = hostView
    capsule.translatesAutoresizingMaskIntoConstraints = false
    capsule.isHidden = true
    capsule.alphaValue = 0
    hostView.addSubview(capsule)

    let bottom = capsule.bottomAnchor.constraint(
      equalTo: hostView.bottomAnchor,
      constant: Self.visibleBottomInset
    )
    bottomConstraint = bottom

    NSLayoutConstraint.activate([
      capsule.centerXAnchor.constraint(equalTo: hostView.centerXAnchor),
      capsule.leadingAnchor.constraint(greaterThanOrEqualTo: hostView.leadingAnchor, constant: 20),
      capsule.trailingAnchor.constraint(lessThanOrEqualTo: hostView.trailingAnchor, constant: -20),
      capsule.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
      bottom,
    ])

    if !isObserving {
      isObserving = true
      observeStore()
      installObservers()
    }
    syncWithStore()
  }

  /// Keep the capsule above newly inserted detail subviews (e.g. when the
  /// detail pane swaps between the task list and Next).
  func bringToFront() {
    guard let container, capsule.superview === container else { return }
    container.addSubview(capsule, positioned: .above, relativeTo: nil)
  }

  private func installObservers() {
    observers.append(NotificationCenter.default.addObserver(
      forName: .septenaTextSizeDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.capsule.refreshFonts() }
    })
    // If the user presses ⌘Z while an undoable toast is visible, they already
    // undid the action — dismiss the toast so its Undo button cannot undo a
    // second, unrelated entry off the stack.
    observers.append(NotificationCenter.default.addObserver(
      forName: .NSUndoManagerDidUndoChange, object: TaskUndo.manager, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.store.current?.undo != nil else { return }
        self.store.dismiss()
      }
    })
  }

  private func observeStore() {
    withObservationTracking {
      _ = store.current?.id
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.observeStore()
        self.syncWithStore()
      }
    }
  }

  private func syncWithStore() {
    guard let toast = store.current else {
      hideCapsule()
      return
    }
    showCapsule(for: toast)
  }

  private func showCapsule(for toast: SeptenaToast) {
    let wasVisible = !capsule.isHidden && presentedID != nil
    presentedID = toast.id
    transitionGeneration += 1
    capsule.configure(message: toast.message, hasUndo: toast.undo != nil)
    bringToFront()

    if wasVisible || KitMotion.reduce {
      // Replace in place (never stack), or jump straight to resting state
      // under Reduce Motion.
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0
        self.bottomConstraint?.constant = Self.visibleBottomInset
        self.capsule.alphaValue = 1
      }
      capsule.isHidden = false
      container?.layoutSubtreeIfNeeded()
      return
    }

    // Start slightly below resting position and transparent, then glide up.
    bottomConstraint?.constant = Self.hiddenBottomOffset
    capsule.alphaValue = 0
    capsule.isHidden = false
    container?.layoutSubtreeIfNeeded()

    let generation = transitionGeneration
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = Self.enterDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      ctx.allowsImplicitAnimation = true
      self.bottomConstraint?.animator().constant = Self.visibleBottomInset
      self.capsule.animator().alphaValue = 1
    }, completionHandler: {
      Task { @MainActor [weak self] in
        guard let self, self.transitionGeneration == generation else { return }
        self.capsule.alphaValue = 1
      }
    })
  }

  private func hideCapsule() {
    guard !capsule.isHidden else {
      presentedID = nil
      return
    }
    presentedID = nil
    transitionGeneration += 1
    let generation = transitionGeneration

    if KitMotion.reduce {
      capsule.alphaValue = 0
      capsule.isHidden = true
      bottomConstraint?.constant = Self.visibleBottomInset
      return
    }

    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = Self.exitDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
      ctx.allowsImplicitAnimation = true
      self.bottomConstraint?.animator().constant = Self.hiddenBottomOffset
      self.capsule.animator().alphaValue = 0
    }, completionHandler: {
      Task { @MainActor [weak self] in
        guard let self, self.transitionGeneration == generation else { return }
        self.capsule.isHidden = true
        self.bottomConstraint?.constant = Self.visibleBottomInset
      }
    })
  }
}

/// The frosted glass capsule itself: single-line message + optional Undo button,
/// built over the shell's shared `KitSurface.backdrop` material.
@MainActor
private final class KitToastCapsuleView: NSView {
  var onUndo: (() -> Void)?

  private let backdrop: NSVisualEffectView
  private let stack = NSStackView()
  private let messageLabel = NSTextField(labelWithString: "")
  private let undoButton = NSButton()

  override init(frame frameRect: NSRect) {
    backdrop = KitSurface.backdrop(radius: 18)
    super.init(frame: frameRect)

    wantsLayer = true
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowRadius = 12
    layer?.shadowOffset = CGSize(width: 0, height: -2)
    layer?.masksToBounds = false

    // `.withinWindow` frosts over the scrolling task rows beneath the capsule.
    backdrop.blendingMode = .withinWindow
    backdrop.translatesAutoresizingMaskIntoConstraints = false
    backdrop.layer?.borderWidth = 0.5
    addSubview(backdrop)

    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    messageLabel.textColor = SeptaskKitTheme.inkPrimary
    messageLabel.lineBreakMode = .byTruncatingTail
    messageLabel.maximumNumberOfLines = 1
    messageLabel.usesSingleLineMode = true
    messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    messageLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

    undoButton.translatesAutoresizingMaskIntoConstraints = false
    undoButton.isBordered = false
    undoButton.setButtonType(.momentaryChange)
    // Never steal keyboard focus from the task list when clicked.
    undoButton.refusesFirstResponder = true
    undoButton.target = self
    undoButton.action = #selector(fireUndo)
    undoButton.setContentHuggingPriority(.required, for: .horizontal)
    undoButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    undoButton.setAccessibilityLabel(String(localized: "Undo", comment: "Toast: undo button"))

    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 14
    stack.addArrangedSubview(messageLabel)
    stack.addArrangedSubview(undoButton)
    backdrop.addSubview(stack)

    NSLayoutConstraint.activate([
      backdrop.topAnchor.constraint(equalTo: topAnchor),
      backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
      backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 11),
      stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -11),
      stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -20),
    ])

    refreshFonts()
    updateAppearance()
  }

  required init?(coder: NSCoder) { fatalError("KitToastCapsuleView is code-only") }

  override func layout() {
    super.layout()
    let radius = min(backdrop.bounds.height / 2, backdrop.bounds.width / 2)
    backdrop.layer?.cornerRadius = radius
    backdrop.layer?.cornerCurve = .continuous
    if radius > 0, !bounds.isEmpty {
      layer?.shadowPath = CGPath(
        roundedRect: bounds,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
      )
    } else {
      layer?.shadowPath = nil
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
    refreshUndoTitle()
  }

  func configure(message: String, hasUndo: Bool) {
    messageLabel.stringValue = message
    undoButton.isHidden = !hasUndo
  }

  func refreshFonts() {
    messageLabel.font = SeptaskKitTheme.toastMessage
    refreshUndoTitle()
  }

  private func refreshUndoTitle() {
    let title = String(localized: "Undo", comment: "Toast: undo button")
    undoButton.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: SeptaskKitTheme.toastAction,
        .foregroundColor: SeptaskKitTheme.inkPrimary,
      ]
    )
  }

  private func updateAppearance() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
      let rim = isDark
        ? NSColor.white.withAlphaComponent(0.14)
        : NSColor.black.withAlphaComponent(0.08)
      backdrop.layer?.borderColor = rim.cgColor
      layer?.shadowOpacity = isDark ? 0.36 : 0.14
    }
  }

  @objc private func fireUndo() {
    onUndo?()
  }
}
#endif
