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

  @Test func parserReadsHeadingsAndMembership() throws {
    let dbURL = try ThingsImportTestFixtures.makeTemporaryDatabase(
      projects: [(id: "proj-1", title: "Renovation", areaID: nil)],
      tasks: [(id: "task-1", title: "Buy paint", areaID: nil, projectID: "proj-1", status: 0, today: false)],
      headings: [(id: "head-1", title: "Kitchen", projectID: "proj-1", index: 5)],
      taskHeadings: ["task-1": "head-1"]
    )
    defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

    let snapshot = try ThingsImportParser.parse(databaseURL: dbURL, options: ThingsImportOptions(), copyToScratchpad: false)
    #expect(snapshot.headings.count == 1)
    #expect(snapshot.headings[0].title == "Kitchen")
    #expect(snapshot.headings[0].projectID == "proj-1")
    #expect(snapshot.headings[0].sortIndex == 5)
    #expect(snapshot.tasks.count == 1)   // the type=2 row is NOT a task
    #expect(snapshot.tasks[0].headingID == "head-1")
  }
}
