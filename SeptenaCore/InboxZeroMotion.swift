import Foundation

/// Shared constants and trigger state machine for Inbox zero motion
/// (`docs/INBOX_ZERO_MOTION_SPEC.md`, #298).
///
/// Foundation-only so `SeptenaCoreTests` compiles and tests it directly
/// without a host app or UI framework. Both the SwiftUI shell (`TaskListView`)
/// and the AppKit shell (`SeptaskKitTaskListController`) drive their Inbox
/// header icon from `InboxZeroMotionTracker` so §2, §2a, §5 and §6 cannot drift.
enum InboxZeroMotion {
  /// Device-local `UserDefaults` key storing the `DayClock.today` YYYY-MM-DD
  /// day on which the Inbox zero motion last started (spec §2a).
  static let lastPlayedDayKey = "septena.ui.inboxZeroMotionLastDay"

  /// How long the checkmark holds before replacing back to the empty tray
  /// (spec §3: "+ ~0.9 s").
  static let holdDuration: TimeInterval = 0.9

  static let filledTraySymbol = "tray.full"
  static let emptyTraySymbol = "tray"
  static let checkmarkSymbol = "checkmark"

  /// VoiceOver confirmation posted whenever the §2 trigger fires — even when
  /// the visual setting is off, Reduce Motion is on, or today's budget is used
  /// (spec §2a, §6).
  static var announcementText: String {
    String(localized: "Inbox clear",
           comment: "VoiceOver announcement when the user empties the Inbox on Today")
  }

  /// Whether Settings ▸ Display ▸ "Inbox zero animation" is enabled on this
  /// device (spec §7; default true).
  static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: RegistrySettings.StorageKey.inboxZeroMotionEnabled) as? Bool
      ?? RegistrySettings.Defaults.inboxZeroMotionEnabled
  }

  /// True when the once-a-day motion budget for `today` (`DayClock.today`)
  /// has already been spent on this device (spec §2a).
  static func hasPlayedToday(_ today: String, in defaults: UserDefaults = .standard) -> Bool {
    defaults.string(forKey: lastPlayedDayKey) == today
  }

  /// Consume today's motion budget. Called as soon as a run starts — a run
  /// later cancelled by undo still counts (spec §2a).
  static func markPlayedToday(_ today: String, in defaults: UserDefaults = .standard) {
    defaults.set(today, forKey: lastPlayedDayKey)
  }
}

/// Pure, testable trigger, daily-budget, and interruption state machine for
/// Inbox zero motion (`docs/INBOX_ZERO_MOTION_SPEC.md`).
struct InboxZeroMotionTracker {
  enum Phase: Equatable {
    case idle
    case checkmark
  }

  struct Outcome: Equatable {
    /// Start the `tray.full` → `checkmark` (draw-on) → `tray` choreography.
    /// True only when §2 fires, §2a budget is free, setting is on, and
    /// Reduce Motion is off.
    var playVisualMotion: Bool = false
    /// Play `CheckFeel.tuck.hapticSpec()`. True when §2 fires, §2a budget is
    /// free, and setting is on — even under Reduce Motion (spec §6).
    var playHaptic: Bool = false
    /// Post `A11y.announce("Inbox clear")`. True whenever §2 fires, regardless
    /// of setting, Reduce Motion, or daily budget (spec §2a, §6).
    var announceVoiceOver: Bool = false
    /// Immediately cancel an in-flight checkmark animation (undo, new capture
    /// into Inbox, or leaving Today — spec §5).
    var cancelInFlightMotion: Bool = false
  }

  private(set) var phase: Phase = .idle
  private(set) var lastObservedCount: Int?
  private(set) var lastObservedInboxIDs: Set<String> = []
  private(set) var pendingGestureIDs: Set<String> = []
  private(set) var suppressedByDayFlourish: Bool = false

  /// Record a user gesture on one or more rows (complete, cancel, move/file,
  /// move to Today, schedule, delete, or accept/import of a pending Apple
  /// Reminder). Only IDs currently in the Inbox are kept, so gestures on
  /// classified Today rows can never trigger Inbox zero.
  ///
  /// Pass `clearedTodayArc: true` when the same gesture also triggers Today's
  /// `.arc` flourish (`TaskCelebration.completed`), so the larger celebration
  /// wins (spec §2).
  mutating func recordGesture(itemIDs: [String],
                              currentInboxIDs: Set<String>? = nil,
                              clearedTodayArc: Bool = false) {
    if lastObservedCount == nil, let currentInboxIDs, !currentInboxIDs.isEmpty {
      lastObservedInboxIDs = currentInboxIDs
      lastObservedCount = currentInboxIDs.count
    }
    let activeInbox = currentInboxIDs ?? lastObservedInboxIDs
    let matched = itemIDs.filter { activeInbox.contains($0) }
    if !matched.isEmpty {
      pendingGestureIDs.formUnion(matched)
      if clearedTodayArc {
        suppressedByDayFlourish = true
      }
    } else if clearedTodayArc, !pendingGestureIDs.isEmpty {
      suppressedByDayFlourish = true
    }
  }

  /// Drop previously recorded gesture IDs (for example when the user un-checks
  /// a row before its settle window ends).
  mutating func cancelGesture(itemIDs: [String]) {
    pendingGestureIDs.subtract(itemIDs)
    if pendingGestureIDs.isEmpty {
      suppressedByDayFlourish = false
    }
  }

  /// Evaluate the current Inbox state after a reload, settle completion, or
  /// filter/tag change.
  mutating func observe(isToday: Bool,
                        inboxIDs: Set<String>,
                        tagFilterActive: Bool,
                        isCollapsed: Bool,
                        today: String,
                        settingEnabled: Bool,
                        reduceMotion: Bool,
                        defaults: UserDefaults = .standard) -> Outcome {
    var outcome = Outcome()

    // Spec §2 item 1 & §5: only on Today; leaving Today drops any running motion.
    guard isToday else {
      if phase == .checkmark {
        phase = .idle
        outcome.cancelInFlightMotion = true
      }
      lastObservedCount = nil
      lastObservedInboxIDs = []
      pendingGestureIDs = []
      suppressedByDayFlourish = false
      return outcome
    }

    let newCount = inboxIDs.count

    // Spec §5: undo or a new capture bringing a row back during the motion
    // cancels it immediately with no reverse animation.
    if phase == .checkmark, newCount >= 1 {
      phase = .idle
      outcome.cancelInFlightMotion = true
      lastObservedCount = newCount
      lastObservedInboxIDs = inboxIDs
      pendingGestureIDs.formIntersection(inboxIDs)
      if pendingGestureIDs.isEmpty { suppressedByDayFlourish = false }
      return outcome
    }

    // Spec §2: initial load / filter switch never triggers.
    guard let previousCount = lastObservedCount else {
      lastObservedCount = newCount
      lastObservedInboxIDs = inboxIDs
      pendingGestureIDs = []
      suppressedByDayFlourish = false
      return outcome
    }

    // Spec §2: never trigger while a tag filter is active (a tag filter hides
    // non-matching Inbox rows, so 0 visible rows does not mean Inbox zero).
    if tagFilterActive {
      lastObservedCount = newCount
      lastObservedInboxIDs = inboxIDs
      if newCount == 0 {
        pendingGestureIDs = []
        suppressedByDayFlourish = false
      } else {
        pendingGestureIDs.formIntersection(inboxIDs)
        if pendingGestureIDs.isEmpty { suppressedByDayFlourish = false }
      }
      return outcome
    }

    if previousCount >= 1, newCount == 0 {
      let causedByUserGesture = !pendingGestureIDs.isEmpty
      let eligible = causedByUserGesture && !isCollapsed && !suppressedByDayFlourish

      lastObservedCount = 0
      lastObservedInboxIDs = []
      pendingGestureIDs = []
      suppressedByDayFlourish = false

      guard eligible else { return outcome }

      // Spec §2a & §6: VoiceOver always announces when §2 triggers.
      outcome.announceVoiceOver = true

      if settingEnabled, !InboxZeroMotion.hasPlayedToday(today, in: defaults) {
        InboxZeroMotion.markPlayedToday(today, in: defaults)
        outcome.playHaptic = true
        if !reduceMotion {
          outcome.playVisualMotion = true
          phase = .checkmark
        }
      }
      return outcome
    }

    lastObservedCount = newCount
    lastObservedInboxIDs = inboxIDs
    // Prune completed non-zero-reaching gestures while keeping any still-settling
    // Inbox rows armed until their settle window finishes.
    pendingGestureIDs.formIntersection(inboxIDs)
    if pendingGestureIDs.isEmpty { suppressedByDayFlourish = false }
    return outcome
  }

  /// End the ~0.9 s checkmark hold and return the header icon to rest.
  mutating func finishMotion() {
    phase = .idle
  }

  /// Cancel any running motion immediately (e.g. new capture started into Inbox
  /// or view disappearing). Returns true if a running motion was cancelled.
  @discardableResult
  mutating func cancelMotion() -> Bool {
    pendingGestureIDs = []
    suppressedByDayFlourish = false
    if phase == .checkmark {
      phase = .idle
      return true
    }
    return false
  }

  /// Reset session state when leaving or switching filters. Returns true if an
  /// in-flight motion was cancelled.
  @discardableResult
  mutating func resetForFilterChange() -> Bool {
    let wasRunning = (phase == .checkmark)
    phase = .idle
    lastObservedCount = nil
    lastObservedInboxIDs = []
    pendingGestureIDs = []
    suppressedByDayFlourish = false
    return wasRunning
  }

  /// The SF Symbol name the Inbox header should show for `count`.
  func iconSymbolName(count: Int) -> String {
    switch phase {
    case .checkmark:
      return InboxZeroMotion.checkmarkSymbol
    case .idle:
      return count > 0 ? InboxZeroMotion.filledTraySymbol : InboxZeroMotion.emptyTraySymbol
    }
  }
}
