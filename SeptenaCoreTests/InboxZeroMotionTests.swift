import XCTest

final class InboxZeroMotionTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "com.septena.tests.inboxZeroMotion.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  // MARK: - Setting default & storage key (§7)

  func testSettingDefaultsTrueAndHonorsStoredValue() {
    XCTAssertEqual(RegistrySettings.StorageKey.inboxZeroMotionEnabled, "septena.ui.inboxZeroMotion")
    XCTAssertEqual(InboxZeroMotion.lastPlayedDayKey, "septena.ui.inboxZeroMotionLastDay")
    XCTAssertTrue(InboxZeroMotion.isEnabled(in: defaults))

    defaults.set(false, forKey: RegistrySettings.StorageKey.inboxZeroMotionEnabled)
    XCTAssertFalse(InboxZeroMotion.isEnabled(in: defaults))

    defaults.set(true, forKey: RegistrySettings.StorageKey.inboxZeroMotionEnabled)
    XCTAssertTrue(InboxZeroMotion.isEnabled(in: defaults))
  }

  // MARK: - Trigger conditions (§2)

  func testFiresOnTodayWhenUserGestureEmptiesInbox() {
    var tracker = InboxZeroMotionTracker()

    // Initial load with 1 Inbox row never fires.
    let initial = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(initial, .init())
    XCTAssertEqual(tracker.iconSymbolName(count: 1), "tray.full")

    // User acts on the Inbox row (complete / move / schedule / delete / file).
    tracker.recordGesture(itemIDs: ["t1"])
    let outcome = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertTrue(outcome.playVisualMotion)
    XCTAssertTrue(outcome.playHaptic)
    XCTAssertTrue(outcome.announceVoiceOver)
    XCTAssertFalse(outcome.cancelInFlightMotion)
    XCTAssertEqual(tracker.phase, .checkmark)
    XCTAssertEqual(tracker.iconSymbolName(count: 0), "checkmark")
    XCTAssertEqual(defaults.string(forKey: InboxZeroMotion.lastPlayedDayKey), "2026-11-24")

    // After ~0.9s hold finishes, icon settles to empty tray.
    tracker.finishMotion()
    XCTAssertEqual(tracker.phase, .idle)
    XCTAssertEqual(tracker.iconSymbolName(count: 0), "tray")
  }

  func testWaitsThroughSettleWindowBeforeFiring() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )

    // User checks the last Inbox task; it stays visible during settle.
    tracker.recordGesture(itemIDs: ["t1"])
    let duringSettle = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(duringSettle, .init())
    XCTAssertEqual(tracker.phase, .idle)

    // Settle finishes and the row leaves: now the motion triggers.
    let atSettleEnd = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertTrue(atSettleEnd.playVisualMotion)
    XCTAssertTrue(atSettleEnd.playHaptic)
    XCTAssertTrue(atSettleEnd.announceVoiceOver)
  }

  func testBatchGestureAndReminderIDsTrigger() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1", "reminder:r1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )

    tracker.recordGesture(itemIDs: ["t1", "reminder:r1"])
    let outcome = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertTrue(outcome.playVisualMotion)
    XCTAssertTrue(outcome.playHaptic)
    XCTAssertTrue(outcome.announceVoiceOver)
  }

  // MARK: - Exclusions (§2)

  func testDoesNotFireOutsideToday() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: false, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    tracker.recordGesture(itemIDs: ["t1"], currentInboxIDs: ["t1"])
    let outcome = tracker.observe(
      isToday: false, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(outcome, .init())
    XCTAssertNil(defaults.string(forKey: InboxZeroMotion.lastPlayedDayKey))
  }

  func testDoesNotFireOnInitialEmptyLoad() {
    var tracker = InboxZeroMotionTracker()
    let outcome = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(outcome, .init())
  }

  func testDoesNotFireWhenSyncOrRemoteEmptiesInbox() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )

    // No user gesture recorded — remote sync / MCP / agent removed t1.
    let outcome = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(outcome, .init())
    XCTAssertNil(defaults.string(forKey: InboxZeroMotion.lastPlayedDayKey))
  }

  func testEarlierNonZeroGestureDoesNotArmLaterSyncToZero() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1", "t2"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )

    // User deletes t1 (Inbox drops 2 -> 1).
    tracker.recordGesture(itemIDs: ["t1"])
    let afterFirst = tracker.observe(
      isToday: true, inboxIDs: ["t2"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(afterFirst, .init())

    // Later, remote sync deletes t2 (Inbox drops 1 -> 0) with no user gesture.
    let afterSync = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(afterSync, .init())
  }

  func testGestureOnNonInboxRowDoesNotArmTrigger() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["inbox-1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )

    tracker.recordGesture(itemIDs: ["project-task-99"])
    let outcome = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(outcome, .init())
  }

  func testUncheckingSettlingRowCancelsGesture() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )

    tracker.recordGesture(itemIDs: ["t1"])
    tracker.cancelGesture(itemIDs: ["t1"])
    let outcome = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(outcome, .init())
  }

  func testDoesNotFireWhenTagFilterHidesRowsOrIsActive() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )

    // Enabling a tag filter hides the last Inbox row.
    let hiddenByTag = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: true, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(hiddenByTag, .init())

    // Clearing the tag filter brings t1 back, then filtering with t1 visible and
    // acting on t1 while the tag filter is active still does not fire.
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: true, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    tracker.recordGesture(itemIDs: ["t1"])
    let emptiedUnderTag = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: true, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(emptiedUnderTag, .init())
  }

  func testDoesNotFireWhenInboxIsFolded() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: true,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )

    tracker.recordGesture(itemIDs: ["t1"])
    let outcome = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: true,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(outcome, .init())
  }

  func testDoesNotFireWhenSameGestureClearsLastTodayTaskArc() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )

    tracker.recordGesture(itemIDs: ["t1"], clearedTodayArc: true)
    let outcome = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(outcome, .init())
    XCTAssertNil(defaults.string(forKey: InboxZeroMotion.lastPlayedDayKey))
  }

  // MARK: - Once-a-day budget (§2a), Setting (§7), Accessibility (§6)

  func testOncePerDayBudgetAndDayRollover() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )

    // First Inbox zero today: plays visual + haptic + VoiceOver.
    tracker.recordGesture(itemIDs: ["t1"])
    let first = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertTrue(first.playVisualMotion)
    XCTAssertTrue(first.playHaptic)
    XCTAssertTrue(first.announceVoiceOver)
    tracker.finishMotion()

    // New task captured and emptied again on the SAME day: no motion, no haptic,
    // VoiceOver STILL announces (§2a, §6).
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t2"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    tracker.recordGesture(itemIDs: ["t2"])
    let secondSameDay = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertFalse(secondSameDay.playVisualMotion)
    XCTAssertFalse(secondSameDay.playHaptic)
    XCTAssertTrue(secondSameDay.announceVoiceOver)

    // Next day (or time travel): budget is fresh again.
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t3"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-25", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    tracker.recordGesture(itemIDs: ["t3"])
    let nextDay = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-25", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertTrue(nextDay.playVisualMotion)
    XCTAssertTrue(nextDay.playHaptic)
    XCTAssertTrue(nextDay.announceVoiceOver)
    XCTAssertEqual(defaults.string(forKey: InboxZeroMotion.lastPlayedDayKey), "2026-11-25")
  }

  func testSettingOffStopsMotionAndHapticButKeepsVoiceOver() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: false, reduceMotion: false, defaults: defaults
    )

    tracker.recordGesture(itemIDs: ["t1"])
    let outcome = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: false, reduceMotion: false, defaults: defaults
    )
    XCTAssertFalse(outcome.playVisualMotion)
    XCTAssertFalse(outcome.playHaptic)
    XCTAssertTrue(outcome.announceVoiceOver)
    XCTAssertEqual(tracker.phase, .idle)
    // Setting was off, so today's budget is untouched if the user enables it later.
    XCTAssertNil(defaults.string(forKey: InboxZeroMotion.lastPlayedDayKey))
  }

  func testReduceMotionStopsVisualEffectButKeepsHapticAndVoiceOver() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: true, defaults: defaults
    )

    tracker.recordGesture(itemIDs: ["t1"])
    let outcome = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: true, defaults: defaults
    )
    XCTAssertFalse(outcome.playVisualMotion)
    XCTAssertTrue(outcome.playHaptic)
    XCTAssertTrue(outcome.announceVoiceOver)
    XCTAssertEqual(tracker.phase, .idle)
    XCTAssertEqual(defaults.string(forKey: InboxZeroMotion.lastPlayedDayKey), "2026-11-24")
  }

  // MARK: - Cancellation (§5) & Undo Budget Rule (§2a)

  func testUndoDuringMotionCancelsAndStillCountsAgainstDailyBudget() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )

    tracker.recordGesture(itemIDs: ["t1"])
    let started = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertTrue(started.playVisualMotion)
    XCTAssertEqual(tracker.phase, .checkmark)

    // Undo brings t1 back while the checkmark is holding -> cancels immediately.
    let undone = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertTrue(undone.cancelInFlightMotion)
    XCTAssertFalse(undone.playVisualMotion)
    XCTAssertFalse(undone.playHaptic)
    XCTAssertEqual(tracker.phase, .idle)
    XCTAssertEqual(tracker.iconSymbolName(count: 1), "tray.full")

    // Redo / emptying again today cannot replay the motion or haptic (§2a).
    tracker.recordGesture(itemIDs: ["t1"])
    let redone = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertFalse(redone.playVisualMotion)
    XCTAssertFalse(redone.playHaptic)
    XCTAssertTrue(redone.announceVoiceOver)
  }

  func testNewCaptureAndLeavingTodayCancelMotionCleanly() {
    var tracker = InboxZeroMotionTracker()
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t1"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )

    tracker.recordGesture(itemIDs: ["t1"])
    _ = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-24", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(tracker.phase, .checkmark)

    // Explicit cancel (e.g. starting a new capture into Inbox).
    XCTAssertTrue(tracker.cancelMotion())
    XCTAssertEqual(tracker.phase, .idle)
    XCTAssertFalse(tracker.cancelMotion())

    // Next day: start again, then leave Today -> drops and never replays on return.
    _ = tracker.observe(
      isToday: true, inboxIDs: ["t2"], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-25", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    tracker.recordGesture(itemIDs: ["t2"])
    _ = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-25", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(tracker.phase, .checkmark)

    let leftToday = tracker.observe(
      isToday: false, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-25", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertTrue(leftToday.cancelInFlightMotion)
    XCTAssertEqual(tracker.phase, .idle)

    // Returning to an empty Today does not replay.
    let returned = tracker.observe(
      isToday: true, inboxIDs: [], tagFilterActive: false, isCollapsed: false,
      today: "2026-11-25", settingEnabled: true, reduceMotion: false, defaults: defaults
    )
    XCTAssertEqual(returned, .init())
  }
}
