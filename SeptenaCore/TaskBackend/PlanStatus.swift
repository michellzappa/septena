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
    let source: String
    let productId: String?
    /// ms since 1970; nil means no expiry (a grant).
    let expiresAt: Double?
    let status: String
    let active: Bool
  }
  let active: Bool
  let entitlements: [Row]
}

@MainActor
@Observable
final class PlanStatus {
  static let shared = PlanStatus()

  enum Plan: Equatable {
    /// No account on this device: the full app, local only.
    case device
    /// Signed in, no active entitlement: the free account.
    case free
    /// An active entitlement. `paidThrough` is nil for a grant with no
    /// expiry. The server does not report auto-renew, so the app says
    /// "through", never "renews".
    case plus(paidThrough: Date?)
  }

  /// nil until the first answer from the server. Views show nothing for an
  /// unknown plan rather than guess.
  private(set) var plan: Plan?
  private(set) var lastError: String?

  private init() {}

  var isPlus: Bool {
    if case .plus = plan { return true }
    return false
  }

  /// One status line for Settings, from the registry copy.
  var statusLine: String? {
    switch plan {
    case .device: return RegistryPlans.Status.device
    case .free: return RegistryPlans.Status.free
    case .plus(let through?):
      return RegistryPlans.Status.paidThrough(date: through.formatted(date: .abbreviated, time: .omitted))
    case .plus(nil): return RegistryPlans.Status.plus
    case nil: return nil
    }
  }

  /// Reads the plan from the server. Signed out, the plan is `.device`. A
  /// failed read keeps the last known plan and records the error.
  func refresh() async {
    guard TaskBackendClient.hasSession else {
      plan = .device
      lastError = nil
      return
    }
    do {
      let answer = try await TaskBackendClient.shared.entitlement()
      plan = Self.plan(from: answer)
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  nonisolated static func plan(from answer: BackendEntitlement) -> Plan {
    let live = answer.entitlements.filter(\.active)
    guard answer.active, !live.isEmpty else { return .free }
    // A grant with no expiry never renews; otherwise show the latest expiry.
    if live.contains(where: { $0.expiresAt == nil }) { return .plus(paidThrough: nil) }
    let latest = live.compactMap(\.expiresAt).max()
    return .plus(paidThrough: latest.map { Date(timeIntervalSince1970: $0 / 1000) })
  }
}
