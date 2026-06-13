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
      TrainingLockScreenView(context: context)
        .padding(16)
        .widgetURL(URL(string: "septena://training/active"))
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
          Text(timerInterval: context.attributes.startedAt...Date.distantFuture,
               countsDown: false)
            .font(.caption.monospacedDigit())
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(context.state.doneCount),
                         total: Double(max(context.state.totalCount, 1)))
            if let next = context.state.nextExercise {
              Text("Next: \(next)")
                .font(.caption)
                .lineLimit(1)
            }
          }
        }
      } compactLeading: {
        Image(systemName: context.attributes.sessionIcon)
      } compactTrailing: {
        Text(timerInterval: context.attributes.startedAt...Date.distantFuture,
             countsDown: false)
          .font(.caption2.monospacedDigit())
          .frame(maxWidth: 44)
      } minimal: {
        Image(systemName: context.attributes.sessionIcon)
      }
      .widgetURL(URL(string: "septena://training/active"))
    }
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
          if let next = context.state.nextExercise {
            Text("Next: \(next)")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        Text(timerInterval: context.attributes.startedAt...Date.distantFuture,
             countsDown: false)
          .font(.headline.monospacedDigit())
          .lineLimit(1)
      }

      ProgressView(value: Double(context.state.doneCount),
                   total: Double(max(context.state.totalCount, 1)))

      HStack(spacing: 18) {
        metric(progressText(context.state), "done")
        metric("\(context.state.cardioMinutes)m", "cardio")
        metric("\(context.state.liftedKg)kg", "lifted")
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

private func progressText(_ state: TrainingActivityAttributes.ContentState) -> String {
  "\(state.doneCount)/\(max(state.totalCount, 1))"
}
