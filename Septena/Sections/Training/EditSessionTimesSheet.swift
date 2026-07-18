import SwiftUI

/// Edit start / end times for a logged training session bucket
/// (`date` + `sessionType`). Start is stored as `concludedAt` on every entry;
/// end is stored as `endedAt` on the concluding entry only.
struct SessionTimesEditContext: Identifiable, Hashable {
  let date: String
  let session: String
  let entries: [ExerciseEntry]
  var id: String { "\(date)|\(session)" }
}

struct EditSessionTimesSheet: View {
  private var trainingMutator: TrainingMutator { SeptenaServices.shared.trainingMutator }

  let context: SessionTimesEditContext
  let onSave: () -> Void

  @State private var startedAt = Date()
  @State private var endedAt = Date()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    AdaptiveEditScaffold(title: "Session times", canSave: !context.entries.isEmpty, onSave: save) {
      Form {
        Section {
          Text(context.session.capitalized.isEmpty ? "Untagged" : context.session.capitalized)
            .foregroundStyle(.secondary)
          Text(friendlyDate(context.date))
            .foregroundStyle(.secondary)
        }
        Section("Started") {
          SteppedDatePicker(selection: $startedAt, displayedComponents: .hourAndMinute)
        }
        Section("Finished") {
          SteppedDatePicker(selection: $endedAt, displayedComponents: .hourAndMinute)
        }
        if let mins = durationMinutes {
          Section {
            Text("\(mins) min total")
              .foregroundStyle(.secondary)
          }
        }
      }
      .onAppear { seed() }
    }
  }

  private var durationMinutes: Int? {
    let secs = endedAt.timeIntervalSince(startedAt)
    guard secs > 0 else { return nil }
    return Int((secs / 60).rounded())
  }

  private func seed() {
    let entries = context.entries
    if let stamp = entries.compactMap(\.concludedAt).first,
       let d = EventTimestamp.fromLocalISO(stamp) {
      startedAt = d
    } else {
      startedAt = EventTimestamp.from(date: context.date, time: EventTimestamp.hhmm(from: Date()))
    }

    if let stamp = entries.compactMap(\.endedAt).first,
       let d = EventTimestamp.fromLocalISO(stamp) {
      endedAt = d
    } else {
      endedAt = derivedEnd(entries: entries, started: startedAt)
    }
  }

  private func derivedEnd(entries: [ExerciseEntry], started: Date) -> Date {
    let iso = ISO8601DateFormatter()
    if let latest = entries.compactMap(\.loggedAt).compactMap({ iso.date(from: $0) }).max() {
      return latest
    }
    return started.addingTimeInterval(45 * 60)
  }

  private func save() {
    guard endedAt >= startedAt else {
      Haptics.warning()
      return
    }
    let startStamp = EventTimestamp.localISO(from: startedAt)
    let endStamp = EventTimestamp.localISO(from: endedAt)
    trainingMutator.setSessionStartedAt(
      date: context.date, sessionType: context.session, startedAt: startStamp)
    trainingMutator.setSessionEndedAt(
      date: context.date, sessionType: context.session, endedAt: endStamp)
    Haptics.success()
    onSave()
    dismiss()
  }

  private func friendlyDate(_ iso: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = .current
    guard let d = f.date(from: iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
    return f.string(from: d)
  }
}
