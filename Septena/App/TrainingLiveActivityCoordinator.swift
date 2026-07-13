#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation
import os

@MainActor
final class TrainingLiveActivityCoordinator {
  static let shared = TrainingLiveActivityCoordinator()

  private init() {}

  func reconcile(with draft: DraftSession?) {
    guard let draft else {
      Task { await endAll(immediate: true) }
      return
    }
    Task {
      if Activity<TrainingActivityAttributes>.activities.isEmpty {
        await startActivity(for: draft)
      } else {
        await updateActivity(from: draft)
      }
    }
  }

  func start(for draft: DraftSession) {
    Task { await startActivity(for: draft) }
  }

  func update(from draft: DraftSession) {
    Task { await updateActivity(from: draft) }
  }

  func end(from draft: DraftSession?, immediate: Bool) {
    Task {
      let state = draft.map(Self.contentState(for:))
      await endAll(finalState: state, immediate: immediate)
    }
  }

  private func startActivity(for draft: DraftSession) async {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    await endActivities(notMatching: draft.liveActivitySessionID)
    if Activity<TrainingActivityAttributes>.activities.contains(where: {
      $0.attributes.sessionID == draft.liveActivitySessionID
    }) {
      await updateActivity(from: draft)
      return
    }

    do {
      _ = try Activity.request(
        attributes: TrainingActivityAttributes(
          sessionID: draft.liveActivitySessionID,
          sessionType: draft.sessionType,
          sessionLabel: draft.label,
          startedAt: draft.startedAtDate ?? Date(),
          sessionIcon: draft.sessionKind.icon,
          accentToken: SectionTheme().token(for: "training")
        ),
        content: ActivityContent(state: Self.contentState(for: draft), staleDate: nil),
        pushType: nil
      )
    } catch {
      Log.liveActivity.error("start failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func updateActivity(from draft: DraftSession) async {
    let matching = Activity<TrainingActivityAttributes>.activities.filter {
      $0.attributes.sessionID == draft.liveActivitySessionID
    }
    if matching.isEmpty {
      await startActivity(for: draft)
      return
    }
    let content = ActivityContent(state: Self.contentState(for: draft), staleDate: nil)
    for activity in matching {
      await activity.update(content)
    }
  }

  private func endAll(finalState: TrainingActivityAttributes.ContentState? = nil,
                      immediate: Bool) async {
    for activity in Activity<TrainingActivityAttributes>.activities {
      let content = ActivityContent(
        state: finalState ?? TrainingActivityAttributes.ContentState(
          doneCount: 0,
          totalCount: 0,
          nextExercise: nil,
          cardioMinutes: 0,
          lifted: 0,
          liftedUnit: WeightUnit.current.suffix
        ),
        staleDate: nil
      )
      await activity.end(content, dismissalPolicy: immediate ? .immediate : .default)
    }
  }

  private func endActivities(notMatching sessionID: String) async {
    for activity in Activity<TrainingActivityAttributes>.activities
    where activity.attributes.sessionID != sessionID {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }

  private static func contentState(for draft: DraftSession) -> TrainingActivityAttributes.ContentState {
    let unit = WeightUnit.current
    return TrainingActivityAttributes.ContentState(
      doneCount: draft.doneCount,
      totalCount: draft.totalCount,
      nextExercise: draft.nextPendingIndex.map { draft.entries[$0].exercise.liveActivityDisplayName },
      cardioMinutes: Int(draft.completedCardioMinutes.rounded()),
      lifted: Int(unit.display(draft.completedLiftedKg).rounded()),
      liftedUnit: unit.suffix
    )
  }
}

private extension DraftSession {
  var liveActivitySessionID: String {
    "\(date)|\(time)|\(sessionType)"
  }

  var startedAtDate: Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: startedAt)
  }

  var completedCardioMinutes: Double {
    entries
      .filter { $0.status == .done && $0.isCardio }
      .reduce(0) { $0 + ($1.durationMin ?? 0) }
  }

  var completedLiftedKg: Double {
    entries
      .filter { $0.status == .done && !$0.isCardio }
      .reduce(0) { acc, entry in
        let sets = Double(entry.sets ?? 0)
        let reps = Double(entry.reps.flatMap { Int($0) } ?? 0)
        return acc + (entry.weight ?? 0) * sets * reps
      }
  }
}

private extension String {
  var liveActivityDisplayName: String {
    replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .capitalized
  }
}
#endif
