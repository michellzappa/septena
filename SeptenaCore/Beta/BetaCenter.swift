// The beta welcome card (ADR 0064, docs/BETA_ONBOARDING_SPEC.md §7). Only an
// account the backend knows as a beta tester sees it. The checklist itself is
// a normal project in the tester's list, which the server seeds; the app has
// no Beta screen. The card's words come from `GET /v1/beta`
// (`registry/beta.json` on the server), never from the app's string catalog:
// the beta is English. A failed read or `member: false` shows nothing.

import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Wire shapes of `/v1/beta` (backend/src/api/beta.ts). Decoding ignores keys
/// it does not know, so the server can add fields; a tester answer without
/// the card copy decodes as no card.
enum BetaWire {
  struct Copy: Decodable, Sendable, Equatable {
    let cardTitle: String
    let cardBody: String
    let cardOpen: String
    let cardDismiss: String
  }

  /// `{ member: false }`, or `{ member: true, projectId, cardDismissedAt, copy }`.
  struct State: Decodable, Sendable, Equatable {
    let member: Bool
    /// The seeded beta project. Nil when the server has none for this tester.
    let projectId: String?
    /// ms since 1970 when the tester closed the card. Nil: the card shows.
    let cardDismissedAt: Double?
    let copy: Copy?
  }

  /// The body of `POST /v1/beta/progress`. The only change is closing the card.
  struct Progress: Encodable, Sendable {
    let dismissCard = true
  }
}

/// A tester's card, as the app shows it.
struct BetaCard: Equatable {
  var copy: BetaWire.Copy
  var projectID: String?
  var dismissedAt: Double?
}

/// The app side of the beta card. One instance; both Today lists read it.
@MainActor
@Observable
final class BetaCenter {
  static let shared = BetaCenter()

  /// Nil: not a tester, signed out, or the read failed. Render nothing.
  private(set) var card: BetaCard?

  /// True when Today shows the one welcome card.
  var showsCard: Bool { card.map { $0.dismissedAt == nil } ?? false }

  /// The beta project the card's open button shows, or nil.
  var projectID: String? { card?.projectID }

  /// Reads the card state. Called on foreground. A failed read hides the
  /// card, as `member: false` does.
  func refresh() async {
    guard TaskBackendClient.hasSession else { apply(nil); return }
    do {
      let state = try await TaskBackendClient.shared.betaState(platform: Self.platform)
      guard state.member, let copy = state.copy else { apply(nil); return }
      let project = state.projectId?.trimmingCharacters(in: .whitespacesAndNewlines)
      apply(BetaCard(copy: copy, projectID: project?.isEmpty == false ? project : nil,
                     dismissedAt: state.cardDismissedAt))
    } catch {
      apply(nil)
    }
  }

  /// Closes the Today card for good (open, or not now). Optimistic: a
  /// refused write reads the server's state again.
  func dismissCard() {
    guard var next = card, next.dismissedAt == nil else { return }
    next.dismissedAt = (Date().timeIntervalSince1970 * 1000).rounded()
    apply(next)
    Task { @MainActor in
      do {
        try await TaskBackendClient.shared.betaProgress(BetaWire.Progress())
      } catch {
        await refresh()
      }
    }
  }

  /// Stores the new state. Both task lists rebuild Today's notices on
  /// `.septenaTasksChanged`, so a change to the card posts it.
  private func apply(_ next: BetaCard?) {
    guard next != card else { return }
    let cardBefore = showsCard
    card = next
    if showsCard != cardBefore {
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
  }

  /// The `platform` query value.
  private static var platform: String {
    #if os(macOS)
    return "macos"
    #else
    return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
    #endif
  }
}
