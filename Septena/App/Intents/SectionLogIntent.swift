import AppIntents
import Foundation

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
// `AppShortcutsProvider.appShortcuts` context (and the OS metadata
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
  /// (idempotent; safe on a cold background launch), then REFUSES if the
  /// section is turned off.
  ///
  /// ENABLEMENT. App Shortcuts are extracted statically by the OS at
  /// install/update time, so the *set* of shortcuts can't be filtered by the
  /// runtime `SectionEntity.isEnabled` flag — the system wouldn't see the
  /// change. We honor enablement at run time instead, and we mirror MCP: a
  /// disabled section's tools simply aren't available. Rather than silently
  /// re-enabling on use, we throw `SectionDisabledError`, which Siri /
  /// Shortcuts surface as a spoken reason. The other surface that reflects
  /// this is the parameter picker — each `EntityQuery.suggestedEntities()`
  /// returns nothing for a disabled section. `.always` sections (tasks, goals)
  /// are locked on and always pass.
  @MainActor
  func requireSection() async throws {
    await SeptenaServices.shared.start()
    guard SeptenaServices.shared.isSectionEnabled(Self.sectionKey) else {
      throw SectionDisabledError(label: manifest.defaultLabel)
    }
  }
}

/// Thrown by `requireSection()` when an intent targets a section the user has
/// turned off. Conforms to `CustomLocalizedStringResourceConvertible` so Siri
/// and the Shortcuts app present the reason to the person instead of a generic
/// failure.
struct SectionDisabledError: Error, CustomLocalizedStringResourceConvertible {
  let label: String
  var localizedStringResource: LocalizedStringResource {
    "\(label) is turned off in Septena. Turn it on to use this action."
  }
}
