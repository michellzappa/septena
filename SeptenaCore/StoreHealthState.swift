import Foundation
import Observation

/// The observable face of `StoreHealth`, so the UI can say that a write was
/// lost instead of leaving the user to guess.
///
/// `StoreHealth` is an enum of statics — accounting, readable from anywhere,
/// observable by nothing. That was the whole problem: a failed save rolled the
/// context back, incremented a counter no view read, and wrote one line to
/// Console. The user saw a task they had typed simply not be there, with no way
/// to tell a lost write from their own mistake ("saving inbox items is flaky").
///
/// This class mirrors the same facts into `@Observable` state. It owns no
/// policy: `StoreHealth` still decides what a failure is and still does the
/// rollback. Nothing here can affect whether a write lands.
@MainActor
@Observable
public final class StoreHealthState {
  public static let shared = StoreHealthState()

  /// One lost write, as the UI needs to describe it.
  public struct Failure: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// `StoreHealth.detail(error)` plus the op name — the engineering summary.
    /// Shown only on the diagnostics surface, never in the alert: it names
    /// entities and attributes, which is noise to the person who just lost a
    /// task.
    public let summary: String
    public let at: Date
  }

  /// Monotonic count for this process, mirroring `StoreHealth.saveFailures`.
  public private(set) var saveFailures = 0

  /// The most recent failure, for the diagnostics surface.
  public private(set) var lastFailure: Failure?

  /// The failure the UI has not yet told the user about. A surface presents it
  /// and calls `acknowledge()`; until then it stays set, so a failure that
  /// happens while no task surface is on screen is still reported when one
  /// appears rather than being silently dropped.
  public private(set) var unreportedFailure: Failure?

  /// Posted on every rolled-back save, for surfaces that cannot observe
  /// `@Observable` state: Septena's Mac shell is pure AppKit
  /// (`SeptaskKitWindow`), with no SwiftUI view to hang an alert on. SwiftUI
  /// surfaces use `.storeHealthAlert()` and ignore this.
  public static let failureNotification = Notification.Name("SeptenaStoreHealthSaveFailed")

  private init() {}

  /// Called from `StoreHealth.noteSaveFailure`. Not for anyone else — a caller
  /// that reported its own failure here would make the count disagree with the
  /// number of writes actually rolled back.
  func noteSaveFailure(_ summary: String) {
    let failure = Failure(summary: summary, at: Date())
    saveFailures += 1
    lastFailure = failure
    unreportedFailure = failure
    NotificationCenter.default.post(name: Self.failureNotification, object: nil)
  }

  /// The user has been told. Clears the pending report, leaving the running
  /// count and `lastFailure` for the diagnostics surface.
  public func acknowledge() {
    unreportedFailure = nil
  }

  /// What to say to the person whose work just went missing. Deliberately not
  /// the error text: it names SwiftData entities and attributes, which tells
  /// them nothing and reads as a crash. This says what happened to their data
  /// and what to do, which is all they can act on. The words are the registry
  /// prompt `changeNotSaved` (`registry/surfaces.json`), which Android shows
  /// for the same event.
  public static var alertTitle: String { copy?.title ?? "" }
  public static var alertMessage: String { copy?.message ?? "" }
  private static var copy: RegistryPromptCopy? { RegistryPrompts.fixed[.changeNotSaved] }

  /// Writes the backend refused this process (#617): the sync engine took the
  /// op out of its outbox, and the next pull puts the backend's row back, so
  /// the edit is gone. Kept apart from `saveFailures`, which counts local
  /// rollbacks only.
  public private(set) var refusedWrites = 0

  /// Called from `TaskSyncEngine` when the backend refuses a write. The same
  /// alert as a rolled-back save: for the user the result is the same.
  func noteRefusedWrite(_ summary: String) {
    let failure = Failure(summary: summary, at: Date())
    refusedWrites += 1
    lastFailure = failure
    unreportedFailure = failure
    NotificationCenter.default.post(name: Self.failureNotification, object: nil)
  }
}
