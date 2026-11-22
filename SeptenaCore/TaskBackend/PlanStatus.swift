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
  func refresh() async {
    guard TaskBackendClient.hasSession else {
      plan = .device
      appAccountToken = nil
      lastError = nil
      return
    }
    do {
      let answer = try await TaskBackendClient.shared.entitlement()
      plan = Self.plan(from: answer)
      appAccountToken = answer.appAccountToken.flatMap(UUID.init(uuidString:))
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
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
