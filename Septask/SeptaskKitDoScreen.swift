#if os(macOS)
import AppKit
import SwiftData

// The Do screen (docs/DO_SPEC.md §4): one task in place of the list, on the
// Mac where the user started it or chose Do Here. The task itself is the
// inspector's form on its `doScreen` placement, so the blocks, their writes
// and their undo are the inspector's own. This file adds the parts around it:
// where the user stopped last, the first step question, the time and the
// exits. The shell window swaps it in and out (`SeptaskKitWindowController`).
@MainActor
final class SeptaskKitDoScreenController: NSViewController {
  /// Later: the window opens the When popover at the button.
  var onLater: ((DoState, NSView) -> Void)?

  private static let columnWidth: CGFloat = 640

  private let inspector = SeptaskKitInspectorController(placement: .doScreen)
  private let lastTimeTitle = NSTextField(labelWithString: RegistryDoing.lastTimeTitle)
  private let lastTimeNote = NSTextField(wrappingLabelWithString: "")
  private let firstStepButton = NSButton()
  private let timeButton = NSButton()
  private lazy var doneButton = SeptaskKitDo.button(.doDone, target: self, action: #selector(donePressed))
  private lazy var stopButton = SeptaskKitDo.button(.doStop, target: self, action: #selector(stopPressed))
  private lazy var laterButton = SeptaskKitDo.button(.doLater, target: self, action: #selector(laterPressed))
  private lazy var showListButton = SeptaskKitDo.button(.doShowList, target: self, action: #selector(showListPressed))

  private var doing: DoState?
  private var isDiscussing = false
  private var observers: [NSObjectProtocol] = []

  private var context: ModelContext { LocalStore.shared.container.mainContext }

  // MARK: - View

  override func loadView() {
    let root = KitDoRootView()
    root.onCancel = { [weak self] in self?.cancel() }

    addChild(inspector)
    inspector.view.translatesAutoresizingMaskIntoConstraints = false
    // Esc, Return and ⌘↩ in a field save it and give the keyboard back to the
    // screen. Esc on the screen itself is Show List.
    inspector.onRequestFocusList = { [weak self] in self?.focus() }
    inspector.onRequestClose = { [weak self] in self?.cancel() }

    lastTimeTitle.font = SeptaskKitTheme.chip
    lastTimeTitle.textColor = SeptaskKitTheme.iconMuted
    lastTimeNote.font = SeptaskKitTheme.taskTitle
    lastTimeNote.textColor = SeptaskKitTheme.inkSecondary
    lastTimeNote.isSelectable = true
    inspector.leadStack.addArrangedSubview(lastTimeTitle)
    inspector.leadStack.addArrangedSubview(lastTimeNote)
    lastTimeNote.widthAnchor.constraint(equalTo: inspector.leadStack.widthAnchor).isActive = true

    firstStepButton.bezelStyle = .rounded
    firstStepButton.imagePosition = .imageLeading
    firstStepButton.image = NSImage(systemSymbolName: RegistrySurfaces.taskAttribute(.discuss).sfSymbol,
                                    accessibilityDescription: nil)
    firstStepButton.target = self
    firstStepButton.action = #selector(firstStepPressed)
    inspector.footStack.addArrangedSubview(firstStepButton)

    timeButton.isBordered = false
    timeButton.font = .monospacedDigitSystemFont(ofSize: SeptenaTypeScale.size(.title1), weight: .regular)
    timeButton.contentTintColor = SeptaskKitTheme.inkPrimary
    timeButton.target = self
    timeButton.action = #selector(timePressed)
    timeButton.refusesFirstResponder = true
    timeButton.toolTip = RegistryDoing.lengthTitle

    showListButton.isBordered = false
    showListButton.contentTintColor = SeptaskKitTheme.inkSecondary
    for button in [doneButton, stopButton, laterButton] { button.controlSize = .large }
    let exits = NSStackView(views: [doneButton, stopButton, laterButton])
    exits.spacing = 10
    let foot = NSStackView(views: [timeButton, exits, showListButton])
    foot.orientation = .vertical
    foot.alignment = .centerX
    foot.spacing = 14
    foot.translatesAutoresizingMaskIntoConstraints = false

    root.addSubview(inspector.view)
    root.addSubview(foot)
    let wide = inspector.view.widthAnchor.constraint(equalToConstant: Self.columnWidth)
    wide.priority = .defaultHigh
    NSLayoutConstraint.activate([
      // The title bar covers the top of a full-size content view.
      inspector.view.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor,
                                          constant: SeptaskKitLayout.titleBarGap),
      inspector.view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      inspector.view.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 10),
      inspector.view.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
      wide,
      foot.topAnchor.constraint(equalTo: inspector.view.bottomAnchor, constant: 12),
      foot.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      foot.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -SeptaskKitLayout.verticalInset),
    ])
    view = root

    observers.append(NotificationCenter.default.addObserver(
      forName: .septenaTasksChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: SeptaskKitDo.ticked, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshTime() }
    })
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  // MARK: - Content

  func show(_ doing: DoState) {
    loadViewIfNeeded()
    self.doing = doing
    inspector.show(LocalCache.task(id: doing.taskID, in: context))
    refreshAround()
    refreshTime()
  }

  private func refresh() {
    inspector.refresh()
    refreshAround()
  }

  /// The parts above and under the blocks.
  private func refreshAround() {
    guard let doing, let task = LocalCache.task(id: doing.taskID, in: context) else { return }
    let note = DoStore.shared.lastNote(taskID: doing.taskID)
    lastTimeNote.stringValue = note ?? ""
    inspector.leadStack.isHidden = note == nil

    // Only a task with nothing to start from gets the question. It never
    // blocks the start.
    let asks = OnDeviceAI.isAvailable && note == nil && (task.notes ?? "").isEmpty
      && !task.conversation.hasStarted
      && LocalCache.checklistItems(forTaskID: task.id, in: context).isEmpty
    firstStepButton.title = isDiscussing
      ? RegistrySurfaces.taskAttribute(.discuss).workingLabel ?? RegistryDoing.firstStepTitle
      : RegistryDoing.firstStepTitle
    firstStepButton.isEnabled = !isDiscussing
    inspector.footStack.isHidden = !asks
  }

  private func refreshTime() {
    guard let doing else { return }
    timeButton.title = SeptaskKitDo.timeText(doing)
    timeButton.setAccessibilityLabel("\(RegistryDoing.lengthTitle), \(timeButton.title)")
  }

  func flushPendingEdits() {
    guard isViewLoaded else { return }
    inspector.flushPendingEdits()
  }

  // MARK: - Keyboard

  func focus() { view.window?.makeFirstResponder(view) }

  func handleCommandReturn() -> Bool { inspector.handleCommandReturn() }

  /// Esc. In a text field that has no Esc of its own (a checklist step) it
  /// leaves the field first; on the screen it is Show List.
  private func cancel() {
    if view.window?.firstResponder is NSText {
      focus()
      return
    }
    showListPressed()
  }

  // MARK: - Actions

  @objc private func donePressed() {
    guard let doing else { return }
    SeptaskKitDo.shared.done(doing)
  }

  @objc private func stopPressed() {
    guard let doing else { return }
    flushPendingEdits()
    SeptaskKitDo.shared.stop(doing)
  }

  @objc private func laterPressed() { presentLater() }

  func presentLater() {
    guard let doing else { return }
    flushPendingEdits()
    onLater?(doing, laterButton)
  }

  @objc private func showListPressed() {
    flushPendingEdits()
    SeptaskKitDo.shared.showList()
  }

  /// Starts Discuss on the task, the same call as the composer's pill. The
  /// first turn then shows in the form.
  @objc private func firstStepPressed() {
    guard !isDiscussing, let doing,
          let task = LocalCache.task(id: doing.taskID, in: context) else { return }
    isDiscussing = true
    refreshAround()
    Task { @MainActor [weak self] in
      _ = await ConversationEngine.advance(task: task)
      self?.isDiscussing = false
      self?.refresh()
    }
  }

  /// The length: none, the registry's lengths, and the task's own duration.
  @objc private func timePressed() {
    guard let doing else { return }
    let own = LocalCache.task(id: doing.taskID, in: context)?.durationMinutes
    var lengths = RegistryDoing.lengths
    if let own, (1...RegistryEntityLimits.doPlannedMinutesMax).contains(own), !lengths.contains(own) {
      lengths.append(own)
    }
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(.sectionHeader(title: RegistryDoing.lengthTitle))
    let options: [(id: String, title: String, minutes: Int?)] =
      [("length.none", RegistryDoing.noLengthTitle, nil)]
        + lengths.map { ("length.\($0)", RegistryDoing.lengthOption(count: $0), Optional($0)) }
    for option in options {
      menu.addItem(KitClosureMenuItem(entry: RegistryMenuEntry(
        id: option.id, title: option.title, sfSymbol: nil,
        isOn: doing.plannedMinutes == option.minutes,
        perform: { Self.setLength(option.minutes, of: doing) })))
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: timeButton.bounds.maxY + 4), in: timeButton)
  }

  private static func setLength(_ minutes: Int?, of doing: DoState) {
    DoStore.shared.setLength(sessionID: doing.sessionID, minutes: minutes)
    // The alert at the end needs a permission. Only a length asks for it.
    if minutes != nil { Task { await DoEndAlert.requestAccess() } }
  }
}

/// The screen's page. It takes the keyboard, so Esc has a target when no
/// field is being edited.
@MainActor
private final class KitDoRootView: NSView {
  var onCancel: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    let backdrop = KitPageBackdropView()
    backdrop.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backdrop)
    NSLayoutConstraint.activate([
      backdrop.topAnchor.constraint(equalTo: topAnchor),
      backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
      backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitDoRootView is code-only") }

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      cancelOperation(nil)
    } else {
      super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) { onCancel?() }
}
#endif
