import Foundation
import SwiftData

@MainActor
enum SettingsMirror {
  private static let encoder = JSONEncoder()
  private static let decoder = JSONDecoder()

  static func loadSettings(context: ModelContext) -> AppSettings? {
    let singletonID = SettingsCloudKitSchema.singletonID
    let descriptor = FetchDescriptor<SettingsEntity>(
      predicate: #Predicate { $0.id == singletonID }
    )
    guard let entity = try? context.fetch(descriptor).first else { return nil }
    return try? decoder.decode(AppSettings.self, from: entity.payloadData)
  }

  static func loadSections(context: ModelContext) -> [SectionConfig] {
    let descriptor = FetchDescriptor<SectionEntity>()
    let rows = (try? context.fetch(descriptor)) ?? []
    let settings = loadSettings(context: context)
    let order = settings?.sectionOrder ?? []
    let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })

    return rows
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
  /// defaults so the row matches the catalog. The CK engine isn't
  /// notified — once install UX lands and the section is properly
  /// owned by the user, the normal save path will push it.
  @discardableResult
  static func seedManifestSectionIfMissing(_ key: String,
                                           context: ModelContext) -> Bool {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    if (try? context.fetch(descriptor).first) != nil { return false }
    guard let manifest = SectionManifest.byKey[key] else { return false }
    // Empty color string = "no user preference"; SectionTheme falls back
    // to its built-in palette. Same shape SettingsMirror.replaceSections
    // uses when the server returns no color override.
    let entity = SectionEntity(id: manifest.key,
                               title: manifest.defaultLabel,
                               color: "",
                               isEnabled: manifest.defaultEnabled)
    context.insert(entity)
    do { try context.save() } catch {
      SeptenaLog.error("SettingsMirror.seedManifestSection", error)
      return false
    }
    return true
  }

  /// Backfill every section in `SectionManifest.all` that doesn't yet
  /// have a local `SectionEntity` row. Idempotent — existing rows are
  /// left alone so user customizations (color, isEnabled) survive.
  static func seedAllManifestSectionsIfMissing(context: ModelContext) {
    for manifest in SectionManifest.all {
      _ = seedManifestSectionIfMissing(manifest.key, context: context)
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
