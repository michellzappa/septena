import SwiftUI

// The one place that lists the environment values every SHARED view depends on.
//
// Why this exists: `Septena` and `Septask` are separate composition roots over
// the same `Shell/` sources. A shared view that starts reading a new
// `@Environment(X.self)` compiles fine in both apps and then CRASHES AT LAUNCH
// in whichever root forgot to inject it — there is no compile-time link between
// "this view needs X" and "the app provides X". That hazard was being managed
// by a hand-maintained checklist in docs/SEPTASK.md, which is a list of things
// that cause launch crashes when someone forgets to read it.
//
// Routing both roots through one non-defaulted parameter list turns it into a
// compile error instead: add a dependency here and BOTH apps stop building
// until they supply it. That's the whole point — do not give these parameters
// default values, and do not let a root inject a shared dependency on its own.
//
// App-SPECIFIC values stay with their root (Septena's training draft, support
// store, and app lock; Septask's iPad chrome). Only things a `Shell/` view can
// reach belong here.

extension View {
  /// Inject every environment value shared `Shell/` views depend on.
  /// Applied by `SeptenaApp` and `SeptaskApp`; see the note above before adding
  /// a parameter.
  func septenaSharedEnvironment(
    navigation: NavigationState,
    theme: SectionTheme,
    settings: SettingsStore,
    dayClock: DayClock,
    logCommit: LogCommitCenter,
    services: SeptenaServices
  ) -> some View {
    self
      .environment(navigation)
      .environment(theme)
      .environment(settings)
      .environment(dayClock)
      .environment(logCommit)
      .environment(services.taskMutator)
      .environment(services.checklistMutator)
      .environment(services.areasMutator)
      .environment(services.projectsMutator)
      .environment(services.ckEngine)
  }
}
