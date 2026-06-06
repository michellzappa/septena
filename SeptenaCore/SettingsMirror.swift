import Foundation
import SwiftData

@MainActor
enum SettingsMirror {
  private static let encoder = JSONEncoder()
  private static let decoder = JSONDecoder()

  // `nonisolated`: a pure context read, so `DashboardReader` can pull
  // settings on its background context off-main. Uses a local decoder
  // rather than the enum's `@MainActor` shared one (the write methods here
  // genuinely need main — they push through CKEngine — so the enum stays
  // `@MainActor` and only this read opts out).
  nonisolated static func loadSettings(context: ModelContext) -> AppSettings? {
    let singletonID = SettingsCloudKitSchema.singletonID
    let descriptor = FetchDescriptor<SettingsEntity>(
      predicate: #Predicate { $0.id == singletonID }
    )
    guard let entity = try? context.fetch(descriptor).first else { return nil }
    return try? JSONDecoder().decode(AppSettings.self, from: entity.payloadData)
  }

  static func loadSections(context: ModelContext) -> [SectionConfig] {
    let descriptor = FetchDescriptor<SectionEntity>()
    let rows = (try? context.fetch(descriptor)) ?? []
    let settings = loadSettings(context: context)
    let order = settings?.sectionOrder ?? []
    let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })

    // Drop SectionEntity rows whose key isn't in the current manifest.
    // These are orphans from prior schemas (e.g. "brief", "next") that
    // CloudKit still has lying around — the manifest is the source of
    // truth for which sections the app surfaces today.
    let knownKeys = Set(SectionManifest.byKey.keys)

    return rows
      .filter { knownKeys.contains($0.id) }
      .sorted { lhs, rhs in
        let lhsRank = rank[lhs.id]
        let rhsRank = rank[rhs.id]
        switch (lhsRank, rhsRank) {
        case let (l?, r?):
          return l < r
        case (.some, .none):
          return true
        case (.none, .some):
          return false
        case (.none, .none):
          return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
      }
      .map(SectionConfig.init)
  }

  /// Insert a SectionEntity for a manifest key if it isn't already in
  /// the local store. Used at startup to backfill sections that were
  /// added to `SectionManifest` after the user's CloudKit `SectionEntity`
  /// set was last synced — without this, a newly-shipped section would
  /// stay invisible on the dashboard until manual install UX exists.
  ///
  /// `title` / `color` / `isEnabled` are pulled from the manifest's
  /// defaults so the row matches the catalog. `hasOnboarded` mirrors
  /// `isEnabled` at seed time: a section seeded enabled is already
  /// "set up" (no onboarding to run); a section seeded disabled awaits
  /// first-enable, at which point the toggle flow asks the plugin
  /// whether onboarding is required.
  @discardableResult
  static func seedManifestSectionIfMissing(_ key: String,
                                           context: ModelContext) -> Bool {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    if (try? context.fetch(descriptor).first) != nil { return false }
    guard let manifest = SectionManifest.byKey[key] else { return false }
    let seedEnabled = manifest.defaultEnabled
    let entity = SectionEntity(id: manifest.key,
                               title: manifest.defaultLabel,
                               color: "",
                               isEnabled: seedEnabled,
                               hasOnboarded: seedEnabled)
    context.insert(entity)
    do { try context.save() } catch {
      SeptenaLog.error("SettingsMirror.seedManifestSection", error)
      return false
    }
    return true
  }

  /// One-shot migration for users who upgrade from a build that pre-dates
  /// the `hasOnboarded` field. Sections that are *currently enabled* on
  /// this device are flipped to `hasOnboarded = true` — they've clearly
  /// been in use, so no onboarding sheet should fire on their next
  /// toggle. Disabled rows are left alone: either they were never
  /// onboarded (fresh seed) or the user explicitly disabled them
  /// after onboarding (in which case the bit's value already encodes
  /// the right thing). Idempotent; must run BEFORE seeding so newly
  /// seeded rows aren't accidentally swept into the migration.
  static func backfillHasOnboardedForLegacySections(context: ModelContext) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.hasOnboarded == false && $0.isEnabled == true }
    )
    guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
    for row in rows {
      row.hasOnboarded = true
    }
    do {
      try context.save()
    } catch {
      SeptenaLog.error("SettingsMirror.backfillHasOnboarded", error)
    }
  }

  /// Toggle `hasOnboarded` on a single section. Pushes through CKEngine.
  static func setSectionHasOnboarded(_ key: String,
                                     hasOnboarded: Bool,
                                     context: ModelContext,
                                     engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    guard let entity = try? context.fetch(descriptor).first else { return }
    guard entity.hasOnboarded != hasOnboarded else { return }
    entity.hasOnboarded = hasOnboarded
    entity.updatedAt = .now
    do {
      try context.save()
      engine?.noteSectionChange(id: key)
    } catch {
      SeptenaLog.error("SettingsMirror.setSectionHasOnboarded", error)
    }
  }

  /// Enable (or disable) a section by key, seeding the row from the
  /// manifest if it doesn't exist yet. Enabling also flips `hasOnboarded`
  /// so an intent-driven enable never tries to present a first-enable sheet
  /// with no UI on screen. Upsert-only — never deletes (same guarantee as
  /// `replaceSections`). Pushes through CKEngine. No-op when already in the
  /// target state.
  static func setSectionEnabled(_ key: String,
                                _ enabled: Bool,
                                context: ModelContext,
                                engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    let entity: SectionEntity
    if let existing = try? context.fetch(descriptor).first {
      entity = existing
    } else {
      guard let manifest = SectionManifest.byKey[key] else { return }
      entity = SectionEntity(id: manifest.key,
                             title: manifest.defaultLabel,
                             color: "")
      context.insert(entity)
    }
    // Enabling implies onboarded (suppresses the first-enable sheet a
    // headless intent can't present); disabling leaves the bit untouched.
    let needsWrite = entity.isEnabled != enabled || (enabled && !entity.hasOnboarded)
    guard needsWrite else { return }
    entity.isEnabled = enabled
    if enabled { entity.hasOnboarded = true }
    entity.updatedAt = .now
    do {
      try context.save()
      engine?.noteSectionChange(id: key)
      NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
    } catch {
      SeptenaLog.error("SettingsMirror.setSectionEnabled", error)
    }
  }

  static func upsert(settings: AppSettings,
                     context: ModelContext,
                     engine: CKEngine? = nil) {
    guard let data = try? encoder.encode(settings) else { return }
    let singletonID = SettingsCloudKitSchema.singletonID
    let descriptor = FetchDescriptor<SettingsEntity>(
      predicate: #Predicate { $0.id == singletonID }
    )
    let entity = (try? context.fetch(descriptor).first)
      ?? SettingsEntity(payloadData: data)
    let changed = entity.payloadData != data
    entity.payloadData = data
    entity.updatedAt = .now
    if entity.modelContext == nil { context.insert(entity) }
    do {
      try context.save()
      if changed { engine?.noteSettingsChange() }
    } catch {
      SeptenaLog.error("SettingsMirror.upsert settings", error)
    }
  }

  /// Upsert-only. Section rows are never deleted by this code path —
  /// disabling a section toggles `isEnabled` instead so all
  /// customizations (title, color) and the row itself survive. This is
  /// the absolute guarantee that no UX action can drop a SectionEntity.
  static func replaceSections(_ sections: [SectionConfig],
                              context: ModelContext,
                              engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>()
    let existing = (try? context.fetch(descriptor)) ?? []
    let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    var changedIDs: [String] = []

    for section in sections {
      if let entity = existingByID[section.key] {
        let changed = entity.title != section.label
          || entity.color != section.color
          || entity.isEnabled != section.isEnabled
          || entity.showInToday != section.showInToday
          || entity.hasOnboarded != section.hasOnboarded
        entity.title = section.label
        entity.color = section.color
        entity.isEnabled = section.isEnabled
        entity.showInToday = section.showInToday
        entity.hasOnboarded = section.hasOnboarded
        entity.updatedAt = .now
        if changed { changedIDs.append(section.key) }
      } else {
        let entity = SectionEntity(id: section.key,
                                   title: section.label,
                                   color: section.color,
                                   isEnabled: section.isEnabled,
                                   showInToday: section.showInToday,
                                   hasOnboarded: section.hasOnboarded)
        context.insert(entity)
        changedIDs.append(section.key)
      }
    }

    do {
      try context.save()
      for id in changedIDs { engine?.noteSectionChange(id: id) }
    } catch {
      SeptenaLog.error("SettingsMirror.replace sections", error)
    }
  }

  /// Toggle `isEnabled` on a single section. Pushes the change through
  /// CKEngine so other devices receive it. Never deletes the row.
  static func setSectionEnabled(_ key: String,
                                enabled: Bool,
                                context: ModelContext,
                                engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    guard let entity = try? context.fetch(descriptor).first else { return }
    guard entity.isEnabled != enabled else { return }
    entity.isEnabled = enabled
    entity.updatedAt = .now
    do {
      try context.save()
      engine?.noteSectionChange(id: key)
    } catch {
      SeptenaLog.error("SettingsMirror.setSectionEnabled", error)
    }
  }

  /// Toggle `showInToday` on a single section. Same shape as
  /// `setSectionEnabled`: persists, syncs, never deletes.
  static func setSectionShowInToday(_ key: String,
                                    showInToday: Bool,
                                    context: ModelContext,
                                    engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    guard let entity = try? context.fetch(descriptor).first else { return }
    guard entity.showInToday != showInToday else { return }
    entity.showInToday = showInToday
    entity.updatedAt = .now
    do {
      try context.save()
      engine?.noteSectionChange(id: key)
    } catch {
      SeptenaLog.error("SettingsMirror.setSectionShowInToday", error)
    }
  }
}
