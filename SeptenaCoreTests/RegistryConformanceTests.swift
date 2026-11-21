import Foundation
import Testing

/// Executes the language-neutral golden fixtures under `registry/conformance/*.json`
/// against Swift's `RecurrenceDateCalculator`, `TaskFade`, and `deriveConvo`.
/// The TypeScript backend runs the exact same JSON files (`backend/test/conformance.test.ts`).
@Suite struct RegistryConformanceTests {
  private static var conformanceDir: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // SeptenaCoreTests
      .deletingLastPathComponent() // repo root
      .appendingPathComponent("registry/conformance")
  }

  private static func load<T: Decodable>(_ filename: String, as type: T.Type) throws -> T {
    let url = conformanceDir.appendingPathComponent(filename)
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: data)
  }

  // MARK: - Recurrence

  private struct RecurrenceFixture: Decodable {
    struct NextCase: Decodable {
      struct Input: Decodable {
        let completedOn: String
        let scheduled: String?
        let logicalScheduled: String?
        let unit: String
        let interval: Int
        let afterCompletion: Bool
      }
      let name: String
      let input: Input
      let expected: String?
    }
    struct OccurrenceCase: Decodable {
      let sourceTaskID: String
      let scheduled: String
      let expected: String
    }
    let nextScheduledDate: [NextCase]
    let occurrenceID: [OccurrenceCase]
  }

  @Test func recurrenceConformance() throws {
    let fixture = try Self.load("recurrence.json", as: RecurrenceFixture.self)
    for c in fixture.nextScheduledDate {
      let actual = RecurrenceDateCalculator.nextDate(
        completedOn: c.input.completedOn,
        scheduled: c.input.scheduled,
        logicalScheduled: c.input.logicalScheduled,
        unit: c.input.unit,
        interval: c.input.interval,
        afterCompletion: c.input.afterCompletion
      )
      #expect(actual == c.expected, "nextScheduledDate failed for: \(c.name)")
    }
    for c in fixture.occurrenceID {
      let actual = RecurrenceDateCalculator.occurrenceID(
        sourceTaskID: c.sourceTaskID,
        scheduled: c.scheduled
      )
      #expect(actual == c.expected, "occurrenceID failed for: \(c.sourceTaskID)|\(c.scheduled)")
    }
  }

  // MARK: - TaskFade

  private struct FadeFixture: Decodable {
    struct OpacityCase: Decodable {
      let name: String
      let fill: Double?
      let expected: Double
    }
    struct ShouldFadeCase: Decodable {
      struct Input: Decodable {
        let isOpen: Bool
        let isHeading: Bool
        let isDeleted: Bool
        let isFaded: Bool
        let deadline: String?
        let scheduled: String?
        let hasRecurrence: Bool
        let isAgentTurn: Bool
        let isAssignedToClaude: Bool
        let touchedAt: Date?
        let createdAt: Date
        let created: String?
        let now: Date
        let today: String
      }
      let name: String
      let input: Input
      let expected: Bool
    }
    let rowOpacity: [OpacityCase]
    let shouldFade: [ShouldFadeCase]
  }

  @Test func taskFadeConformance() throws {
    let fixture = try Self.load("task-fade.json", as: FadeFixture.self)
    for c in fixture.rowOpacity {
      let actual = TaskFade.rowOpacity(c.fill)
      #expect(abs(actual - c.expected) < 0.0001, "rowOpacity failed for: \(c.name)")
    }
    for c in fixture.shouldFade {
      let i = c.input
      let actual = TaskFade.shouldFade(
        isOpen: i.isOpen,
        isHeading: i.isHeading,
        isDeleted: i.isDeleted,
        isFaded: i.isFaded,
        deadline: i.deadline,
        scheduled: i.scheduled,
        hasRecurrence: i.hasRecurrence,
        isAgentTurn: i.isAgentTurn,
        isAssignedToClaude: i.isAssignedToClaude,
        touchedAt: i.touchedAt,
        createdAt: i.createdAt,
        created: i.created,
        now: i.now,
        today: i.today
      )
      #expect(actual == c.expected, "shouldFade failed for: \(c.name)")
    }
  }

  // MARK: - Conversation derivation

  private struct ConvoFixture: Decodable {
    struct Case: Decodable {
      struct ConvoInput: Decodable {
        let confirmedIntent: String?
        let acceptance: String?
        let assignee: ConvoAssignee?
        let endState: ConvoEndState?
        let endStateNote: String?
        let stoppedAt: Date?
        let thread: [ConvoTurn]
      }
      struct Expected: Decodable {
        let stage: String
        let badge: String?
        let pendingReasoning: Bool
      }
      let name: String
      let convo: ConvoInput
      let expected: Expected
    }
    let cases: [Case]
  }

  @Test func convoDerivedConformance() throws {
    let fixture = try Self.load("convo-derived.json", as: ConvoFixture.self)
    for c in fixture.cases {
      var convo = TaskConvo()
      convo.confirmedIntent = c.convo.confirmedIntent
      convo.acceptance = c.convo.acceptance
      convo.assignee = c.convo.assignee
      convo.endState = c.convo.endState
      convo.endStateNote = c.convo.endStateNote
      convo.stoppedAt = c.convo.stoppedAt
      convo.thread = c.convo.thread

      let derived = deriveConvo(convo)
      let stageName: String = switch derived.stage {
      case .open: "open"
      case .clarifying: "clarifying"
      case .inProgress: "inProgress"
      case .awaitingHuman: "awaitingHuman"
      case .terminal: "terminal"
      }
      let badgeName: String? = switch derived.badge {
      case nil: nil
      case .needsYou: "needsYou"
      case .working: "working"
      case .done: "done"
      case .wontDo: "wontDo"
      }
      #expect(stageName == c.expected.stage, "stage failed for: \(c.name)")
      #expect(badgeName == c.expected.badge, "badge failed for: \(c.name)")
      #expect(derived.pendingReasoning == c.expected.pendingReasoning, "pendingReasoning failed for: \(c.name)")
    }
  }

  // MARK: - Generated registry sanity (R1–R4)

  @Test func generatedRegistriesCoverCoreContracts() {
    #expect(RegistrySettings.syncedKeys.contains("welcomeName"))
    #expect(RegistrySettings.syncedKeys.contains("agentsPaused"))
    #expect(RegistryDestinations.viewAliases["someday"] == "anytime")
    #expect(RegistryDestinations.viewAliases["triage"] == "inbox")
    #expect(RegistryDestinations.byNavigationKey["today"]?.sfSymbol == "sun.max.fill")
    #expect(RegistryDestinations.byNavigationKey["review"]?.title == "Review")
    #expect(RegistryTokens.accentPalette.count == 16)
    #expect(RegistryTokens.textScaleFactors.count == 5)
    #expect(RegistrySurfaces.maxConcurrentExplainers == 1)
    #expect(RegistrySurfaces.prompts["deleteSection"]?.confirmTitle == "Delete Section")
    #expect(RegistryCapabilities.isShipped("lists.today", on: "macos"))
    #expect(!RegistryCapabilities.isShipped("lists.today", on: "web"))
    // Ensure iPad excludes macOS-only ⌃⌘S sidebar shortcut
    let sidebar = RegistryActions.shortcutsGeneral.first { $0.id == "app.toggleSidebar" }
    #expect(sidebar?.keycaps == ["⌃", "⌘", "S"])
    #expect(sidebar?.excludePlatforms.contains("ipados") == true)
  }
}
