/// Current import/export envelope format version.
let importExportEnvelopeVersion = 1

/// Sections the exporter understands today. Order matches the Settings sidebar.
/// A section this app retired (Septena Life: Tasks, ADR 0007) is neither
/// exported nor imported here; the task app owns that data.
let exportableSectionKeys: [String] = [
  "tasks", "training", "nutrition", "habits", "chores",
  "supplements", "groceries", "gut", "intake",
].filter { !SectionManifest.isRetired($0) }
