import AppIntents

// App Intents spine — every loggable section action becomes a Shortcut, a
// Siri phrase, and a Spotlight result through this one pattern.
//
// A `SectionLogIntent` is tied to its section by the manifest `key`. That
// single string is the join to everything section-shaped: it boots the
// shared stack, auto-enables the section, and (via `manifest`) hands the
// intent the section's catalog identity. Adding a section's intents means
// one new file that conforms to this — no central switch, the same shape as
// `SectionPlugin` / `SectionManifest`.
//
// The protocol is deliberately NOT @MainActor. An AppIntent's type must stay
// nonisolated so its `init()` is callable from the nonisolated
// `AppShortcutsProvider.appShortcuts` context (and from the OS's metadata
// extractor). Only the work that touches the SwiftData / CloudKit stack hops
// onto the main actor: each conformer's `perform()` and `prepareSection()`.

protocol SectionLogIntent: AppIntent {
  /// Matches `SectionManifest.key` (and `SectionEntity.id`). The one tie
  /// between an intent and its section.
  static var sectionKey: String { get }
}

extension SectionLogIntent {
  /// The catalog row this intent belongs to. Force-unwrap is safe: a
  /// `sectionKey` always names a real manifest entry (a compile-time
  /// constant matched to `SectionManifest.all`).
  var manifest: SectionManifest { SectionManifest.byKey[Self.sectionKey]! }

  /// Run before every mutation. Boots the CloudKit-backed stack
  /// (idempotent; safe on a cold background launch) and turns the section
  /// on if it was off.
  ///
  /// ENABLEMENT. App Shortcuts are extracted statically by the OS at
  /// install/update time, so the *set* of shortcuts can't be filtered by the
  /// runtime `SectionEntity.isEnabled` flag — the system wouldn't see the
  /// change. Enablement is honored here at run time instead: logging to a
  /// section is implicit consent to use it, and a disable never drops data,
  /// so we silently re-enable rather than refuse. The surfaces that DO
  /// reflect data live are the parameter pickers (`EntityQuery` reads the
  /// real catalog) and, later, Spotlight entity indexing.
  @MainActor
  func prepareSection() async {
    await SeptenaServices.shared.start()
    SeptenaServices.shared.ensureSectionEnabled(Self.sectionKey)
  }
}

/// The app's single, global App Shortcuts surface. The OS reads this list
/// statically, so it's a literal listing of each section's shortcuts — one
/// `AppShortcut` per line, NOT a `SectionRegistry` loop (the build-time
/// phrase extractor can't see a runtime loop). This is the one hand-
/// maintained spot: adding a section means adding its line(s) here. Apple
/// surfaces ~10 for zero-config Siri, so keep the highest-value voice
/// actions near the top; the rest still appear as actions in Shortcuts.app.
struct SeptenaShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    [
      TaskShortcuts.addTask,
      SupplementShortcuts.markTaken,
      SupplementShortcuts.addNew,
    ]
  }
}
