import Foundation

/// Canonical join key for matching exercise labels across surfaces.
/// Lowercases and strips every non-alphanumeric character so that
/// "Chest-Press", "chest press", "Chest_Press" all collapse to
/// "chestpress". Use both sides of any name-keyed lookup (routine
/// slug vs. historical entry name) to survive separator drift that
/// accumulated across legacy data, RoutineSlugRepair stubs, and
/// the in-app catalog editor.
///
/// Lives in its own file rather than beside the PR calculator it grew up in:
/// it is pure string work with no SwiftData in sight, and the history importer
/// needs it from a test target that deliberately doesn't compile the model
/// layer.
func exerciseKey(_ name: String) -> String {
  name.lowercased().filter { $0.isLetter || $0.isNumber }
}
