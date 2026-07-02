// The app's top-level tabs. Extracted from RootTabView.swift so shells that
// don't compile the tab bar (Septask) can still reference the type
// (NavigationState.pendingTab) — see docs/SEPTASK.md.

enum SeptenaTab: Hashable {
  case week, next, tasks, goals

  /// Stable, low-cardinality screen name for telemetry. Kept here so the
  /// dashboard's labels match the enum even if the tab's display title
  /// changes.
  var analyticsName: String {
    switch self {
    case .week:  return "week"
    case .next:  return "next"
    case .tasks: return "tasks"
    case .goals: return "goals"
    }
  }
}
