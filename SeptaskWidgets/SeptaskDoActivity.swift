#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

/// The floating Do (docs/DO_SPEC.md §4.2): the title and the time. A tap opens
/// the app on the Do screen. The time counts up in whole minutes, and a stale
/// Do shows none.
struct SeptaskDoActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DoActivityAttributes.self) { context in
      HStack(spacing: 12) {
        Image(systemName: context.attributes.symbol).accessibilityHidden(true)
        Text(context.state.title).font(.headline).lineLimit(2)
        Spacer(minLength: 8)
        DoActivityTime(context: context)
      }
      .padding(16)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: context.attributes.symbol).accessibilityHidden(true)
        }
        DynamicIslandExpandedRegion(.trailing) { DoActivityTime(context: context) }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.state.title).font(.headline).lineLimit(2)
        }
      } compactLeading: {
        Image(systemName: context.attributes.symbol).accessibilityHidden(true)
      } compactTrailing: {
        DoActivityTime(context: context).frame(maxWidth: 64)
      } minimal: {
        Image(systemName: context.attributes.symbol).accessibilityLabel(Text(verbatim: context.state.title))
      }
    }
  }
}

private struct DoActivityTime: View {
  let context: ActivityViewContext<DoActivityAttributes>

  var body: some View {
    if !context.isStale {
      Text(.currentDate, format: .offset(to: context.attributes.startedAt, allowedFields: [.hour, .minute],
                                         maxFieldCount: 1, sign: .never))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .multilineTextAlignment(.trailing)
    }
  }
}
#endif
