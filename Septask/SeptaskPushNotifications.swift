import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

// APNs remote notification registration & interactive option action handler
// for agent question turns (F1b #213, docs/TASK_FACTORY_SPEC.md §8).
//
// Category & action design (no UNNotificationServiceExtension target required):
// - Registers `UNNotificationCategory` `"AGENT_QUESTION"` with 3 static
//   option-slot actions: `AGENT_OPTION_0` ("Option 1"), `AGENT_OPTION_1`
//   ("Option 2"), and `AGENT_OPTION_2` ("Option 3").
// - The backend summarizes the numbered choices (`1. … · 2. … · 3. …`) directly
//   in `aps.alert.body` and includes the exact option strings in
//   `userInfo["options"]` (capped at 3) plus `aps.mutable-content: 1` for
//   forward compatibility if a service extension is added later.
// - Static slot titles keep every pending notification in Notification Center
//   unambiguous even when multiple agent questions are open simultaneously,
//   and require zero extra app-extension targets or provisioning profiles.
// - Tapping an action runs in the background (no foreground launch): it starts
//   `SeptenaServices`, looks up `options[slot]` from `userInfo`, appends the
//   user turn via `TaskMutator.appendConvoTurn` with matching `inReplyTo` and
//   `chosen`, and flushes `TaskSyncEngine.shared.scheduleSync(after: 0)`.

enum AgentQuestionNotification {
  static let categoryID = "AGENT_QUESTION"
  /// An agent handed work over to Review. No actions: a tap opens the task.
  static let reviewCategoryID = "AGENT_REVIEW"
  static let optionActionIDs = [
    "AGENT_OPTION_0",
    "AGENT_OPTION_1",
    "AGENT_OPTION_2",
  ]

  enum UserInfoKey {
    static let taskID = "taskId"
    static let turnSeq = "turnSeq"
    static let step = "step"
    static let options = "options"
  }
}

@MainActor
final class SeptaskPushNotifications {
  static let shared = SeptaskPushNotifications()

  private static let lastTokenKey = "septask.apns.lastHexToken"
  private static let lastSandboxKey = "septask.apns.lastSandbox"
  private static let uploadedTokenKey = "septask.apns.uploadedHexToken"

  private var started = false

  private init() {}

  /// Idempotent startup called from `SeptaskLaunch.run(settings:)`.
  /// Registers the `AGENT_QUESTION` category (merging with existing categories
  /// so `TaskReminderScheduler`'s category stays intact) and hooks into the
  /// shared notification delegate and sign-in/sign-out lifecycle.
  func start() {
    guard !started else {
      syncRegistrationIfNeeded()
      return
    }
    started = true

    registerCategory(on: UNUserNotificationCenter.current())

    TaskReminderScheduler.externalResponseHandler = { response in
      await SeptaskPushNotifications.handleNotificationResponse(response)
    }
    TaskReminderScheduler.onAuthorizationGranted = { [weak self] in
      self?.registerForRemoteNotificationsIfAuthorized()
    }
    TaskSyncEngine.onSignInHook = { [weak self] in
      self?.syncRegistrationIfNeeded()
    }
    TaskSyncEngine.beforeSignOutHook = { [weak self] in
      await self?.unregisterCurrentToken()
    }

    syncRegistrationIfNeeded()
  }

  /// Checks notification authorization without prompting and registers for
  /// APNs remote notifications if already granted, then uploads any pending
  /// device token once signed in.
  func syncRegistrationIfNeeded() {
    registerForRemoteNotificationsIfAuthorized()
    uploadPendingTokenIfNeeded()
  }

  func registerForRemoteNotificationsIfAuthorized() {
    #if os(iOS)
    Task { @MainActor in
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        UIApplication.shared.registerForRemoteNotifications()
      case .notDetermined, .denied:
        break
      @unknown default:
        break
      }
    }
    #endif
  }

  /// Called by `SeptaskAppDelegate` when iOS delivers an APNs device token.
  func didRegisterForRemoteNotifications(deviceToken: Data) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    let sandbox = Self.isSandboxAPNsEnvironment()
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: Self.lastTokenKey)
    let previousSandbox = defaults.bool(forKey: Self.lastSandboxKey)
    defaults.set(hex, forKey: Self.lastTokenKey)
    defaults.set(sandbox, forKey: Self.lastSandboxKey)
    if previous != hex || previousSandbox != sandbox {
      defaults.removeObject(forKey: Self.uploadedTokenKey)
    }
    uploadPendingTokenIfNeeded()
  }

  func didFailToRegisterForRemoteNotifications(error: Error) {
    SeptenaLog.error("[Push] APNs registration failed", error)
  }

  /// Best-effort deletion of the registered push token on sign-out.
  func unregisterCurrentToken() async {
    let defaults = UserDefaults.standard
    guard let hex = defaults.string(forKey: Self.lastTokenKey), !hex.isEmpty else { return }
    defaults.removeObject(forKey: Self.uploadedTokenKey)
    guard TaskBackendClient.hasSession else { return }
    do {
      try await TaskBackendClient.shared.deletePushToken(hex)
    } catch {
      SeptenaLog.error("[Push] Failed to delete push token on sign-out", error)
    }
  }

  private func uploadPendingTokenIfNeeded() {
    #if os(iOS)
    let defaults = UserDefaults.standard
    guard TaskBackendClient.hasSession,
          let hex = defaults.string(forKey: Self.lastTokenKey),
          !hex.isEmpty else { return }
    let sandbox = defaults.bool(forKey: Self.lastSandboxKey)
    let uploadedKey = "\(hex):\(sandbox ? "1" : "0")"
    guard defaults.string(forKey: Self.uploadedTokenKey) != uploadedKey else { return }

    Task {
      do {
        try await TaskBackendClient.shared.registerPushToken(hex, platform: "ios", sandbox: sandbox)
        await MainActor.run {
          UserDefaults.standard.set(uploadedKey, forKey: Self.uploadedTokenKey)
        }
      } catch {
        SeptenaLog.error("[Push] Failed to upload APNs device token", error)
      }
    }
    #endif
  }

  // MARK: - Category registration

  private func registerCategory(on center: UNUserNotificationCenter) {
    let actions: [UNNotificationAction] = AgentQuestionNotification.optionActionIDs.enumerated().map { idx, id in
      let title = String(
        format: String(localized: "Option %lld", comment: "Interactive agent question push notification option slot"),
        Int64(idx + 1)
      )
      return UNNotificationAction(identifier: id, title: title, options: [])
    }
    let category = UNNotificationCategory(
      identifier: AgentQuestionNotification.categoryID,
      actions: actions,
      intentIdentifiers: [],
      options: []
    )
    center.getNotificationCategories { existing in
      var merged = existing.filter { $0.identifier != AgentQuestionNotification.categoryID }
      merged.insert(category)
      center.setNotificationCategories(merged)
    }
  }

  // MARK: - Interactive action response

  /// Handles `AGENT_QUESTION` and `AGENT_REVIEW` taps and option button actions.
  /// Returns `true` if handled, `false` to fall through to `TaskReminderScheduler`.
  nonisolated static func handleNotificationResponse(_ response: UNNotificationResponse) async -> Bool {
    let content = response.notification.request.content
    let actionID = response.actionIdentifier
    let isAgentCategory = [AgentQuestionNotification.categoryID, AgentQuestionNotification.reviewCategoryID]
      .contains(content.categoryIdentifier)
    let optionIndex = AgentQuestionNotification.optionActionIDs.firstIndex(of: actionID)

    guard isAgentCategory || optionIndex != nil else { return false }

    let userInfo = content.userInfo
    guard let taskID = userInfo[AgentQuestionNotification.UserInfoKey.taskID] as? String,
          !taskID.isEmpty else {
      return true
    }

    // Banner tap: reveal the task in the active app shell.
    if actionID == UNNotificationDefaultActionIdentifier {
      await MainActor.run {
        guard let url = URL(string: "septask://task/\(taskID)") else { return }
        #if os(iOS)
        if let nav = SeptaskAppDelegate.navigation {
          SeptaskDeepLinkRouter.handle(url, navigation: nav, context: LocalStore.shared.container.mainContext)
        }
        #elseif os(macOS)
        SeptaskDeepLinkRouter.handleMac(url)
        #endif
      }
      return true
    }

    guard let optionIndex,
          let options = userInfo[AgentQuestionNotification.UserInfoKey.options] as? [String],
          optionIndex < options.count else {
      return true
    }

    let chosen = options[optionIndex]
    let turnSeq = (userInfo[AgentQuestionNotification.UserInfoKey.turnSeq] as? Int)
      ?? (userInfo[AgentQuestionNotification.UserInfoKey.turnSeq] as? NSNumber)?.intValue
    let stepRaw = userInfo[AgentQuestionNotification.UserInfoKey.step] as? String

    await MainActor.run {
      SeptenaServices.shared.bindWriteBoundary()
    }
    await SeptenaServices.shared.start()

    // If the task arrived on another device while this device was asleep, pull
    // once before appending so the local mirror has the row to mutate.
    let needsPull = await MainActor.run {
      SeptenaServices.shared.taskMutator.conversation(id: taskID) == nil
    }
    if needsPull {
      await TaskSyncEngine.shared.runSync(reconcileFirst: false)
    }

    let appended = await MainActor.run { () -> Bool in
      let mutator = SeptenaServices.shared.taskMutator
      let existing = mutator.conversation(id: taskID)
      let step: ConvoTurn.Step = stepRaw.flatMap(ConvoTurn.Step.init(rawValue:))
        ?? turnSeq.flatMap { seq in existing?.thread.first(where: { $0.seq == seq })?.step }
        ?? .decide

      let turn = ConvoTurn(
        seq: 0,
        role: .user,
        step: step,
        chosen: chosen,
        inReplyTo: turnSeq,
        ts: Date()
      )
      let seq = mutator.appendConvoTurn(id: taskID, turn)
      if seq > 0 {
        mutator.touch(id: taskID)
        TaskSyncEngine.shared.scheduleSync(after: 0)
        return true
      }
      return false
    }

    // Flush the queued turn immediately while iOS keeps the background wake alive.
    if appended {
      await TaskSyncEngine.shared.runSync(reconcileFirst: false)
    }

    return true
  }

  // MARK: - APNs environment detection

  /// Inspects `embedded.mobileprovision` when present so Xcode local Release
  /// runs (which sign with a development profile despite `!DEBUG`) accurately
  /// report `sandbox: true`, while TestFlight and App Store builds report `false`.
  private static func isSandboxAPNsEnvironment() -> Bool {
    #if os(iOS)
    if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
       let data = try? Data(contentsOf: url),
       let text = String(data: data, encoding: .isoLatin1),
       let keyRange = text.range(of: "<key>aps-environment</key>") {
      let tail = text[keyRange.upperBound...]
      if let start = tail.range(of: "<string>"),
         let end = tail[start.upperBound...].range(of: "</string>") {
        let env = tail[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if env == "development" { return true }
        if env == "production" { return false }
      }
    }
    #endif
    #if DEBUG
    return true
    #else
    return false
    #endif
  }
}
