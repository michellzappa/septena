import Foundation
import Testing

/// Runs `registry/shell-conformance/navigation-history.json` against
/// `NavigationHistory` (#849). Android runs the same file.
@Suite struct NavigationHistoryTests {
  private struct Fixture: Decodable {
    struct Step: Decodable {
      let op: String
      let entry: String?
      let expect: String?
    }
    struct Expected: Decodable {
      let current: String?
      let back: [String]
      let forward: [String]
    }
    struct Case: Decodable {
      let name: String
      let limit: Int?
      let steps: [Step]
      let expected: Expected
    }
    let cases: [Case]
  }

  private static func fixture() throws -> Fixture {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("registry/shell-conformance/navigation-history.json")
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }

  @Test func conformance() throws {
    let cases = try Self.fixture().cases
    #expect(!cases.isEmpty)
    for c in cases {
      var history = NavigationHistory<String>(limit: c.limit ?? RegistryRules.navigationHistoryLimit)
      var removed = Set<String>()
      let exists: (String) -> Bool = { !removed.contains($0) }
      for (index, step) in c.steps.enumerated() {
        switch step.op {
        case "visit":
          history.visit(try #require(step.entry))
        case "back":
          #expect(history.goBack(exists: exists) == step.expect, "\(c.name): step \(index)")
        case "forward":
          #expect(history.goForward(exists: exists) == step.expect, "\(c.name): step \(index)")
        case "remove":
          removed.insert(try #require(step.entry))
        default:
          Issue.record("\(c.name): unknown op \(step.op)")
        }
      }
      #expect(history.current == c.expected.current, "\(c.name): current")
      #expect(history.back == c.expected.back, "\(c.name): back")
      #expect(history.forward == c.expected.forward, "\(c.name): forward")
    }
  }

  @Test func limitComesFromTheRegistry() {
    #expect(RegistryRules.navigationHistoryLimit == 50)
    #expect(NavigationHistory<String>().limit == 50)
  }
}
