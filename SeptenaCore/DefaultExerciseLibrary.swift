import Foundation

// Curated catalog of common exercises with muscle-group assignments.
// Two consumers:
//   1. ExerciseLibrarySheet — opt-in picker for the user to add canonical
//      entries to their catalog.
//   2. TrainingLibraryEnrichment — one-shot launch pass that fills in
//      `primaryMuscle` / `secondaryMuscles` on existing user exercises
//      whose slug matches a library entry, but only where those fields
//      are currently nil/empty. Never overwrites user data.
//
// Slugs are the canonical join key. Keep them stable; renaming a slug
// here will orphan any historical entries that point at it.

struct LibraryExercise: Hashable, Identifiable, Sendable {
  let id: String              // slug
  let name: String
  let type: String            // strength | cardio | mobility | core
  let primaryMuscle: Muscle?  // nil for cardio/mobility entries
  let secondaryMuscles: [Muscle]

  init(_ id: String, _ name: String, _ type: String,
       _ primary: Muscle?, _ secondaries: [Muscle] = []) {
    self.id = id
    self.name = name
    self.type = type
    self.primaryMuscle = primary
    self.secondaryMuscles = secondaries
  }
}

enum DefaultExerciseLibrary {
  static let all: [LibraryExercise] = [
    // Chest
    .init("bench-press",          "Bench Press",          "strength", .chest,     [.triceps, .shoulders]),
    .init("incline-bench-press",  "Incline Bench Press",  "strength", .chest,     [.shoulders, .triceps]),
    .init("dumbbell-press",       "Dumbbell Press",       "strength", .chest,     [.triceps, .shoulders]),
    .init("push-up",              "Push-Up",              "strength", .chest,     [.triceps, .shoulders, .core]),
    .init("chest-fly",            "Chest Fly",            "strength", .chest,     [.shoulders]),
    .init("dip",                  "Dip",                  "strength", .chest,     [.triceps, .shoulders]),

    // Back
    .init("pull-up",              "Pull-Up",              "strength", .back,      [.biceps]),
    .init("chin-up",              "Chin-Up",              "strength", .back,      [.biceps]),
    .init("lat-pulldown",         "Lat Pulldown",         "strength", .back,      [.biceps]),
    .init("barbell-row",          "Barbell Row",          "strength", .back,      [.biceps]),
    .init("dumbbell-row",         "Dumbbell Row",         "strength", .back,      [.biceps]),
    .init("cable-row",            "Cable Row",            "strength", .back,      [.biceps]),
    .init("face-pull",            "Face Pull",            "strength", .back,      [.shoulders]),

    // Shoulders
    .init("overhead-press",       "Overhead Press",       "strength", .shoulders, [.triceps, .core]),
    .init("dumbbell-shoulder-press", "Dumbbell Shoulder Press", "strength", .shoulders, [.triceps]),
    .init("lateral-raise",        "Lateral Raise",        "strength", .shoulders),
    .init("front-raise",          "Front Raise",          "strength", .shoulders),
    .init("rear-delt-fly",        "Rear Delt Fly",        "strength", .shoulders, [.back]),
    .init("arnold-press",         "Arnold Press",         "strength", .shoulders, [.triceps]),

    // Biceps
    .init("barbell-curl",         "Barbell Curl",         "strength", .biceps),
    .init("dumbbell-curl",        "Dumbbell Curl",        "strength", .biceps),
    .init("hammer-curl",          "Hammer Curl",          "strength", .biceps),
    .init("preacher-curl",        "Preacher Curl",        "strength", .biceps),
    .init("concentration-curl",   "Concentration Curl",   "strength", .biceps),

    // Triceps
    .init("tricep-extension",     "Tricep Extension",     "strength", .triceps),
    .init("skullcrusher",         "Skullcrusher",         "strength", .triceps),
    .init("tricep-pushdown",      "Tricep Pushdown",      "strength", .triceps),
    .init("close-grip-bench-press","Close-Grip Bench Press","strength", .triceps, [.chest]),

    // Quads
    .init("barbell-squat",        "Barbell Squat",        "strength", .quads,     [.glutes, .hamstrings, .core]),
    .init("front-squat",          "Front Squat",          "strength", .quads,     [.glutes, .core]),
    .init("leg-press",            "Leg Press",            "strength", .quads,     [.glutes, .hamstrings]),
    .init("lunge",                "Lunge",                "strength", .quads,     [.glutes, .hamstrings]),
    .init("bulgarian-split-squat","Bulgarian Split Squat","strength", .quads,     [.glutes]),
    .init("leg-extension",        "Leg Extension",        "strength", .quads),
    .init("hack-squat",           "Hack Squat",           "strength", .quads,     [.glutes]),

    // Hamstrings
    .init("deadlift",             "Deadlift",             "strength", .hamstrings,[.glutes, .back, .core]),
    .init("romanian-deadlift",    "Romanian Deadlift",    "strength", .hamstrings,[.glutes, .back]),
    .init("leg-curl",             "Leg Curl",             "strength", .hamstrings),
    .init("good-morning",         "Good Morning",         "strength", .hamstrings,[.glutes, .back]),

    // Glutes
    .init("hip-thrust",           "Hip Thrust",           "strength", .glutes,    [.hamstrings]),
    .init("glute-bridge",         "Glute Bridge",         "strength", .glutes,    [.hamstrings]),
    .init("sumo-deadlift",        "Sumo Deadlift",        "strength", .glutes,    [.hamstrings, .back]),
    .init("cable-kickback",       "Cable Kickback",       "strength", .glutes),

    // Calves
    .init("standing-calf-raise",  "Standing Calf Raise",  "strength", .calves),
    .init("seated-calf-raise",    "Seated Calf Raise",    "strength", .calves),

    // Core
    .init("plank",                "Plank",                "core",     .core),
    .init("hanging-leg-raise",    "Hanging Leg Raise",    "core",     .core),
    .init("crunch",               "Crunch",               "core",     .core),
    .init("russian-twist",        "Russian Twist",        "core",     .core),
    .init("dead-bug",             "Dead Bug",             "core",     .core),
    .init("hollow-hold",          "Hollow Hold",          "core",     .core),
    .init("ab-wheel",             "Ab Wheel Rollout",     "core",     .core),

    // Cardio — no muscle assignment; type alone is enough.
    .init("running",              "Running",              "cardio",   nil),
    .init("cycling",              "Cycling",              "cardio",   nil),
    .init("rowing",               "Rowing",               "cardio",   nil),
    .init("elliptical",           "Elliptical",           "cardio",   nil),
    .init("stair-climber",        "Stair Climber",        "cardio",   nil),
    .init("swimming",             "Swimming",             "cardio",   nil),
    .init("walking",              "Walking",              "cardio",   nil),
    .init("jumping-rope",         "Jumping Rope",         "cardio",   nil),

    // Mobility
    .init("foam-rolling",         "Foam Rolling",         "mobility", nil),
    .init("hip-mobility",         "Hip Mobility Flow",    "mobility", nil),
    .init("shoulder-mobility",    "Shoulder Mobility",    "mobility", nil),
    .init("ankle-mobility",       "Ankle Mobility",       "mobility", nil),
    .init("stretching",           "Stretching",           "mobility", nil),
  ]

  static let bySlug: [String: LibraryExercise] = {
    Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
  }()

  // Stable display order: strength grouped by muscle (in Muscle.allCases
  // order), then core, cardio, mobility. Matches the picker grouping.
  static let grouped: [(title: String, items: [LibraryExercise])] = {
    var out: [(String, [LibraryExercise])] = []
    for muscle in Muscle.allCases {
      let items = all.filter { $0.type == "strength" && $0.primaryMuscle == muscle }
      if !items.isEmpty { out.append((muscle.label, items)) }
    }
    let coreItems = all.filter { $0.type == "core" }
    if !coreItems.isEmpty { out.append(("Core (isometric)", coreItems)) }
    let cardio = all.filter { $0.type == "cardio" }
    if !cardio.isEmpty { out.append(("Cardio", cardio)) }
    let mobility = all.filter { $0.type == "mobility" }
    if !mobility.isEmpty { out.append(("Mobility", mobility)) }
    return out
  }()
}
