import SwiftUI
import SwiftData

@MainActor
enum TasksPlugin: SectionPlugin {
  static var producesTimedEvents: Bool { true }

  static var manifest: SectionManifest {
    SectionManifest.byKey["tasks"]!
  }

  // The homepage Tasks tile opens this light drawer — today's tasks +
  // inline capture, on the shared `SectionDrawer` chrome — exactly like
  // every other section. The deep areas / projects / scheduling surface
  // stays on the Tasks tab (`TaskListView`); the "Open in" setting lets a
  // user route the tile straight there instead.
  static func destinationView() -> AnyView? { AnyView(TasksDestinationView()) }

  static func detailPaneContent() -> AnyView? { AnyView(TasksDetailContent()) }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "task", purpose: "one row per task / to-do", fields: [
          .req("id", "string"), .req("title", "string"),
          .opt("status", "string", "open | done | cancelled"),
          .opt("created", "date"), .opt("scheduled", "date"),
          .opt("deadline", "date"), .opt("today", "bool"),
          .opt("todaySetOn", "date"), .opt("completedAt", "timestamp"),
          .opt("area", "string", "area id"),
          .opt("project", "string", "project id"),
          .opt("notes", "string"),
          .opt("recurrenceUnit", "string", "day | week | month | year"),
          .opt("recurrenceInterval", "int"),
          .opt("recurrenceAfterCompletion", "bool"),
        ]),
        SchemaTable(name: "project", purpose: "a project grouping tasks", fields: [
          .req("id", "string"), .req("title", "string"),
          .opt("status", "string", "active | completed | cancelled"),
          .opt("area", "string", "area id"),
          .opt("created", "date"), .opt("completedAt", "timestamp"),
          .opt("notes", "string"), .opt("context", "string"),
        ]),
        SchemaTable(name: "area", purpose: "a top-level area of life", fields: [
          .req("id", "string"), .req("title", "string"),
          .opt("context", "string"),
        ]),
      ],
      collect: { ctx in
        // Headings are project section dividers, not to-dos — don't export
        // them as tasks (see `TaskEntity.isHeading`).
        let tasks    = try ctx.fetch(FetchDescriptor<TaskEntity>())
                          .filter { !$0.isHeading }
        let projects = try ctx.fetch(FetchDescriptor<ProjectEntity>())
        let areas    = try ctx.fetch(FetchDescriptor<AreaEntity>())
        return [
          "task":    tasks.map(taskExportDict),
          "project": projects.map(projectExportDict),
          "area":    areas.map(areaExportDict),
        ]
      }
    )
  }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionOnboarding(
      sectionKey: "tasks",
      intro: "Tasks route by intent, not by tags. Three fields decide visibility — today, scheduled, and deadline.",
      bullets: [
        .init("Inbox", "No today / scheduled / deadline → lands in Inbox. The parking spot for anything not yet committed.", icon: "tray"),
        .init("Today", "Pin to Today to commit. Use it for what you'll actually do today.", icon: "sun.max"),
        .init("Scheduled / deadline", "Scheduled puts it in Upcoming. A deadline adds a hard date without scheduling — both surface in Anytime.", icon: "calendar"),
        .init("Areas & projects", "Tags for filtering only — not routing. A project task with no view pin still sits in Inbox.", icon: "folder"),
      ],
      complete: complete
    ))
  }

  static var mcpSkill: SectionSkill? {
    // Brief relocated to Shell/Tasks/TasksSkill.swift (shared with Septask).
    TasksSkill.skill
  }
}

// Thin full-app adapter: the actual rows live in Shell/Tasks/
// TaskSettingsSections.swift, shared with Septask's dedicated Settings
// (docs/SEPTASK.md) so the two apps' task knobs can't drift.
private struct TasksDetailContent: View {
  var body: some View {
    TaskSettingsSections()
  }
}

@MainActor func taskExportDict(_ e: TaskEntity) -> [String: Any] {
  compact([
    "id": e.id, "title": e.title, "status": e.statusRaw,
    "created": e.created, "scheduled": e.scheduled, "deadline": e.deadline,
    "today": e.today, "todaySetOn": e.todaySetOn, "completedAt": e.completedAt,
    "area": e.area, "project": e.project, "notes": e.notes,
    "recurrenceUnit": e.recurrenceUnit,
    "recurrenceInterval": e.recurrenceInterval,
    "recurrenceAfterCompletion": e.recurrenceAfterCompletion,
    "sortIndex": e.sortIndex,
    "updatedAt": e.updatedAt, "deletedAt": e.deletedAt,
  ])
}

@MainActor func projectExportDict(_ e: ProjectEntity) -> [String: Any] {
  compact([
    "id": e.id, "title": e.title, "status": e.statusRaw, "area": e.area,
    "created": e.created, "completedAt": e.completedAt,
    "notes": e.notes, "context": e.context, "githubRepo": e.githubRepo,
    "updatedAt": e.updatedAt, "deletedAt": e.deletedAt,
  ])
}

@MainActor func areaExportDict(_ e: AreaEntity) -> [String: Any] {
  compact([
    "id": e.id, "title": e.title, "context": e.context,
    "updatedAt": e.updatedAt,
  ])
}
