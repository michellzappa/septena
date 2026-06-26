import Testing
import Foundation

@Suite struct ThingsImportTests {

  @Test func thingsDateDecoder() {
    // 2021-03-28 from things.py docs
    let date = ThingsDateDecoder.decodeThingsDate(132_464_128)
    #expect(date != nil)
    #expect(ThingsDateDecoder.formatISODate(date) == "2021-03-28")
    #expect(ThingsDateDecoder.decodeUnixTimestamp(1_642_581_216) != nil)
  }

  @Test func parserReadsAreasProjectsTasks() throws {
    let dbURL = try ThingsImportTestFixtures.makeTemporaryDatabase(
      areas: [(id: "area-1", title: "Home")],
      projects: [(id: "proj-1", title: "Renovation", areaID: "area-1")],
      tasks: [(id: "task-1", title: "Buy paint", areaID: nil, projectID: "proj-1", status: 0, today: true)]
    )
    defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

    let snapshot = try ThingsImportParser.parse(databaseURL: dbURL, options: ThingsImportOptions(), copyToScratchpad: false)
    #expect(snapshot.areas.count == 1)
    #expect(snapshot.projects.count == 1)
    #expect(snapshot.tasks.count == 1)
    #expect(snapshot.tasks[0].title == "Buy paint")
    #expect(snapshot.tasks[0].today == true)
    #expect(snapshot.tasks[0].projectID == "proj-1")
  }

  @Test func parserSkipsCompletedUnlessRequested() throws {
    let dbURL = try ThingsImportTestFixtures.makeTemporaryDatabase(
      tasks: [(id: "t1", title: "Done task", areaID: nil, projectID: nil, status: 3, today: false)]
    )
    defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

    var options = ThingsImportOptions()
    options.includeCompleted = false
    #expect(throws: ThingsImportError.emptyDatabase) {
      _ = try ThingsImportParser.parse(databaseURL: dbURL, options: options, copyToScratchpad: false)
    }

    options.includeCompleted = true
    let with = try ThingsImportParser.parse(databaseURL: dbURL, options: options, copyToScratchpad: false)
    #expect(with.tasks.count == 1)
    #expect(with.tasks[0].status == .completed)
  }

  @Test func mapperMergesAreaByTitle() {
    ThingsImportMapping.resetAll()
    defer { ThingsImportMapping.resetAll() }

    let snapshot = ThingsDatabaseSnapshot(
      areas: [ThingsAreaRecord(id: "things-area", title: "Home", trashed: false)],
      projects: [],
      tasks: [ThingsTaskRecord(
        id: "things-task", title: "Fix sink", notes: nil, areaID: "things-area", projectID: nil,
        status: .open, trashed: false, sortIndex: 1, today: false, scheduled: nil, deadline: nil,
        created: nil, completedAt: nil, tags: [], checklistLines: []
      )]
    )
    let existing = ThingsToSeptenaMapper.ExistingState(
      areas: [(id: "home1", title: "Home")],
      projects: [],
      liveTaskSeptenaIDs: [],
      deletedMappedThingsTaskIDs: []
    )
    var options = ThingsImportOptions()
    options.mergeMatchingTitles = true

    let plan = ThingsToSeptenaMapper.buildPlan(
      snapshot: snapshot,
      existing: existing,
      options: options,
      idGenerator: { "newid" }
    )

    #expect(plan.areasToCreate.isEmpty)
    #expect(plan.areaIDByThingsID["things-area"] == "home1")
    #expect(plan.tasksToImport.count == 1)
    #expect(plan.tasksToImport[0].areaSeptenaID == "home1")
  }

  @Test func mapperCreatesDuplicateAreaWhenMergeOff() {
    ThingsImportMapping.resetAll()
    defer { ThingsImportMapping.resetAll() }

    let snapshot = ThingsDatabaseSnapshot(
      areas: [ThingsAreaRecord(id: "things-area", title: "Home", trashed: false)],
      projects: [],
      tasks: []
    )
    let existing = ThingsToSeptenaMapper.ExistingState(
      areas: [(id: "home1", title: "Home")],
      projects: [],
      liveTaskSeptenaIDs: [],
      deletedMappedThingsTaskIDs: []
    )
    var options = ThingsImportOptions()
    options.mergeMatchingTitles = false

    var counter = 0
    let plan = ThingsToSeptenaMapper.buildPlan(
      snapshot: snapshot,
      existing: existing,
      options: options,
      idGenerator: {
        defer { counter += 1 }
        return "id\(counter)"
      }
    )

    #expect(plan.areasToCreate.count == 1)
    #expect(plan.areasToCreate[0].title == "Home (Things)")
  }

  @Test func mapperSkipsPreviouslyImportedTask() {
    ThingsImportMapping.resetAll()
    defer { ThingsImportMapping.resetAll() }

    ThingsImportMapping.setTask(thingsID: "things-1", septenaID: "exist1")

    let snapshot = ThingsDatabaseSnapshot(
      areas: [],
      projects: [],
      tasks: [ThingsTaskRecord(
        id: "things-1", title: "Again", notes: nil, areaID: nil, projectID: nil,
        status: .open, trashed: false, sortIndex: 0, today: false, scheduled: nil, deadline: nil,
        created: nil, completedAt: nil, tags: [], checklistLines: []
      )]
    )
    let existing = ThingsToSeptenaMapper.ExistingState(
      areas: [],
      projects: [],
      liveTaskSeptenaIDs: ["exist1"],
      deletedMappedThingsTaskIDs: []
    )

    let plan = ThingsToSeptenaMapper.buildPlan(
      snapshot: snapshot,
      existing: existing,
      options: ThingsImportOptions()
    )

    #expect(plan.tasksToImport.isEmpty)
    #expect(plan.skippedDuplicates == 1)
  }

  @Test func mapperViewCountsInboxVsToday() {
    let snapshot = ThingsDatabaseSnapshot(
      areas: [],
      projects: [],
      tasks: [
        ThingsTaskRecord(
          id: "inbox", title: "Loose", notes: nil, areaID: nil, projectID: nil,
          status: .open, trashed: false, sortIndex: 0, today: false, scheduled: nil, deadline: nil,
          created: nil, completedAt: nil, tags: [], checklistLines: []
        ),
        ThingsTaskRecord(
          id: "today", title: "Pinned", notes: nil, areaID: nil, projectID: nil,
          status: .open, trashed: false, sortIndex: 1, today: true, scheduled: nil, deadline: nil,
          created: nil, completedAt: nil, tags: [], checklistLines: []
        ),
      ]
    )
    let plan = ThingsToSeptenaMapper.buildPlan(
      snapshot: snapshot,
      existing: .init(areas: [], projects: [], liveTaskSeptenaIDs: [], deletedMappedThingsTaskIDs: []),
      options: ThingsImportOptions()
    )
    #expect(plan.viewCounts.inbox == 1)
    #expect(plan.viewCounts.today == 1)
  }
}
