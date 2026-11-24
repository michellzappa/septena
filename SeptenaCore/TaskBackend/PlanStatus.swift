// The account's plan, as the server reports it (ADR 0010, ADR 0023).
//
// The server owns the plan: it verifies purchases and enforces every limit
// from one plan table. The app never decides access. This store only reads
// `GET /v1/entitlement` so Settings can say which plan the account is on.
// Copy for every state comes from `registry/plans.json` (`RegistryPlans`).

import Foundation
import Observation

/// Wire shape of `GET /v1/entitlement` (backend/src/api/routes.ts).
struct BackendEntitlement: Decodable, Sendable {
  struct Row: Decodable, Sendable {
    /// `apple` / `stripe` / `google` / `grant` / `trial` (ADR 0026).
    let source: String
    let productId: String?
    /// ms since 1970; nil means no expiry (a grant).
    let expiresAt: Double?
    let status: String
    let active: Bool
  }
  let active: Bool
  let entitlements: [Row]
  /// The token every App Store purchase carries (spec §5). Optional so an
  /// older server answer still decodes.
  let appAccountToken: String?
  /// ms since 1970: the reverse trial's end while it is the only active row.
  let trialEndsAt: Double?
  /// True when the server refuses calls past a limit. In log-only mode it
  /// reports limits (a device as not syncing) but still serves the call.
  /// Optional so an older server answer still decodes.
  let enforced: Bool?
  /// The plan table row the server applies (spec §6.3). Optional for an older server.
  let limits: Limits?
  /// The calling device's sync slot (spec §6.3). Optional for an older server.
  let device: Device?

  struct Limits: Decodable, Sendable, Equatable {
    let devices: Int?
    let liveSync: Bool?
    let changeLogDays: Int?
    let logbookDays: Int?
    let recentlyDeletedDays: Int?
    let attachmentsGB: Double?
    let connectorWritesPerDay: Int?
    let agentRunsPerMonth: Int?
    let createShares: Bool?
  }

  struct Device: Decodable, Sendable {
    /// This device holds a sync slot.
    let syncing: Bool
    let syncingDevices: Int
    let knownDevices: Int
  }
}

@MainActor
@Observable
final class PlanStatus {
  static let shared = PlanStatus()

  enum Plan: Equatable {
    /// No account on this device: the full app, local only.
    case device
    /// Signed in, no active entitlement: the free account. `lapsed` when
    /// the account paid before (any expired row that is not the trial).
    case free(lapsed: Bool)
    /// The 14-day reverse trial (spec §3): Plus limits, nothing paid.
    case trial(endsAt: Date)
    /// An active entitlement. `paidThrough` is nil for a grant with no
    /// expiry. The server does not report auto-renew, so the app says
    /// "through", never "renews". `source` says where it was bought, so no
    /// app offers a second purchase (ADR 0026).
    case plus(paidThrough: Date?, source: String)
  }

  /// nil until the first answer from the server. Views show nothing for an
  /// unknown plan rather than guess.
  private(set) var plan: Plan?
  private(set) var lastError: String?
  /// From the last answer. Purchases need it; nil until the first read.
  private(set) var appAccountToken: UUID?
  /// The server refuses calls past a limit (not log-only mode).
  private(set) var enforced = false
  /// The server's plan limits from the last `GET /v1/entitlement` read.
  private(set) var limits: BackendEntitlement.Limits?
  /// This device holds a sync slot. nil until the server says so; true on
  /// an older server that does not report it.
  private(set) var deviceSyncing: Bool?
  /// Set immediately when a sync/API call answers HTTP 402 `device_not_syncing`,
  /// before the follow-up `GET /v1/entitlement` returns. Cleared on the next
  /// successful `refresh()` or sign-out.
  private(set) var serverBlockedDevice = false
  /// Clean server/registry message when `POST /v1/entitlement/device` returned
  /// 402 (e.g. the 24-hour move cooldown in spec §6.4 finding 2).
  private(set) var syncThisDeviceLimitMessage: String?
  /// The reverse trial ran out and the account never paid: a `trial` row
  /// exists, none is active, and no other row ever existed.
  private(set) var trialEnded = false
  @ObservationIgnored private var lastLimitRefreshAt: Date = .distantPast

  private init() {}

  /// The account has the Plus limits now: paid, granted or in the trial.
  var isPlus: Bool {
    switch plan {
    case .plus, .trial: return true
    default: return false
    }
  }

  /// The account may buy Plus here: signed in and not already paying from
  /// any source. The trial may buy; billing then starts that day.
  var canPurchase: Bool {
    switch plan {
    case .free, .trial: return appAccountToken != nil
    default: return false
    }
  }

  /// The server stops sync on this device: the free account's one slot is
  /// on another device. False in log-only mode, where the server reports
  /// `syncing: false` but still syncs (spec §6.3). The server judges; this
  /// only reads its answer (or a live 402 `device_not_syncing` refusal).
  var deviceNotSyncing: Bool {
    serverBlockedDevice || (enforced && deviceSyncing == false && !isPlus)
  }

  /// Whether the plan allows the live WebSocket nudge (`/v1/sync/ws`).
  /// Defaults to true until the server reports `enforced && limits.liveSync == false`.
  var liveSyncAllowed: Bool {
    !(enforced && limits?.liveSync == false)
  }

  /// Whether the plan allows uploading attachment bytes to the server.
  /// Defaults to true until the server reports `enforced && limits.attachmentsGB == 0`.
  var attachmentsAllowed: Bool {
    !(enforced && limits?.attachmentsGB == 0)
  }

  /// One status line for Settings, from the registry copy.
  var statusLine: String? {
    switch plan {
    case .device: return RegistryPlans.Status.device
    case .free: return RegistryPlans.Status.free
    case .trial(let end): return RegistryPlans.Status.trialEnds(date: Self.day(end))
    case .plus(let through?, _): return RegistryPlans.Status.paidThrough(date: Self.day(through))
    case .plus(nil, _): return RegistryPlans.Status.plus
    case nil: return nil
    }
  }

  /// Reads the plan from the server. Signed out, the plan is `.device`. A
  /// failed read keeps the last known plan and records the error.
  ///
  /// When a value Today's notices read changes (the plan, the device slot,
  /// the trial end), it posts `.septenaTasksChanged` so both task lists
  /// read their notices again.
  func refresh() async {
    let before = noticeInputs
    defer { if noticeInputs != before { NotificationCenter.default.post(name: .septenaTasksChanged, object: nil) } }
    guard TaskBackendClient.hasSession else {
      plan = .device
      appAccountToken = nil
      lastError = nil
      enforced = false
      limits = nil
      deviceSyncing = nil
      serverBlockedDevice = false
      syncThisDeviceLimitMessage = nil
      trialEnded = false
      return
    }
    do {
      let answer = try await TaskBackendClient.shared.entitlement()
      plan = Self.plan(from: answer)
      appAccountToken = answer.appAccountToken.flatMap(UUID.init(uuidString:))
      enforced = answer.enforced ?? false
      limits = answer.limits
      deviceSyncing = answer.device?.syncing ?? true
      serverBlockedDevice = false
      trialEnded = Self.trialEnded(answer)
      lastError = nil
      TaskSyncEngine.shared.applyPlanStatus(
        deviceNotSyncing: deviceNotSyncing,
        liveSyncAllowed: liveSyncAllowed,
        attachmentsAllowed: attachmentsAllowed
      )
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Records a live HTTP 402 plan-limit refusal from any backend call
  /// (spec §6.3). Updates local state immediately so Today's notices and
  /// Settings reflect the limit without waiting, then refreshes `/v1/entitlement`
  /// (throttled) so the full plan state stays current.
  func noteLimitReached(_ limit: BackendLimitError) {
    let before = noticeInputs
    switch limit.kind {
    case .deviceNotSyncing:
      enforced = true
      deviceSyncing = false
      serverBlockedDevice = true
    case .liveSyncNotInPlan, .attachmentsNotInPlan, .attachmentQuota,
         .historyEdge, .agentRuns, .connectorCap, .shareCreate, .other:
      break
    }
    if noticeInputs != before {
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
    let now = Date()
    if now.timeIntervalSince(lastLimitRefreshAt) > 15 {
      lastLimitRefreshAt = now
      Task { @MainActor in await self.refresh() }
    }
  }

  /// Moves the free account's sync slot to this device
  /// (`POST /v1/entitlement/device`). The other device stops syncing and
  /// keeps its local data. Reads the plan again after, and starts a sync.
  /// False when the server did not take the move.
  @discardableResult
  func syncThisDevice() async -> Bool {
    syncThisDeviceLimitMessage = nil
    do {
      try await TaskBackendClient.shared.claimSyncDevice()
    } catch TaskBackendError.limitReached(let limit) {
      syncThisDeviceLimitMessage = limit.userMessage
      lastError = nil
      noteLimitReached(limit)
      return false
    } catch {
      lastError = error.localizedDescription
      return false
    }
    await refresh()
    TaskSyncEngine.shared.activate()
    return true
  }

  private struct NoticeInputs: Equatable {
    let plan: Plan?
    let deviceNotSyncing: Bool
    let trialEnded: Bool
  }

  private var noticeInputs: NoticeInputs {
    NoticeInputs(plan: plan, deviceNotSyncing: deviceNotSyncing, trialEnded: trialEnded)
  }

  /// The trial ran out and nothing was ever bought or granted.
  nonisolated static func trialEnded(_ answer: BackendEntitlement) -> Bool {
    guard !answer.active else { return false }
    let rows = answer.entitlements
    return rows.contains { $0.source == "trial" && !$0.active }
      && !rows.contains { $0.source != "trial" }
  }

  nonisolated static func plan(from answer: BackendEntitlement) -> Plan {
    let live = answer.entitlements.filter(\.active)
    guard answer.active, !live.isEmpty else {
      return .free(lapsed: answer.entitlements.contains { $0.source != "trial" })
    }
    let paid = live.filter { $0.source != "trial" }
    guard let first = paid.first else {
      // Only the trial is active. The server reports its end; fall back to
      // the row's expiry for an older server.
      let end = answer.trialEndsAt ?? live.compactMap(\.expiresAt).max() ?? 0
      return .trial(endsAt: date(end))
    }
    // A grant with no expiry never renews; otherwise show the latest expiry.
    if let open = paid.first(where: { $0.expiresAt == nil }) { return .plus(paidThrough: nil, source: open.source) }
    let latest = paid.max { ($0.expiresAt ?? 0) < ($1.expiresAt ?? 0) } ?? first
    return .plus(paidThrough: latest.expiresAt.map(date), source: latest.source)
  }

  private nonisolated static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
  private static func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
}
