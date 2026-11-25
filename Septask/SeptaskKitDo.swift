#if os(macOS)
import AppKit
import SwiftData

// Do in the AppKit shell (docs/DO_SPEC.md §4, §5, ADR 0041). `DoStore` owns
// the state and every write. This file owns what the Mac surfaces share: one
// observation of the store, one minute clock, the gestures and their menu,
// and the "Where did you stop?" panel. The Do screen
// (SeptaskKitDoScreen.swift), the notice row (SeptaskKitTaskList.swift),
// the menu bar item (SeptaskKitDoStatusItem.swift) and the floating panel
// (SeptaskKitDoFloat.swift) all read from here.
@MainActor
final class SeptaskKitDo {
  static let shared = SeptaskKitDo()

  /// The current Do, or where it shows, changed.
  static let changed = Notification.Name("septaskKit.do.changed")
  /// The minute a surface shows changed.
  static let ticked = Notification.Name("septaskKit.do.ticked")

  /// Agent requests that came in while the last Do was open: the one line
  /// after an exit. 0 when there is nothing to say.
  private(set) var requestCount = 0

  private var started = false
  private var last: DoState?
  private var tickWork: DispatchWorkItem?

  private var context: ModelContext { LocalStore.shared.container.mainContext }

  /// Called before the shell window opens, so a Do that was open at the last
  /// quit shows in the first frame. Idempotent.
  func start() {
    guard !started else { return }
    started = true
    DoStore.shared.start()
    last = DoStore.shared.current
    observe()
    scheduleTick()
    SeptaskKitDoStatusItem.shared.sync()
    SeptaskKitDoFloat.shared.start()
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        DoStore.shared.refresh()
        self?.tick()
      }
    }
  }

  // MARK: - Observation

  /// `@Observable` drives SwiftUI by itself but not AppKit: re-arm a one-shot
  /// observation after each change and post for the AppKit surfaces.
  private func observe() {
    withObservationTracking {
      _ = DoStore.shared.current
      _ = DoStore.shared.isFullHere
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.observe()
        self?.storeChanged()
      }
    }
  }

  private func storeChanged() {
    let next = DoStore.shared.current
    if next != nil {
      requestCount = 0
    } else if let ended = last, !ended.isStale {
      requestCount = agentRequests(since: ended.startedAt)
    }
    last = next
    scheduleTick()
    SeptaskKitDoStatusItem.shared.sync()
    SeptaskKitDoFloat.shared.sync()
    NotificationCenter.default.post(name: Self.changed, object: nil)
  }

  /// Review rows and open agent questions that came in since `start`. A
  /// question from the model on this device is the user's own Discuss, not an
  /// agent request.
  private func agentRequests(since start: Date) -> Int {
    LocalCache.liveAggregateEntities(in: context).filter { task in
      guard task.status == .open, !task.isFaded, task.conversationJSON != nil else { return false }
      let convo = task.conversation
      if convo.needsHumanReview { return (convo.endStateAt ?? .distantPast) >= start }
      guard convo.hasOpenProviderQuestion, let question = convo.thread.last,
            question.provider != .onDevice else { return false }
      return question.ts >= start
    }.count
  }

  func clearRequests() {
    guard requestCount > 0 else { return }
    requestCount = 0
    NotificationCenter.default.post(name: Self.changed, object: nil)
  }

  // MARK: - Clock

  /// The time of a Do, in whole minutes. A session runs on the wall clock,
  /// not on the app's day.
  static func timeText(_ doing: DoState) -> String { doing.timeText(at: Date()) }

  /// One wake at the next whole minute of the Do. The wall clock keeps it
  /// right across sleep.
  private func scheduleTick() {
    tickWork?.cancel()
    tickWork = nil
    guard let doing = DoStore.shared.current, !doing.isStale else { return }
    let elapsed = Date().timeIntervalSince(doing.startedAt)
    let wait = 60 - elapsed.truncatingRemainder(dividingBy: 60) + 0.1
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.tick() }
    }
    tickWork = work
    DispatchQueue.main.asyncAfter(wallDeadline: .now() + wait, execute: work)
  }

  private func tick() {
    scheduleTick()
    SeptaskKitDoStatusItem.shared.sync()
    SeptaskKitDoFloat.shared.sync()
    NotificationCenter.default.post(name: Self.ticked, object: nil)
  }

  // MARK: - Gestures
  //
  // Each one takes the Do it acts on, so a menu that stayed open across a
  // replace never ends the newer Do.

  func begin(taskID: String) { DoStore.shared.begin(taskID: taskID) }

  /// The existing complete gesture: the list's, with its undo and settle
  /// beat, or the shared recorder when no shell window is open.
  func done(_ doing: DoState) {
    guard let task = LocalCache.task(id: doing.taskID, in: context), task.status == .open else { return }
    if let shell = SeptaskKitWindowController.existing {
      shell.completeDoing(task)
      return
    }
    let mutator = SeptenaServices.shared.taskMutator
    TaskUndo.recordCompletion(ids: [task.id], wasDone: false, mutator: mutator)
    mutator.complete(id: task.id)
    mutator.acknowledge(id: task.id)
  }

  func stop(_ doing: DoState) {
    DoStore.shared.stop(sessionID: doing.sessionID)
    guard DoStore.shared.justStoppedSessionID == doing.sessionID else { return }
    SeptaskKitStopNote.shared.present(sessionID: doing.sessionID)
  }

  /// Opens the When popover in the shell window. Only a saved date ends the
  /// Do (§2.3).
  func later(_ doing: DoState) {
    showShell()
    // Next run-loop turn: a window that just opened has laid out by then.
    DispatchQueue.main.async { SeptaskKitWindowController.existing?.presentDoLater(doing) }
  }

  func showHere() {
    DoStore.shared.showHere()
    showShell()
  }

  func showList() {
    DoStore.shared.showList()
    showShell()
  }

  func showShell() {
    NSApp.activate(ignoringOtherApps: true)
    SeptaskKitWindowController.show()
  }

  // MARK: - Menu

  /// What a click on the notice and the menu bar item offer. Done and Do are
  /// never next to each other (§3).
  func menu(for doing: DoState) -> NSMenu {
    let place: RegistryActionID = DoStore.shared.isFullHere ? .doShowList : .doHere
    let groups: [[RegistryActionID]] = doing.isStale
      ? [[.doDone, .doStop], [.doConfirm]]
      : [[.doDone, .doStop, .doLater], [place]]
    return KitRegistryMenu.build(Self.items(groups)) { [weak self] id in
      guard let self else { return nil }
      switch id {
      case .doDone: return .init { self.done(doing) }
      case .doStop: return .init { self.stop(doing) }
      case .doLater: return .init { self.later(doing) }
      case .doHere: return .init { self.showHere() }
      case .doShowList: return .init { self.showList() }
      case .doConfirm: return .init { DoStore.shared.confirm(sessionID: doing.sessionID) }
      default: return nil
      }
    }
  }

  /// Registry actions as menu items, with a divider between groups. The
  /// resolver takes titles, icons and gating from the registry.
  private static func items(_ groups: [[RegistryActionID]]) -> [RegistryMenuItem] {
    groups.enumerated().flatMap { index, ids in
      let divider = RegistryMenuItem(kind: "divider", id: "do.divider", actionId: nil,
                                     title: nil, sfSymbol: nil, items: [])
      return (index == 0 ? [] : [divider]) + ids.map { id in
        RegistryMenuItem(kind: "action", id: id.rawValue, actionId: id, title: nil,
                         sfSymbol: RegistryActions.sfSymbols[id], items: [])
      }
    }
  }

  /// A button that shows an action's registry title and icon.
  static func button(_ id: RegistryActionID, target: AnyObject, action: Selector) -> NSButton {
    let title = RegistryActions.title(id)
    let button = NSButton(title: title, target: target, action: action)
    button.image = RegistryActions.sfSymbols[id].flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: nil)
    }
    button.imagePosition = .imageLeading
    button.bezelStyle = .push
    button.refusesFirstResponder = true
    return button
  }
}

// MARK: - Notice

/// A Do line in the list's notice slot (`KitNoticeCell`).
enum KitDoNotice: Equatable {
  /// Another device shows the Do, or this one after Show List.
  case doing(DoState, time: String)
  /// The Do is stale: ask once.
  case stale(DoState)
  /// A Do ended, and agents asked for something meanwhile.
  case requests(Int)

  @MainActor
  static func current() -> [KitDoNotice] {
    let store = DoStore.shared
    var out: [KitDoNotice] = []
    if store.showsNotice, let doing = store.current {
      out.append(doing.isStale ? .stale(doing) : .doing(doing, time: SeptaskKitDo.timeText(doing)))
    }
    let requests = SeptaskKitDo.shared.requestCount
    if requests > 0 { out.append(.requests(requests)) }
    return out
  }

  var key: String {
    switch self {
    case .doing, .stale: return "notice:do"
    case .requests: return "notice:do-requests"
    }
  }

  var state: DoState? {
    switch self {
    case .doing(let doing, _), .stale(let doing): return doing
    case .requests: return nil
    }
  }

  var title: String {
    switch self {
    case .doing(let doing, _): return RegistryDoing.notice(title: doing.title)
    case .stale(let doing): return RegistryDoing.stale(title: doing.title)
    case .requests(let count): return RegistryDoing.needsYou(count: count)
    }
  }

  var notice: KitNotice {
    switch self {
    case .doing(_, let time):
      return KitNotice(kind: .info, symbol: RegistryIcons.sfSymbol(for: "action.do"), title: title,
                       trailing: time, dismissible: false, pressable: true)
    case .stale:
      return KitNotice(kind: .info, symbol: RegistryIcons.sfSymbol(for: "action.do"), title: title,
                       dismissible: false, pressable: true)
    case .requests:
      return KitNotice(kind: .info, symbol: RegistryIcons.sfSymbol(for: "list.review"), title: title,
                       dismissible: true, pressable: true)
    }
  }
}

// MARK: - Stop note

/// "Where did you stop?" after Stop for Now: one optional field. A TIER 2
/// surface (SeptaskKitSurface.swift): the Do screen, the notice and the menu
/// bar item all open it, so it has no row to anchor to. Return and Save write
/// the note, Esc and Skip close it. A click elsewhere accepts what is typed,
/// the close-commits contract.
@MainActor
private final class SeptaskKitStopNote: NSObject, NSTextFieldDelegate, NSWindowDelegate {
  static let shared = SeptaskKitStopNote()

  private var panel: KitSurfacePanel?
  private let field = NSTextField()
  private var sessionID: String?

  func present(sessionID: String) {
    save()
    let panel = ensurePanel()
    self.sessionID = sessionID
    field.stringValue = ""
    if NSApp.isActive, NSApp.keyWindow != nil {
      panel.centerOverKeyWindow()
    } else if let frame = NSScreen.main?.visibleFrame {
      panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                   y: frame.minY + frame.height * 0.62))
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(field)
  }

  private func ensurePanel() -> KitSurfacePanel {
    if let panel { return panel }
    field.placeholderString = RegistryDoing.stopNoteTitle
    field.setAccessibilityLabel(RegistryDoing.stopNoteTitle)
    field.font = KitSurface.fieldFont
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false

    let skip = NSButton(title: RegistryDoing.stopNoteSkipTitle, target: self, action: #selector(skipPressed))
    let save = NSButton(title: RegistryDoing.stopNoteSaveTitle, target: self, action: #selector(savePressed))
    for button in [skip, save] {
      button.bezelStyle = .push
      button.refusesFirstResponder = true
    }
    let buttons = NSStackView(views: [skip, save])
    buttons.translatesAutoresizingMaskIntoConstraints = false

    let body = NSView()
    body.addSubview(field)
    body.addSubview(buttons)
    let inset = KitSurface.listInset + 2
    NSLayoutConstraint.activate([
      field.topAnchor.constraint(equalTo: body.topAnchor, constant: 16),
      field.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: inset),
      field.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -inset),
      buttons.topAnchor.constraint(greaterThanOrEqualTo: field.bottomAnchor, constant: 12),
      buttons.trailingAnchor.constraint(equalTo: field.trailingAnchor),
      buttons.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -14),
    ])

    let panel = KitSurfacePanel.make(size: NSSize(width: 480, height: 100),
                                     a11yTitle: RegistryDoing.stopNoteTitle)
    panel.install(body)
    panel.delegate = self
    panel.onCommandReturn = { [weak self] in self?.save() }
    self.panel = panel
    return panel
  }

  private func save() {
    guard let id = sessionID else { return }
    sessionID = nil
    panel?.orderOut(nil)
    DoStore.shared.setNote(sessionID: id, field.stringValue)
  }

  private func skip() {
    guard sessionID != nil else { return }
    sessionID = nil
    panel?.orderOut(nil)
    DoStore.shared.dismissStopNote()
  }

  @objc private func savePressed() { save() }
  @objc private func skipPressed() { skip() }

  func controlTextDidChange(_ obj: Notification) {
    field.septaskFlattenPastedLineBreaks()
  }

  func control(_ control: NSControl, textView: NSTextView,
               doCommandBy commandSelector: Selector) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)): save(); return true
    case #selector(NSResponder.cancelOperation(_:)): skip(); return true
    default: return false
    }
  }

  func windowDidResignKey(_ notification: Notification) { save() }
}
#endif
