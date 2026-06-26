import AppIntents
import Foundation

struct DashboardSectionEntity: AppEntity, Identifiable {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Section")
  static var defaultQuery = DashboardSectionEntityQuery()

  var id: String { itemID }
  var itemID: String
  var title: String
  var iconSymbol: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)")
  }
}

struct DashboardSectionEntityQuery: EntityQuery {
  func entities(for identifiers: [DashboardSectionEntity.ID]) async throws -> [DashboardSectionEntity] {
    let catalog = TileWidgetSnapshotStore.load()
    return identifiers.compactMap { id in
      catalog.sections.first { $0.itemID == id }.map {
        DashboardSectionEntity(itemID: $0.itemID, title: $0.title, iconSymbol: $0.iconSymbol)
      }
    }
  }

  func suggestedEntities() async throws -> [DashboardSectionEntity] {
    TileWidgetSnapshotStore.load().sections.map {
      DashboardSectionEntity(itemID: $0.itemID, title: $0.title, iconSymbol: $0.iconSymbol)
    }
  }

  func defaultResult() async -> DashboardSectionEntity? {
    (try? await suggestedEntities())?.first
  }
}

struct SectionTileConfigurationIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource = "Section Tile"
  static var description = IntentDescription("A dashboard tile for one section — 7-day histogram (small) or ~15-week heatmap (wide).")

  @Parameter(title: "Section")
  var section: DashboardSectionEntity?
}

extension SectionTileConfigurationIntent {
  static var sampleSection: DashboardSectionEntity {
    DashboardSectionEntity(itemID: HomepageDomain.habits.rawValue,
                           title: "Habits",
                           iconSymbol: "figure.mind.and.body")
  }
}
