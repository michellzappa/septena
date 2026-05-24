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

  static func replaceSections(_ sections: [SectionConfig],
                              context: ModelContext,
                              engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>()
    let existing = (try? context.fetch(descriptor)) ?? []
    let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    let incomingIDs = Set(sections.map(\.key))
    var changedIDs: [String] = []

    for section in sections {
      if let entity = existingByID[section.key] {
        let changed = entity.title != section.label || entity.color != section.color
        entity.title = section.label
        entity.color = section.color
        entity.updatedAt = .now
        if changed { changedIDs.append(section.key) }
      } else {
        let entity = SectionEntity(id: section.key, title: section.label, color: section.color)
        context.insert(entity)
        changedIDs.append(section.key)
      }
    }

    let deletedIDs = existing
      .filter { !incomingIDs.contains($0.id) }
      .map(\.id)
    for entity in existing where !incomingIDs.contains(entity.id) {
      context.delete(entity)
    }

    do {
      try context.save()
      for id in changedIDs { engine?.noteSectionChange(id: id) }
      for id in deletedIDs { engine?.noteSectionDeletion(id: id) }
    } catch {
      SeptenaLog.error("SettingsMirror.replace sections", error)
    }
  }
}
