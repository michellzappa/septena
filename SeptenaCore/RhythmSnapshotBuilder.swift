import Foundation
import SwiftData

/// Builds the `RhythmWire` snapshot the time-wheel widget renders — the
/// front-door day dial: **today's** timestamped events (every enabled section)
/// plus the day's training-session bands. (Built with `windowDays: 1` from the
/// publisher; the wire keeps `windowDays` general in case a multi-day dial ever
/// wants it.)
///
/// Derives from the same SwiftData primitives the in-app dials use:
/// `LoggedEvents.timed` (the shared, section-keyed projection), completed
/// tasks at their `completedAt`, intake plotted per *kind* color, and training
/// merged into session bands. The per-source logic mirrors `RhythmData` in
/// `Septena/Shell/Dashboard/RhythmHomepageView.swift` — **keep the two in
/// sync**: both answer "what dots/bands does the wheel show," this one off-view
/// for the published snapshot (no `Color`, no Oura sleep, no EventKit calendar
/// — those need surfaces the background publisher can't cheaply reach).
@MainActor
enum RhythmSnapshotBuilder {
  private static let ymd: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
    return f
  }()
  private static let isoLocal: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.timeZone = .current
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  /// Build the snapshot for `todayStart` (start-of-day) over `windowDays`.
  /// `sections` is the user's mirrored section list (`SettingsMirror.loadSections`)
  /// — only enabled sections plot, each in its own authored color.
  /// `wakingDay` rolls the wheel over at wake instead of midnight (the same
  /// lens the in-app dials use; see `WakingDay`). The background builder has no
  /// Oura sleep data, so it degrades to the documented 4am cutoff — `todayStart`
  /// must be a `dayKey` from the same resolver. Pass `WakingDay(enabled: false)`
  /// for the legacy midnight buckets.
  static func build(context: ModelContext,
                    sections: [SectionConfig],
                    todayStart: Date,
                    windowDays: Int = 7,
                    wakingDay: WakingDay = WakingDay(enabled: true, cutoffHour: 4)) -> RhythmWire {
    let cal = Calendar.current
    let weekStart = cal.date(byAdding: .day, value: -(windowDays - 1), to: todayStart) ?? todayStart

    let enabled = sections.filter { $0.isEnabled }
    let colorHex = Dictionary(enabled.map { ($0.key, $0.color) }, uniquingKeysWith: { a, _ in a })
    let visible = Set(enabled.map { $0.key })

    var events: [RhythmWire.Event] = []
    var bands: [RhythmWire.Band] = []

    // 1) Logged events on the shared section-keyed projection (gut, mood,
    //    chores, habits, supplements, nutrition). Training is a duration, not
    //    an instant — pulled out below; intake is omitted here (per-kind color).
    for t in LoggedEvents.timed(since: weekStart, in: context)
    where visible.contains(t.sectionKey) && t.sectionKey != "training" {
      guard let e = event(id: t.id, occurredAt: t.occurredAt, todayStart: todayStart,
                          windowDays: windowDays, colorHex: colorHex[t.sectionKey],
                          wakingDay: wakingDay) else { continue }
      events.append(e)
    }

    // 2) Completed tasks as dots, placed at their local `completedAt` —
    //    mirrors `DayTimelineView` / `RhythmData.taskEvents`.
    if visible.contains("tasks") {
      let rows = (try? context.fetch(
        FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.statusRaw == "done" && $0.deletedAt == nil })
      )) ?? []
      for t in rows {
        guard let cs = t.completedAt, let when = isoLocal.date(from: cs),
              let e = event(id: t.id, occurredAt: when, todayStart: todayStart,
                            windowDays: windowDays, colorHex: colorHex["tasks"],
                            wakingDay: wakingDay) else { continue }
        events.append(e)
      }
    }

    // 3) Intake events, each tinted by its *kind*'s own color (coffee, matcha,
    //    …), falling back to the section accent — mirrors `RhythmData.intakeEvents`.
    if visible.contains("intake") {
      let rows = (try? context.fetch(
        FetchDescriptor<IntakeEventEntity>(predicate: #Predicate { $0.occurredAt >= weekStart })
      )) ?? []
      if !rows.isEmpty {
        let kinds = (try? context.fetch(FetchDescriptor<IntakeKindEntity>())) ?? []
        let kindColor = Dictionary(kinds.map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        for r in rows {
          guard let e = event(id: r.id, occurredAt: r.occurredAt, todayStart: todayStart,
                              windowDays: windowDays,
                              colorHex: kindColor[r.kindID] ?? colorHex["intake"],
                              wakingDay: wakingDay) else { continue }
          events.append(e)
        }
      }
    }

    // 4) Training as session pills (start → start+duration), gaps < 0.75h
    //    merged — mirrors `RhythmData.trainingBands`.
    if visible.contains("training") {
      bands = trainingBands(todayStart: todayStart, weekStart: weekStart,
                            windowDays: windowDays, colorHex: colorHex["training"],
                            wakingDay: wakingDay, context: context)
    }

    return RhythmWire(windowDays: windowDays, events: events, bands: bands)
  }

  /// `(fraction, daysAgo)` for an instant, bounded to the window. Mirrors
  /// `TimeOfDayWheel.Event.init?(occurredAt:todayStart:windowDays:)`.
  private static func event(id: String, occurredAt: Date, todayStart: Date,
                            windowDays: Int, colorHex: String?,
                            wakingDay: WakingDay) -> RhythmWire.Event? {
    guard occurredAt > .distantPast else { return nil }
    let cal = Calendar.current
    let daysAgo = wakingDay.daysAgo(occurredAt, todayKey: todayStart, calendar: cal)
    guard daysAgo >= 0, daysAgo < windowDays else { return nil }
    let c = cal.dateComponents([.hour, .minute], from: occurredAt)
    let fraction = (Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0)) / 1440
    return RhythmWire.Event(id: id, fraction: fraction, daysAgo: daysAgo, colorHex: colorHex)
  }

  private static func trainingBands(todayStart: Date, weekStart: Date, windowDays: Int,
                                    colorHex: String?, wakingDay: WakingDay,
                                    context: ModelContext) -> [RhythmWire.Band] {
    let rows = (try? context.fetch(
      FetchDescriptor<ExerciseEntryEntity>(predicate: #Predicate { $0.occurredAt >= weekStart })
    )) ?? []
    let cal = Calendar.current
    var out: [RhythmWire.Band] = []
    for (dateStr, dayRows) in Dictionary(grouping: rows, by: \.date) {
      guard let d = ymd.date(from: dateStr) else { continue }
      let daysAgo = wakingDay.daysAgo(d.addingTimeInterval(43_200), todayKey: todayStart, calendar: cal)
      guard daysAgo >= 0, daysAgo < windowDays else { continue }
      let spans = dayRows.compactMap { e -> (Double, Double)? in
        guard e.occurredAt > .distantPast else { return nil }
        let c = cal.dateComponents([.hour, .minute], from: e.occurredAt)
        let startH = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        return (startH, startH + (e.durationMin ?? 0) / 60)
      }.sorted { $0.0 < $1.0 }
      var merged: [(Double, Double)] = []
      for s in spans {
        if var last = merged.last, s.0 <= last.1 + 0.75 {
          last.1 = max(last.1, s.1); merged[merged.count - 1] = last
        } else {
          merged.append(s)
        }
      }
      for (i, m) in merged.enumerated() {
        out.append(RhythmWire.Band(
          id: "\(dateStr)-train-\(i)",
          start: m.0 / 24,
          end: min(max(m.1, m.0 + 0.05) / 24, 0.9999),
          daysAgo: daysAgo,
          colorHex: colorHex,
          opaque: true
        ))
      }
    }
    return out
  }
}
