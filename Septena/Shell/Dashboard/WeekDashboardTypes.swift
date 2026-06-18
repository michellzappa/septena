// Week module — the synthesizing dashboard. Each module gets a tile that
// (a) renders live stats / histogram for that module and (b) pushes into
// the module's full destination on tap. Tiles for modules that don't yet
// have a Swift mini-app stay mocked + inert until those are built — but
// every accent comes from SectionTheme so colors match the user's
// server-configured Septena palette today.

enum WeekDestination: String, Hashable, Identifiable {
  case habits, chores, training, supplements, sleep, nutrition
  case hydration
  case groceries, body, gut
  case intake
  case mood
  case symptoms
  case medications
  case activity
  case github
  case insights
  /// Tasks-as-drawer. Mirrors every other section's bottom-sheet behaviour
  /// for users who prefer not to lose the homepage when they peek at today.
  /// The full Tasks tab is still reachable via the long-press menu and via
  /// the Settings > Tasks > Open in picker.
  case tasks

  var id: String { rawValue }
}

/// Sub-sheets presented from the Nutrition QuickAdd menu. Separate state
/// from `sheetDest` (destination views) so each affordance is self-contained.
enum NutritionSheet: Hashable, Identifiable {
  case search        // history search modal
  case newEntry      // blank meal-form sheet

  var id: Self { self }
}
