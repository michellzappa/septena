import Foundation

// Curated catalog of common exercises with muscle-group assignments.
// Consumers:
//   1. ExerciseLibrarySheet — opt-in picker.
//   2. CanonicalExerciseName — resolves logged names against ids + aliases.
//      Aliases let users with personal naming conventions ("incline-db-press",
//      "bb-row") still resolve without us renaming their entries.
//
// Slugs are the canonical join key. Keep ids stable; aliases are
// additive — adding a new alias only widens what name resolution catches.

struct LibraryExercise: Hashable, Identifiable, Sendable {
  let id: String                  // canonical slug
  let name: String
  let type: String                // strength | cardio | mobility | core
  let primaryMuscle: Muscle?
  let secondaryMuscles: [Muscle]
  let aliases: [String]           // alternative slugs the user may have

  init(_ id: String, _ name: String, _ type: String,
       _ primary: Muscle?, _ secondaries: [Muscle] = [],
       aliases: [String] = []) {
    self.id = id
    self.name = name
    self.type = type
    self.primaryMuscle = primary
    self.secondaryMuscles = secondaries
    self.aliases = aliases
  }
}

enum DefaultExerciseLibrary {
  static let all: [LibraryExercise] = [
    // ── Chest ───────────────────────────────────────────────────────
    .init("bench-press", "Bench Press", "strength", .chest, [.triceps, .frontDelts],
          aliases: ["barbell-bench-press", "bb-bench-press", "flat-bench-press", "bench"]),
    .init("incline-bench-press", "Incline Bench Press", "strength", .chest, [.frontDelts, .triceps],
          aliases: ["incline-press", "incline-barbell-press", "incline-bb-press"]),
    .init("decline-bench-press", "Decline Bench Press", "strength", .chest, [.triceps],
          aliases: ["decline-press"]),
    .init("dumbbell-press", "Dumbbell Bench Press", "strength", .chest, [.triceps, .frontDelts],
          aliases: ["db-press", "db-bench-press", "dumbbell-chest-press", "flat-db-press"]),
    .init("incline-dumbbell-press", "Incline Dumbbell Press", "strength", .chest, [.frontDelts, .triceps],
          aliases: ["incline-db-press"]),
    .init("push-up", "Push-Up", "strength", .chest, [.triceps, .frontDelts, .abs],
          aliases: ["pushup", "push-ups", "pushups"]),
    .init("chest-fly", "Chest Fly", "strength", .chest, [.frontDelts],
          aliases: ["dumbbell-fly", "db-fly", "pec-fly", "pec-deck", "machine-fly"]),
    .init("cable-crossover", "Cable Crossover", "strength", .chest, [.frontDelts],
          aliases: ["cable-fly", "cable-chest-fly"]),
    .init("dip", "Dip", "strength", .chest, [.triceps, .frontDelts],
          aliases: ["dips", "chest-dip", "parallel-bar-dip"]),
    .init("machine-chest-press", "Machine Chest Press", "strength", .chest, [.triceps, .frontDelts],
          aliases: ["chest-press", "chest-press-machine", "seated-chest-press"]),

    // ── Back (lats / upper back) ────────────────────────────────────
    .init("pull-up", "Pull-Up", "strength", .lats, [.biceps, .upperBack],
          aliases: ["pullup", "pull-ups", "pullups", "wide-grip-pull-up"]),
    .init("chin-up", "Chin-Up", "strength", .lats, [.biceps],
          aliases: ["chinup", "chin-ups"]),
    .init("lat-pulldown", "Lat Pulldown", "strength", .lats, [.biceps],
          aliases: ["pulldown", "lat-pull-down", "wide-grip-pulldown", "neutral-grip-pulldown"]),
    .init("barbell-row", "Barbell Row", "strength", .upperBack, [.lats, .biceps],
          aliases: ["bb-row", "bent-over-row", "bent-over-barbell-row", "pendlay-row"]),
    .init("dumbbell-row", "Dumbbell Row", "strength", .upperBack, [.lats, .biceps],
          aliases: ["db-row", "one-arm-row", "single-arm-row", "single-arm-db-row"]),
    .init("cable-row", "Cable Row", "strength", .upperBack, [.lats, .biceps],
          aliases: ["seated-cable-row", "seated-row"]),
    .init("t-bar-row", "T-Bar Row", "strength", .upperBack, [.lats, .biceps],
          aliases: ["tbar-row", "t-bar"]),
    .init("face-pull", "Face Pull", "strength", .rearDelts, [.upperBack],
          aliases: ["face-pulls", "rear-delt-cable", "cable-face-pull"]),
    .init("meadows-row", "Meadows Row", "strength", .upperBack, [.lats, .biceps],
          aliases: ["meadows"]),
    .init("shrug", "Shrug", "strength", .upperBack, [],
          aliases: ["shrugs", "barbell-shrug", "dumbbell-shrug", "db-shrug", "trap-shrug"]),
    .init("inverted-row", "Inverted Row", "strength", .upperBack, [.lats, .biceps],
          aliases: ["bodyweight-row", "australian-pull-up"]),
    .init("straight-arm-pulldown", "Straight-Arm Pulldown", "strength", .lats, [],
          aliases: ["straight-arm-cable", "lat-cable"]),

    // ── Shoulders (front / side / rear delts) ──────────────────────
    .init("overhead-press", "Overhead Press", "strength", .frontDelts, [.sideDelts, .triceps],
          aliases: ["ohp", "barbell-ohp", "standing-press", "military-press", "bb-press", "shoulder-press"]),
    .init("dumbbell-shoulder-press", "Dumbbell Shoulder Press", "strength", .frontDelts, [.sideDelts, .triceps],
          aliases: ["db-shoulder-press", "seated-dumbbell-press", "db-ohp"]),
    .init("arnold-press", "Arnold Press", "strength", .frontDelts, [.sideDelts, .triceps],
          aliases: ["arnold"]),
    .init("lateral-raise", "Lateral Raise", "strength", .sideDelts, [],
          aliases: ["side-raise", "db-lateral-raise", "cable-lateral-raise", "side-lateral"]),
    .init("front-raise", "Front Raise", "strength", .frontDelts, [],
          aliases: ["db-front-raise", "plate-front-raise"]),
    .init("rear-delt-fly", "Rear Delt Fly", "strength", .rearDelts, [.upperBack],
          aliases: ["reverse-fly", "rear-fly", "bent-over-fly", "rear-delt-raise", "rear-delt"]),
    .init("upright-row", "Upright Row", "strength", .sideDelts, [.upperBack],
          aliases: ["upright-rows"]),
    .init("machine-shoulder-press", "Machine Shoulder Press", "strength", .frontDelts, [.sideDelts, .triceps],
          aliases: ["smith-shoulder-press"]),

    // ── Biceps ─────────────────────────────────────────────────────
    .init("barbell-curl", "Barbell Curl", "strength", .biceps, [.forearms],
          aliases: ["bb-curl", "ez-bar-curl", "ez-curl", "straight-bar-curl"]),
    .init("dumbbell-curl", "Dumbbell Curl", "strength", .biceps, [.forearms],
          aliases: ["db-curl", "alternating-db-curl", "alternating-dumbbell-curl"]),
    .init("hammer-curl", "Hammer Curl", "strength", .biceps, [.forearms],
          aliases: ["hammer-curls", "db-hammer-curl"]),
    .init("preacher-curl", "Preacher Curl", "strength", .biceps, [],
          aliases: ["scott-curl", "preacher-bench-curl"]),
    .init("concentration-curl", "Concentration Curl", "strength", .biceps, [],
          aliases: ["seated-concentration-curl"]),
    .init("cable-curl", "Cable Curl", "strength", .biceps, [],
          aliases: ["rope-curl", "cable-bicep-curl"]),
    .init("spider-curl", "Spider Curl", "strength", .biceps, [],
          aliases: []),
    .init("wrist-curl", "Wrist Curl", "strength", .forearms, [],
          aliases: ["forearm-curl", "reverse-wrist-curl", "reverse-curl"]),

    // ── Triceps ────────────────────────────────────────────────────
    .init("tricep-extension", "Tricep Extension", "strength", .triceps, [],
          aliases: ["overhead-tricep-extension", "overhead-extension", "db-tricep-extension"]),
    .init("skullcrusher", "Skullcrusher", "strength", .triceps, [],
          aliases: ["lying-tricep-extension", "skull-crusher", "ez-skullcrusher"]),
    .init("tricep-pushdown", "Tricep Pushdown", "strength", .triceps, [],
          aliases: ["cable-pushdown", "rope-pushdown", "pushdown", "tricep-pressdown"]),
    .init("close-grip-bench-press", "Close-Grip Bench Press", "strength", .triceps, [.chest],
          aliases: ["cgbp", "close-grip-bench"]),
    .init("tricep-kickback", "Tricep Kickback", "strength", .triceps, [],
          aliases: ["kickback", "db-kickback"]),
    .init("tricep-dip", "Tricep Dip", "strength", .triceps, [.chest, .frontDelts],
          aliases: ["bench-dip", "parallel-dip"]),

    // ── Quads ──────────────────────────────────────────────────────
    .init("barbell-squat", "Barbell Squat", "strength", .quads, [.glutes, .hamstrings, .lowerBack],
          aliases: ["back-squat", "squat", "high-bar-squat", "low-bar-squat", "bb-squat"]),
    .init("front-squat", "Front Squat", "strength", .quads, [.glutes, .abs],
          aliases: ["bb-front-squat"]),
    .init("goblet-squat", "Goblet Squat", "strength", .quads, [.glutes, .abs],
          aliases: ["kb-goblet-squat", "db-goblet-squat"]),
    .init("leg-press", "Leg Press", "strength", .quads, [.glutes, .hamstrings],
          aliases: ["machine-leg-press", "45-degree-leg-press"]),
    .init("lunge", "Lunge", "strength", .quads, [.glutes, .hamstrings],
          aliases: ["lunges", "walking-lunge", "reverse-lunge", "forward-lunge", "db-lunge", "bb-lunge"]),
    .init("bulgarian-split-squat", "Bulgarian Split Squat", "strength", .quads, [.glutes],
          aliases: ["bss", "rear-foot-elevated-split-squat", "rfess", "split-squat"]),
    .init("step-up", "Step-Up", "strength", .quads, [.glutes],
          aliases: ["step-ups", "db-step-up", "box-step-up"]),
    .init("leg-extension", "Leg Extension", "strength", .quads, [],
          aliases: ["machine-leg-extension"]),
    .init("hack-squat", "Hack Squat", "strength", .quads, [.glutes],
          aliases: ["machine-hack-squat"]),
    .init("pistol-squat", "Pistol Squat", "strength", .quads, [.glutes],
          aliases: ["single-leg-squat"]),

    // ── Hamstrings ─────────────────────────────────────────────────
    .init("deadlift", "Deadlift", "strength", .hamstrings, [.glutes, .lowerBack, .upperBack],
          aliases: ["dl", "conventional-deadlift", "bb-deadlift", "barbell-deadlift"]),
    .init("romanian-deadlift", "Romanian Deadlift", "strength", .hamstrings, [.glutes, .lowerBack],
          aliases: ["rdl", "db-rdl", "dumbbell-rdl", "stiff-leg-deadlift"]),
    .init("leg-curl", "Leg Curl", "strength", .hamstrings, [],
          aliases: ["lying-leg-curl", "seated-leg-curl", "machine-leg-curl", "hamstring-curl"]),
    .init("good-morning", "Good Morning", "strength", .hamstrings, [.glutes, .lowerBack],
          aliases: ["bb-good-morning"]),
    .init("nordic-curl", "Nordic Curl", "strength", .hamstrings, [],
          aliases: ["nordic-hamstring-curl"]),
    .init("hex-bar-deadlift", "Hex Bar Deadlift", "strength", .hamstrings, [.glutes, .quads, .lowerBack],
          aliases: ["trap-bar-deadlift", "trap-bar-dl", "hex-bar-dl"]),

    // ── Glutes ─────────────────────────────────────────────────────
    .init("hip-thrust", "Hip Thrust", "strength", .glutes, [.hamstrings],
          aliases: ["barbell-hip-thrust", "bb-hip-thrust", "hip-thrusts"]),
    .init("glute-bridge", "Glute Bridge", "strength", .glutes, [.hamstrings],
          aliases: ["bridge", "glute-bridges", "bb-glute-bridge"]),
    .init("sumo-deadlift", "Sumo Deadlift", "strength", .glutes, [.hamstrings, .lowerBack, .adductors],
          aliases: ["sumo-dl"]),
    .init("cable-kickback", "Cable Kickback", "strength", .glutes, [],
          aliases: ["glute-kickback", "kickback"]),
    .init("hip-abduction", "Hip Abduction", "strength", .glutes, [],
          aliases: ["machine-hip-abduction", "abductor-machine", "abduction"]),
    .init("hip-adduction", "Hip Adduction", "strength", .adductors, [],
          aliases: ["machine-hip-adduction", "adductor-machine", "adduction", "inner-thigh"]),

    // ── Calves ─────────────────────────────────────────────────────
    .init("standing-calf-raise", "Standing Calf Raise", "strength", .calves, [],
          aliases: ["calf-raise", "calf-raises", "bb-calf-raise"]),
    .init("seated-calf-raise", "Seated Calf Raise", "strength", .calves, [],
          aliases: []),
    .init("donkey-calf-raise", "Donkey Calf Raise", "strength", .calves, [],
          aliases: []),

    // ── Core (abs / lower back) ────────────────────────────────────
    .init("plank", "Plank", "core", .abs, [],
          aliases: ["forearm-plank", "high-plank", "front-plank"]),
    .init("side-plank", "Side Plank", "core", .abs, [],
          aliases: ["lateral-plank"]),
    .init("hanging-leg-raise", "Hanging Leg Raise", "core", .abs, [],
          aliases: ["leg-raise", "hanging-knee-raise"]),
    .init("crunch", "Crunch", "core", .abs, [],
          aliases: ["crunches", "ab-crunch"]),
    .init("sit-up", "Sit-Up", "core", .abs, [],
          aliases: ["situp", "sit-ups", "situps"]),
    .init("russian-twist", "Russian Twist", "core", .abs, [],
          aliases: ["russian-twists", "weighted-twist"]),
    .init("dead-bug", "Dead Bug", "core", .abs, [],
          aliases: ["deadbug"]),
    .init("hollow-hold", "Hollow Hold", "core", .abs, [],
          aliases: ["hollow-body-hold"]),
    .init("ab-wheel", "Ab Wheel Rollout", "core", .abs, [],
          aliases: ["ab-rollout", "wheel-rollout"]),
    .init("cable-crunch", "Cable Crunch", "core", .abs, [],
          aliases: ["kneeling-cable-crunch"]),
    .init("pallof-press", "Pallof Press", "core", .abs, [],
          aliases: ["pallof", "anti-rotation-press"]),
    .init("mountain-climber", "Mountain Climber", "core", .abs, [],
          aliases: ["mountain-climbers"]),
    .init("back-extension", "Back Extension", "core", .lowerBack, [.glutes],
          aliases: ["hyperextension", "hyper-extension", "superman", "roman-chair"]),

    // ── Cardio ─────────────────────────────────────────────────────
    .init("running", "Running", "cardio", nil, [],
          aliases: ["run", "jog", "jogging", "treadmill", "treadmill-run", "outdoor-run"]),
    .init("cycling", "Cycling", "cardio", nil, [],
          aliases: ["bike", "biking", "stationary-bike", "indoor-cycling", "spinning", "spin"]),
    .init("rowing", "Rowing", "cardio", nil, [],
          aliases: ["row-erg", "erg", "rower"]),
    .init("elliptical", "Elliptical", "cardio", nil, [],
          aliases: ["cross-trainer"]),
    .init("stair-climber", "Stair Climber", "cardio", nil, [],
          aliases: ["stairmaster", "stairs"]),
    .init("swimming", "Swimming", "cardio", nil, [],
          aliases: ["swim", "lap-swim"]),
    .init("walking", "Walking", "cardio", nil, [],
          aliases: ["walk", "hike", "hiking"]),
    .init("jumping-rope", "Jumping Rope", "cardio", nil, [],
          aliases: ["jump-rope", "skipping"]),
    .init("kettlebell-swing", "Kettlebell Swing", "cardio", .glutes, [.hamstrings, .lowerBack],
          aliases: ["kb-swing", "swing", "kettlebell-swings"]),
    .init("burpee", "Burpee", "cardio", nil, [],
          aliases: ["burpees"]),
    .init("zone-2", "Zone 2", "cardio", nil, [],
          aliases: ["z2", "zone-2-cardio", "z2-cardio"]),
    .init("hiit", "HIIT", "cardio", nil, [],
          aliases: ["high-intensity-interval-training", "high-intensity-intervals"]),
    .init("interval-training", "Interval Training", "cardio", nil, [],
          aliases: ["intervals", "interval-workout"]),
    .init("sprint-intervals", "Sprint Intervals", "cardio", nil, [],
          aliases: ["sprints", "running-intervals"]),
    .init("boxing", "Boxing", "cardio", nil, [],
          aliases: ["boxercise", "boxing-workout"]),
    .init("kickboxing", "Kickboxing", "cardio", nil, [],
          aliases: ["kick-boxing", "muay-thai"]),
    .init("dance-cardio", "Dance Cardio", "cardio", nil, [],
          aliases: ["dance", "dance-workout"]),
    .init("aerobics", "Aerobics", "cardio", nil, [],
          aliases: ["aerobic-class", "step-aerobics"]),
    .init("cross-country-skiing", "Cross-Country Skiing", "cardio", nil, [],
          aliases: ["cross-country-ski", "nordic-skiing"]),
    .init("ice-skating", "Ice Skating", "cardio", nil, [],
          aliases: ["ice-skate"]),
    .init("roller-skating", "Roller Skating", "cardio", nil, [],
          aliases: ["rollerblading", "inline-skating", "inline-skate"]),
    .init("assault-bike", "Assault Bike", "cardio", nil, [],
          aliases: ["air-bike", "fan-bike"]),
    .init("battle-ropes", "Battle Ropes", "cardio", nil, [],
          aliases: ["battle-rope", "rope-slam"]),
    .init("sled-push", "Sled Push", "cardio", nil, [],
          aliases: ["prowler-push", "sled-drag"]),
    .init("tennis", "Tennis", "cardio", nil, [],
          aliases: ["tennis-match"]),
    .init("basketball", "Basketball", "cardio", nil, [],
          aliases: ["basketball-game"]),
    .init("soccer", "Soccer", "cardio", nil, [],
          aliases: ["football", "soccer-match"]),

    // ── Mobility ───────────────────────────────────────────────────
    .init("foam-rolling", "Foam Rolling", "mobility", nil, [],
          aliases: ["foam-roll", "smr", "self-myofascial-release"]),
    .init("hip-mobility", "Hip Mobility Flow", "mobility", nil, [],
          aliases: ["hip-flow", "hip-opener"]),
    .init("shoulder-mobility", "Shoulder Mobility", "mobility", nil, [],
          aliases: ["shoulder-flow", "shoulder-opener"]),
    .init("ankle-mobility", "Ankle Mobility", "mobility", nil, [],
          aliases: []),
    .init("stretching", "Stretching", "mobility", nil, [],
          aliases: ["stretch", "static-stretch", "dynamic-stretch"]),
    .init("yoga", "Yoga", "mobility", nil, [],
          aliases: ["yoga-flow", "vinyasa"]),
  ]

  static let bySlug: [String: LibraryExercise] = {
    Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
  }()

  // Reverse-lookup table: any alias → its canonical entry. Aliases never
  // collide with primary ids because ids are also added below — that way
  // a single dictionary call covers both lookup paths.
  static let byAnySlug: [String: LibraryExercise] = {
    var dict: [String: LibraryExercise] = [:]
    for entry in all {
      dict[entry.id] = entry
      for alias in entry.aliases {
        // First writer wins on collision — keep canonical id over alias
        // if both happen to be present (shouldn't, but defensive).
        if dict[alias] == nil { dict[alias] = entry }
      }
    }
    return dict
  }()

  // Resolution table keyed by `exerciseKey` (lowercase, alphanumerics
  // only) over id + name + every alias. Unlike `byAnySlug`, which keys on
  // the literal alias string, this survives casing/separator drift —
  // "Rear-Delt", "rear delt" and "rear-delt" all collapse to one hit.
  // Used by CanonicalExerciseName to map stored labels → canonical names.
  static let byKey: [String: LibraryExercise] = {
    var dict: [String: LibraryExercise] = [:]
    for entry in all {
      for raw in [entry.id, entry.name] + entry.aliases {
        let key = exerciseKey(raw)
        // First writer wins: id and name are visited before aliases, so a
        // canonical slug/name always beats an alias on collision.
        if !key.isEmpty, dict[key] == nil { dict[key] = entry }
      }
    }
    return dict
  }()

  // Stable display order for the picker UI: strength grouped by muscle
  // (Muscle.allCases order), then core, cardio, mobility.
  static let grouped: [(title: String, items: [LibraryExercise])] = {
    var out: [(String, [LibraryExercise])] = []
    for muscle in Muscle.allCases {
      let items = all.filter { $0.type == "strength" && $0.primaryMuscle == muscle }
      if !items.isEmpty { out.append((muscle.label, items)) }
    }
    let coreItems = all.filter { $0.type == "core" }
    if !coreItems.isEmpty { out.append(("Core", coreItems)) }
    let cardio = all.filter { $0.type == "cardio" }
    if !cardio.isEmpty { out.append(("Cardio", cardio)) }
    let mobility = all.filter { $0.type == "mobility" }
    if !mobility.isEmpty { out.append(("Mobility", mobility)) }
    return out
  }()
}
