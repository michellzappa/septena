import Foundation

/// Which product shell this process runs as. SeptenaCore compiles into every
/// app target by source inclusion, and `SeptenaServices.start()` wires the
/// whole life-OS by default — the Septask target (a focused task app over the
/// same CloudKit data, see docs/SEPTASK.md) must not bind non-task mutators or
/// the third-party provider stores (Oura / Withings / Readwise).
///
/// Compile-time, not a mutable global, so there is no ordering hazard between
/// the app scene and a background-launched App Intent: the Septask target sets
/// the `SEPTASK` compilation condition in project.yml and every call site in
/// the process agrees from the first instruction.
///
/// Note this gates BINDING, not sync: CKSyncEngine fetches the whole
/// `septena-v1` zone, so a tasks-only process still mirrors every record type
/// locally (invisible without UI). Filtering at apply time would just discard
/// data the next full-profile fetch has to re-pull; the mirror is private to
/// the app sandbox either way.
public enum RuntimeProfile {
  case full
  case tasksOnly

  public static var current: RuntimeProfile {
    #if SEPTASK
    return .tasksOnly
    #else
    return .full
    #endif
  }

  public var isTasksOnly: Bool { self == .tasksOnly }
}
