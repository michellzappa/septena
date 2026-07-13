import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SeptenaLiveActivitiesBundle: WidgetBundle {
  var body: some Widget {
    TrainingLiveActivityWidget()
  }
}

struct TrainingLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TrainingActivityAttributes.self) { context in
      TrainingActivityRootView(context: context)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          VStack(alignment: .leading, spacing: 2) {
            Text(context.attributes.sessionLabel)
              .font(.caption.weight(.semibold))
              .lineLimit(1)
            Text(progressText(context.state))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          sessionTimer(startedAt: context.attributes.startedAt, font: .caption)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(context.state.doneCount),
                         total: Double(max(context.state.totalCount, 1)))
              .tint(trainingAccent(context.attributes))
            if let exercise = activeExerciseName(context.state) {
              Text(exercise)
                .font(.caption)
                .lineLimit(1)
            }
          }
        }
      } compactLeading: {
        Image(systemName: context.attributes.sessionIcon)
      } compactTrailing: {
        sessionTimer(startedAt: context.attributes.startedAt, font: .caption2)
          .frame(maxWidth: 44)
      } minimal: {
        Image(systemName: context.attributes.sessionIcon)
      }
      .widgetURL(URL(string: "septena://training/active"))
    }
    .supplementalActivityFamilies([.small])
  }
}

/// Routes lock-screen (`.medium`) vs watch Smart Stack (`.small`) layouts.
private struct TrainingActivityRootView: View {
  @Environment(\.activityFamily) private var activityFamily
  let context: ActivityViewContext<TrainingActivityAttributes>

  var body: some View {
    Group {
      switch activityFamily {
      case .small:
        TrainingWatchStackView(context: context)
      default:
        TrainingLockScreenView(context: context)
          .padding(16)
      }
    }
    .widgetURL(URL(string: "septena://training/active"))
  }
}

/// watchOS Smart Stack / app-switcher card — compact, exercise-forward.
private struct TrainingWatchStackView: View {
  let context: ActivityViewContext<TrainingActivityAttributes>

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Image(systemName: context.attributes.sessionIcon)
        .font(.body.weight(.semibold))
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 1) {
        Text(headline)
          .font(.headline)
          .lineLimit(1)
        HStack(spacing: 4) {
          if context.state.totalCount > 1 {
            Text(progressText(context.state))
            Text("·")
          }
          sessionTimer(startedAt: context.attributes.startedAt, font: .caption2)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }

      Spacer(minLength: 0)
    }
  }

  /// Pending exercise name when in flight; session label when wrapping up.
  private var headline: String {
    activeExerciseName(context.state) ?? context.attributes.sessionLabel
  }
}

private struct TrainingLockScreenView: View {
  let context: ActivityViewContext<TrainingActivityAttributes>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: context.attributes.sessionIcon)
          .font(.title3.weight(.semibold))
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 3) {
          Text(context.attributes.sessionLabel)
            .font(.headline)
            .lineLimit(1)
          if let exercise = activeExerciseName(context.state) {
            Text(exercise)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        sessionTimer(startedAt: context.attributes.startedAt, font: .headline)
      }

      ProgressView(value: Double(context.state.doneCount),
                   total: Double(max(context.state.totalCount, 1)))
        .tint(trainingAccent(context.attributes))

      HStack(spacing: 18) {
        metric(progressText(context.state), "done")
        metric("\(context.state.cardioMinutes)m", "cardio")
        metric("\(context.state.lifted)\(context.state.liftedUnit)", "lifted")
      }
    }
    .foregroundStyle(.primary)
  }

  private func metric(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value)
        .font(.caption.weight(.semibold).monospacedDigit())
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

private func activeExerciseName(_ state: TrainingActivityAttributes.ContentState) -> String? {
  guard let name = state.nextExercise, !name.isEmpty else { return nil }
  return name
}

private func progressText(_ state: TrainingActivityAttributes.ContentState) -> String {
  "\(state.doneCount)/\(max(state.totalCount, 1))"
}

private func trainingAccent(_ attributes: TrainingActivityAttributes) -> Color {
  AdaptiveColor.adaptive(attributes.accentToken)
    ?? AdaptiveColor.adaptive("#f97316")
    ?? .orange
}

private func sessionTimer(startedAt: Date, font: Font) -> some View {
  Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
    .font(font.monospacedDigit())
    .lineLimit(1)
}
