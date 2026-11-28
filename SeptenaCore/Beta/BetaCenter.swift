// The beta checklist (ADR 0064, docs/BETA_ONBOARDING_SPEC.md §7). Only an
// account the backend knows as a beta tester sees it. Every word comes from
// `GET /v1/beta` (`registry/beta.json` on the server), never from the app's
// string catalog: the beta is English. A failed read or `member: false`
// shows nothing.

import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Wire shapes of `/v1/beta` (backend/src/api/beta.ts).
enum BetaWire {
  struct Copy: Decodable, Sendable, Equatable {
    let settingsRow: String
    let settingsSummary: String
    let title: String
    let deal: String
    let intro: String
    let tried: String
    let note: String
    let noteSubject: String
    let ack: String
    let ackDone: String
    let cardTitle: String
    let cardBody: String
    let cardOpen: String
    let cardDismiss: String
  }

  struct Item: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let `try`: String
  }

  /// `{ member: false }`, or every other field for a tester.
  struct State: Decodable, Sendable, Equatable {
    let member: Bool
    let joinedAt: Double?
    let copy: Copy?
    let items: [Item]?
    /// Item id → ms since 1970 when it was ticked.
    let tried: [String: Double]?
    let ackAt: Double?
    let cardDismissedAt: Double?
    let feedbackURL: String?
  }

  /// The body of `POST /v1/beta/progress`: exactly one of the three shapes.
  enum Progress: Encodable, Sendable {
    case tried(item: String, tried: Bool)
    case ack
    case dismissCard

    private enum Keys: String, CodingKey { case item, tried, ack, dismissCard }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: Keys.self)
      switch self {
      case .tried(let item, let tried):
        try c.encode(item, forKey: .item)
        try c.encode(tried, forKey: .tried)
      case .ack:
        try c.encode(true, forKey: .ack)
      case .dismissCard:
        try c.encode(true, forKey: .dismissCard)
      }
    }
  }
}

/// A tester's checklist, as the app shows it.
struct BetaChecklist: Equatable {
  var copy: BetaWire.Copy
  var items: [BetaWire.Item]
  var tried: [String: Double]
  var ackAt: Double?
  var cardDismissedAt: Double?

  var triedCount: Int { items.filter { tried[$0.id] != nil }.count }

  /// `copy.settingsSummary` with its counts filled in.
  var summary: String {
    copy.settingsSummary
      .replacingOccurrences(of: "{tried}", with: String(triedCount))
      .replacingOccurrences(of: "{total}", with: String(items.count))
  }

  /// `copy.noteSubject` for one item ("Beta: <item title>").
  func noteSubject(_ item: BetaWire.Item) -> String {
    copy.noteSubject.replacingOccurrences(of: "{item}", with: item.title)
  }

  /// `copy.ackDone` with the last ack's date (medium style), or nil.
  var ackDone: String? {
    guard let ackAt else { return nil }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    let date = formatter.string(from: Date(timeIntervalSince1970: ackAt / 1000))
    return copy.ackDone.replacingOccurrences(of: "{date}", with: date)
  }
}

/// The app side of the beta checklist. One instance; the Settings row, the
/// Beta screen and the Today card all read it.
@MainActor
@Observable
final class BetaCenter {
  static let shared = BetaCenter()

  /// The Settings page id and navigation value of the Beta screen. Not in
  /// `registry/settings.json`: the row exists only for testers, and its
  /// words come from the server.
  static let surfaceID = "beta"

  /// Nil: not a tester, signed out, or the read failed. Render nothing.
  private(set) var checklist: BetaChecklist?

  /// True when Today shows the one welcome card.
  var showsCard: Bool { checklist.map { $0.cardDismissedAt == nil } ?? false }

  /// Reads the checklist. Called on foreground and when Settings opens. A
  /// failed read hides everything, as `member: false` does.
  func refresh() async {
    guard TaskBackendClient.hasSession else { apply(nil); return }
    do {
      let state = try await TaskBackendClient.shared.betaState(platform: Self.platform)
      guard state.member, let copy = state.copy else { apply(nil); return }
      apply(BetaChecklist(copy: copy, items: state.items ?? [], tried: state.tried ?? [:],
                          ackAt: state.ackAt, cardDismissedAt: state.cardDismissedAt))
    } catch {
      apply(nil)
    }
  }

  /// Ticks or unticks an item. Optimistic: a refused write reads the
  /// server's state again.
  func setTried(_ item: BetaWire.Item, _ tried: Bool) {
    guard var next = checklist else { return }
    next.tried[item.id] = tried ? Self.nowMs : nil
    apply(next)
    send(.tried(item: item.id, tried: tried))
  }

  /// "I used Septena for real this week". The tester can say it again.
  func acknowledge() {
    guard var next = checklist else { return }
    next.ackAt = Self.nowMs
    apply(next)
    send(.ack)
  }

  /// Closes the Today card for good (Open the checklist, or Not now).
  func dismissCard() {
    guard var next = checklist, next.cardDismissedAt == nil else { return }
    next.cardDismissedAt = Self.nowMs
    apply(next)
    send(.dismissCard)
  }

  private func send(_ change: BetaWire.Progress) {
    Task { @MainActor in
      do {
        try await TaskBackendClient.shared.betaProgress(change)
      } catch {
        await refresh()
      }
    }
  }

  /// Stores the new state. Both task lists rebuild Today's notices on
  /// `.septenaTasksChanged`, so a change to the card posts it.
  private func apply(_ next: BetaChecklist?) {
    guard next != checklist else { return }
    let cardBefore = showsCard
    checklist = next
    if showsCard != cardBefore {
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
  }

  private static var nowMs: Double { (Date().timeIntervalSince1970 * 1000).rounded() }

  /// The `platform` query value: the backend lists the items that ship here.
  private static var platform: String {
    #if os(macOS)
    return "macos"
    #else
    return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
    #endif
  }
}
