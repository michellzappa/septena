import SwiftUI

// CaffeineCommit — the single commit funnel for the Caffeine section.
//
// Many doors in, one hallway out: every on-screen way to log a coffee — the
// capture page, the dashboard tile's "Repeat", the section drawer's quick-log
// ("Log V60/Matcha/other"), the edit sheet's create mode — ends here. The
// funnel owns the write, the haptic, the tile refresh, and the affect-matched
// flourish, so behavior can't drift between entry points (the reason the
// celebration used to fire on only one of them).
//
// This is the template for the rest of the sections' commit funnels. UI paths
// only for now — App Intents / the MCP gateway keep their direct mutator
// writes (no UI to animate).

@MainActor
enum CaffeineCommit {
  private static var mutator: CaffeineMutator { SeptenaServices.shared.caffeineMutator }

  /// Affect axis: a caffeine log is a warm cup, so daytime gets a gentle
  /// bloom; late at night a stimulant log gets a quiet sink instead —
  /// acknowledged, not celebrated. Keyed off the hour the entry is logged
  /// *for* (parsed from `time`), so a backfilled 11pm log still reads as
  /// late. No `.snap`: its full-screen flash is too loud for a drink logged
  /// several times a day.
  static func motion(forTime time: String) -> CommitMotion {
    let hour = Int(time.prefix(2)) ?? 12
    return (hour >= 21 || hour < 5) ? .sink : .bloom
  }

  /// Dose → loudness. ~18g (a typical pour) is the calibrated 1.0; clamped
  /// so a small cup still reads and a big brew can't overpower.
  static func intensity(grams: Double?) -> Double {
    min(1.3, max(0.7, (grams ?? 16) / 18))
  }

  /// Log a NEW caffeine entry. The non-blocking commit path: the write +
  /// success haptic + VoiceOver announce fire, then the flourish plays at
  /// the app root over whatever's behind. Returns the new entry's id (the
  /// edit sheet uses it to build its optimistic DTO).
  ///
  /// `logCommit` is optional — hosts that don't inherit the root environment
  /// pass nil and simply skip the visual; the write + haptic still confirm.
  @discardableResult
  static func logNew(date: String = SeptenaDate.today,
                     time: String = SeptenaDate.nowHHMM,
                     method: String,
                     beans: String?,
                     grams: Double?,
                     note: String? = nil,
                     accent: Color,
                     logCommit: LogCommitCenter?) -> String {
    var id = ""
    // Routes through the shared SectionLog funnel. Caffeine's default motion
    // (.bloom) lives in CaffeinePlugin.logFlourish; we override per-call with
    // the time-of-day rule (late-night → sink) and the dose-scaled intensity.
    SectionLog.newLog(
      section: "caffeine",
      accent: accent,
      motion: motion(forTime: time),
      intensity: intensity(grams: grams),
      announce: "Logged \(beans ?? method.uppercased()).",
      logCommit: logCommit
    ) {
      // note defaults to "" (not nil) so the field registers with CloudKit
      // on first in-app write — see CaffeineMutator.addEntry.
      let entity = mutator.addEntry(date: date, time: time, method: method,
                                    beans: beans, grams: grams, note: note ?? "")
      id = entity.id
      AddInfoSection.caffeine.notifyTilesChanged()
    }
    return id
  }

  /// Edit an existing entry. A correction, not a fresh log — quiet haptic,
  /// no celebration. (Dismissal is owned by AdaptiveEditScaffold, so this
  /// must not dismiss.)
  static func update(id: String,
                     date: String,
                     time: String,
                     method: String,
                     beans: String?,
                     grams: Double?,
                     note: String?) {
    SectionLog.edit {
      mutator.updateEntry(id: id, date: date, time: time, method: method,
                          beans: .some(beans), grams: .some(grams), note: .some(note))
      AddInfoSection.caffeine.notifyTilesChanged()
    }
  }
}
