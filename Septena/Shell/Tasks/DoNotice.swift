import SwiftUI

// The Do notice of the SwiftUI task lists (docs/DO_SPEC.md §5 and §2.2): the
// device that does not show the Do screen shows one line, in the notice slot
// and in the notice style (`TaskListNotice`). It cannot be dismissed, it does
// not pulse, and its color never changes.

/// The text and icon of a Do action, from the registry.
struct DoActionLabel: View {
  let id: RegistryActionID

  init(_ id: RegistryActionID) { self.id = id }

  var body: some View {
    Label(RegistryActions.title(id), systemImage: RegistryActions.sfSymbols[id] ?? "")
  }
}

struct DoNotice: View {
  let doing: DoState
  let onDone: () -> Void
  let onStop: () -> Void
  let onLater: () -> Void

  private var symbol: String { RegistryIcons.sfSymbol(for: "action.do", on: true) }

  var body: some View {
    if doing.isStale {
      // The stale question: asked once, answered in place.
      TaskListNotice(kind: .info, symbol: symbol,
                     title: Text(RegistryDoing.stale(title: doing.title))) {
        FlowLayout(spacing: 8) {
          Button(RegistryActions.title(.doDone), action: onDone)
          Button(RegistryActions.title(.doStop), action: onStop)
          Button(RegistryActions.title(.doConfirm)) {
            Haptics.commit()
            DoStore.shared.confirm(sessionID: doing.sessionID)
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    } else {
      Menu {
        Button(action: onDone) { DoActionLabel(.doDone) }
        Button(action: onStop) { DoActionLabel(.doStop) }
        Button(action: onLater) { DoActionLabel(.doLater) }
        Button {
          Haptics.press()
          DoStore.shared.showHere()
        } label: { DoActionLabel(.doHere) }
      } label: {
        // Whole minutes, on the minute of the Do.
        TimelineView(.periodic(from: doing.startedAt, by: 60)) { timeline in
          TaskListNotice(kind: .info, symbol: symbol, title: line(at: timeline.date))
        }
        .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
    }
  }

  private func line(at now: Date) -> Text {
    Text(verbatim: [RegistryDoing.notice(title: doing.title), doing.timeText(at: now)]
      .joined(separator: " · "))
  }
}
