#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only curated dataset for App Store / marketing screenshots and UI
/// keyboard-contract tests. Inserts directly into the `ModelContext` (NOT
/// mutators — no sync, no notifications). Only runs when `DemoSeedMode.isOn`,
/// against the in-memory store, so it never touches real data.
public enum DemoSeed {
  static let days = 90

  @MainActor
  public static func populate(context ctx: ModelContext, today: String) {
    guard (try? ctx.fetchCount(FetchDescriptor<TaskEntity>())) == 0 else { return }
    var rng = SeededRNG(seed: 0x5EED_5E97_A11_C0DE)

    seedTasks(ctx, &rng)
    if ProcessInfo.processInfo.arguments.contains("-SeptenaTaskContractSeed") {
      seedTaskKeyboardContract(ctx)
    }
    StoreHealth.save(ctx, op: "DemoSeed.populate")
  }

  // MARK: - date helpers (offset 0 = today, negative = past)

  private static func dateObj(_ off: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: off, to: Date()) ?? Date()
  }
  private static func day(_ off: Int) -> String { SeptenaDate.format(dateObj(off)) ?? SeptenaDate.today }

  // MARK: - tasks, areas, projects

  private static func seedAreasProjects(_ ctx: ModelContext) {
    for (id, title) in [("area-work", "Work"), ("area-personal", "Personal"), ("area-health", "Health")] {
      ctx.insert(AreaEntity(id: id, title: title))
    }
    for (id, title, area) in [
      ("proj-q3", "Q3 launch", "area-work"),
      ("proj-website", "Website redesign", "area-work"),
      ("proj-move", "Apartment move", "area-personal"),
      ("proj-marathon", "Marathon training", "area-health"),
    ] {
      ctx.insert(ProjectEntity(id: id, title: title, area: area, created: day(-45)))
    }
  }

  private static func seedTasks(_ ctx: ModelContext, _ rng: inout SeededRNG) {
    seedAreasProjects(ctx)
    var pos = 1024.0
    let open: [(String, Bool, String?, String?)] = [
      ("Reply to the landlord", false, nil, nil),
      ("Renew the parking permit", false, nil, nil),
      ("Text Mom back", false, nil, nil),
      ("Cancel the unused subscription", false, nil, nil),
      ("Call the dentist", true, nil, nil),
      ("Draft the Q3 plan", true, "area-work", "proj-q3"),
      ("Finalize the launch checklist", false, "area-work", "proj-q3"),
      ("Review the design doc", true, "area-work", "proj-website"),
      ("Book flights for the trip", false, "area-personal", "proj-move"),
      ("Pack the kitchen", false, "area-personal", "proj-move"),
      ("20-mile long run", false, "area-health", "proj-marathon"),
      ("Buy new running shoes", false, "area-health", "proj-marathon"),
    ]
    for (i, t) in open.enumerated() {
      ctx.insert(TaskEntity(id: "demo-task-open-\(i)", title: t.0, today: t.1,
                            area: t.2, project: t.3, position: pos)); pos += 1024
    }
    let projects = [("proj-q3", "area-work"), ("proj-website", "area-work"),
                    ("proj-move", "area-personal"), ("proj-marathon", "area-health")]
    let verbs = ["Email", "Call", "Review", "Pay", "Schedule", "Fix", "Plan", "Send", "Order", "Book", "Tidy", "File"]
    let nouns = ["the report", "the invoice", "the team", "the bill", "the notes", "the bug",
                 "the draft", "the update", "the brief", "the form", "the deck", "the PR"]
    var n = 0
    for d in 0..<days {
      for _ in 0..<rng.int(1, 4) {
        let title = "\(verbs[rng.int(0, verbs.count - 1)]) \(nouns[rng.int(0, nouns.count - 1)])"
        var area: String?
        var project: String?
        if rng.chance(0.35) {
          let p = projects[rng.int(0, projects.count - 1)]; project = p.0; area = p.1
        }
        ctx.insert(TaskEntity(id: "demo-task-h-\(n)", title: title, statusRaw: TaskStatus.done.rawValue,
                              created: day(-d - rng.int(0, 2)), completedAt: day(-d),
                              area: area, project: project, position: pos))
        n += 1; pos += 1024
      }
    }
  }

  /// Dense Today list used only by executable keyboard-contract UI tests.
  private static func seedTaskKeyboardContract(_ ctx: ModelContext) {
    for index in 0..<48 {
      let ordinal = String(format: "%02d", index + 1)
      ctx.insert(TaskEntity(
        id: "demo-keyboard-task-\(index)",
        title: "Keyboard Contract \(ordinal)",
        today: true,
        position: 1_000_000 + Double(index) * 1_024
      ))
    }
    ctx.insert(TaskEntity(
      id: "demo-keyboard-hidden-completed",
      title: "Hidden keyboard-contract completion",
      statusRaw: TaskStatus.done.rawValue,
      today: true,
      completedAt: day(0),
      position: 1_000_000 + 2_560
    ))
  }
}

/// Deterministic SplitMix64 — reproducible "random" so screenshots are stable.
struct SeededRNG: RandomNumberGenerator {
  private var s: UInt64
  init(seed: UInt64) { s = seed }
  mutating func next() -> UInt64 {
    s &+= 0x9E37_79B9_7F4A_7C15
    var z = s
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
  mutating func int(_ lo: Int, _ hi: Int) -> Int { Int.random(in: lo...hi, using: &self) }
  mutating func dbl(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo...hi, using: &self) }
}
#endif
