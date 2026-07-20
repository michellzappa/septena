import SwiftUI

/// Edit a logged training session bucket (`date` + `sessionType`): its
/// category, its start / end times, and — by tapping through — the individual
/// exercises logged in it. Start is stored as `concludedAt` on every entry;
/// end is stored as `endedAt` on the concluding entry only; the category is a
/// bulk retag of the whole date.
struct SessionEditContext: Identifiable, Hashable {
  let date: String
  let session: String
  let entries: [ExerciseEntry]
  var id: String { "\(date)|\(session)" }
}

struct EditSessionSheet: View {
  private var trainingMutator: TrainingMutator { SeptenaServices.shared.trainingMutator }

  let context: SessionEditContext
  /// Display strings come from the destination view so the sheet renders the
  /// same canonical exercise names and detail lines as the list behind it.
  let title: (ExerciseEntry) -> String
  let detail: (ExerciseEntry) -> String
  /// Called after a save with the (possibly new) session type. The parent
  /// patches its local `entries` so the list and charts re-bucket immediately.
  let onSave: (String) -> Void
  let onEntryUpdated: (ExerciseEntry) -> Void

  @Environment(TrainingDraftStore.self) private var draftStore

  @State private var startedAt = Date()
  @State private var endedAt = Date()
  @State private var sessionType = ""
  @State private var entries: [ExerciseEntry] = []
  @State private var editingEntry: ExerciseEntry?

  var body: some View {
    AdaptiveEditScaffold(title: "Session", canSave: !context.entries.isEmpty, onSave: save) {
      Form {
        Section("Category") {
          Picker("Category", selection: $sessionType) {
            ForEach(draftStore.sessionTypes.filter { !$0.archived }, id: \.id) { st in
              Label(st.label, systemImage: st.kind.icon).tag(st.id)
            }
            Label("Untagged", systemImage: "questionmark.circle").tag("")
          }
          Text(friendlyDate(context.date))
            .foregroundStyle(.secondary)
        }
        // Start, end and the resulting duration read as one fact, so they get
        // one row: both pickers are compact chips, and the duration is the
        // trailing readout rather than a section of its own.
        Section("Time") {
          HStack(spacing: 8) {
            SteppedDatePicker(selection: $startedAt, displayedComponents: .hourAndMinute)
            Text("–").foregroundStyle(.secondary)
            SteppedDatePicker(selection: $endedAt, displayedComponents: .hourAndMinute)
            Spacer(minLength: 8)
            if let mins = durationMinutes {
              Text("\(mins) min")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          }
        }
        Section("Exercises") {
          if entries.isEmpty {
            Text("Nothing logged.").foregroundStyle(.secondary)
          }
          ForEach(entries) { entry in
            if entry.file != nil {
              Button {
                editingEntry = entry
              } label: {
                exerciseRow(entry)
              }
              .buttonStyle(.plain)
            } else {
              exerciseRow(entry)
            }
          }
        }
      }
      .onAppear { seed() }
    }
    .adaptiveDetail(item: $editingEntry) { entry in
      EditExerciseEntrySheet(
        original: entry,
        onSave: { updated in
          if let idx = entries.firstIndex(where: { $0.id == updated.id }) {
            entries[idx] = updated
          }
          onEntryUpdated(updated)
        }
      )
    }
  }

  @ViewBuilder
  private func exerciseRow(_ entry: ExerciseEntry) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title(entry))
      let line = detail(entry)
      if !line.isEmpty {
        Text(line).font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  private var durationMinutes: Int? {
    let secs = endedAt.timeIntervalSince(startedAt)
    guard secs > 0 else { return nil }
    return Int((secs / 60).rounded())
  }

  private func seed() {
    entries = context.entries
    sessionType = context.session

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

  /// Times first (keyed by the *old* session type), then the retag — doing it
  /// the other way round would leave the time writes pointing at a bucket that
  /// no longer exists.
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
    if sessionType != context.session {
      _ = trainingMutator.retagSession(date: context.date, to: sessionType)
    }
    Haptics.success()
    onSave(sessionType)
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
