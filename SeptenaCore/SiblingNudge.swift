import Foundation

/// Same-device app-to-app "fetch now" hint between Septena and Septask
/// (docs/SEPTASK.md P4). CloudKit push to a sibling on the SAME device is
/// slow/best-effort, so after the server accepts this app's changes we ring
/// a Darwin notification; a running sibling fetches within a beat instead of
/// waiting for its next foreground. Data still moves only through CloudKit —
/// a Darwin notification carries no payload by design, it is purely a hint.
/// Best-effort on purpose: a suspended sibling misses it, and foreground
/// fetch remains the correctness path (docs/SEPTASK.md §5).
enum SiblingNudge {
  /// Per-profile names so an app observes only its sibling's posts and never
  /// re-fetches off its own send echo.
  private static var postName: String {
    RuntimeProfile.current.isTasksOnly
      ? "com.septena.nudge.fromSeptask"
      : "com.septena.nudge.fromSeptena"
  }
  private static var observeName: String {
    RuntimeProfile.current.isTasksOnly
      ? "com.septena.nudge.fromSeptena"
      : "com.septena.nudge.fromSeptask"
  }

  /// Ring the sibling. Call after CKSyncEngine confirms accepted changes.
  static func post() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(postName as CFString),
      nil, nil, true)
  }

  @MainActor private static var pending = false
  @MainActor private static var handler: (() -> Void)?

  /// Install the sibling-write handler (idempotent enough for one caller:
  /// `SeptenaServices.start()`). Runs on the main actor, debounced — a send
  /// often lands as several batches and one fetch covers them all.
  @MainActor
  static func observe(_ onNudge: @escaping () -> Void) {
    handler = onNudge
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      nil,
      { _, _, _, _, _ in
        Task { @MainActor in SiblingNudge.fire() }
      },
      observeName as CFString,
      nil,
      .deliverImmediately)
  }

  @MainActor
  private static func fire() {
    guard !pending else { return }
    pending = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(400))
      pending = false
      SeptenaLog.info("[SiblingNudge] sibling wrote — fetching")
      handler?()
    }
  }
}
