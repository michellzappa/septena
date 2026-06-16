import Foundation

/// The natural weight increment for a piece of equipment, expressed *per unit
/// system* rather than as a converted number — because 2.5 kg (≈5.5 lb) is not
/// what anyone dials on a US barbell, and 5 lb (≈2.27 kg) is not a metric plate.
/// Each cadence pairs a kg step with a lb step, both "round" in their own world.
///
/// Drives the in-session weight stepper so the +/- buttons match the equipment.
/// A pure display/input convenience — the increment never affects stored data
/// (you can always type an exact weight), so it's inferred from the exercise
/// name with no schema field. A stored per-exercise override can be layered on
/// later without touching this type (`resolve` would just check it first).
enum WeightCadence: String, CaseIterable {
  case barbell    // 2.5 kg · 5 lb   — the safe default for most lifts
  case dumbbell   // 2 kg   · 5 lb
  case machine    // 5 kg   · 10 lb  — selectorized stacks
  case micro      // 1 kg   · 2.5 lb — microplates / fractional

  /// The step size, in the user's unit, for this cadence.
  func step(_ unit: WeightUnit) -> Double {
    switch (self, unit) {
    case (.barbell, .kg):  return 2.5
    case (.barbell, .lb):  return 5
    case (.dumbbell, .kg): return 2
    case (.dumbbell, .lb): return 5
    case (.machine, .kg):  return 5
    case (.machine, .lb):  return 10
    case (.micro, .kg):    return 1
    case (.micro, .lb):    return 2.5
    }
  }

  /// Infer the cadence from an exercise's display name. Conservative: only the
  /// clear equipment tells (dumbbell / machine / cable / smith and the common
  /// machine movements) move off the `.barbell` default. Misses just fall back
  /// to barbell's gentle 2.5 / 5 — a mild annoyance, never wrong data.
  static func resolve(forExercise name: String) -> WeightCadence {
    let n = " \(name.lowercased()) "
    if n.contains("dumbbell") || n.contains("dumbell") || n.contains(" db ") {
      return .dumbbell
    }
    let machineTells = ["machine", "cable", "smith", "pulldown", "lat pull",
                        "leg press", "leg extension", "leg curl", "pec deck",
                        "seated row", "chest press machine"]
    if machineTells.contains(where: n.contains) { return .machine }
    return .barbell
  }
}
