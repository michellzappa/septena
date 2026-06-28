import Testing
import Foundation

@Suite struct TrainingSessionSpansTests {

  @Test func cardioSpanUsesDuration() {
    let span = TrainingSessionSpans.entrySpan(.init(
      date: "2026-06-15",
      concludedAt: "2026-06-15T07:00:00",
      durationMin: 30
    ))
    #expect(span?.startHour == 7)
    #expect(span?.endHour == 7.5)
  }

  @Test func strengthSpanWithoutDurationUsesStartOnly() {
    let span = TrainingSessionSpans.entrySpan(.init(
      date: "2026-06-15",
      concludedAt: "2026-06-15T07:00:00"
    ))
    #expect(span?.startHour == 7)
    #expect(span?.endHour == 7)
  }

  @Test func mergeJoinsNearAdjacentSpans() {
    let a = TrainingSessionSpans.Span(startHour: 7, endHour: 8)
    let b = TrainingSessionSpans.Span(startHour: 8.5, endHour: 9)
    let merged = TrainingSessionSpans.merge([a, b])
    #expect(merged.count == 1)
    #expect(merged[0].startHour == 7)
    #expect(merged[0].endHour == 9)
  }

  @Test func mergeSplitsDistantSpans() {
    let a = TrainingSessionSpans.Span(startHour: 7, endHour: 8)
    let b = TrainingSessionSpans.Span(startHour: 10, endHour: 11)
    let merged = TrainingSessionSpans.merge([a, b])
    #expect(merged.count == 2)
  }

  @Test func minimumWidthAddsThreeMinutes() {
    let clamped = TrainingSessionSpans.withMinimumWidth(
      .init(startHour: 7, endHour: 7))
    #expect(clamped.endHour == 7.05)
  }

  @Test func sessionsFiltersByDate() {
    let entries: [TrainingSessionSpans.Entry] = [
      .init(date: "2026-06-15", concludedAt: "2026-06-15T07:00:00", durationMin: 60),
      .init(date: "2026-06-14", concludedAt: "2026-06-14T18:00:00", durationMin: 45),
    ]
    let spans = TrainingSessionSpans.sessions(on: "2026-06-15", entries: entries)
    #expect(spans.count == 1)
    #expect(spans[0].startHour == 7)
    #expect(spans[0].endHour == 8)
  }
}
