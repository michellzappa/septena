#if DEBUG
import SwiftUI
import CloudKit

// Forensic view of the CloudKit zone. Fetches every Task/Area/Project
// record with a nil token (full replay), then renders raw decoded
// fields and any dangling references. Reads server state directly —
// independent of local SwiftData — so it stays useful even when the
// local mirror has drifted.

struct ServerInspectorReport: Identifiable {
  let id = UUID()
  struct AreaRow: Identifiable {
    let id: String          // recordName
    let entityID: String    // id without "area:" prefix
    let title: String
  }
  struct ProjectRow: Identifiable {
    let id: String
    let entityID: String
    let title: String
    let area: String?
  }
  struct TaskRow: Identifiable {
    let id: String
    let entityID: String
    let title: String
    let area: String?
    let project: String?
    let status: String?
  }
  var areas: [AreaRow]
  var projects: [ProjectRow]
  var tasks: [TaskRow]

  /// Sets of valid entity ids — used to compute dangling refs.
  var areaIDs: Set<String> { Set(areas.map(\.entityID)) }
  var projectIDs: Set<String> { Set(projects.map(\.entityID)) }

  /// task.area / project.area / task.project references that point at
  /// no existing record. Each tuple: (referencingId, missingTarget).
  var danglingTaskAreaRefs: [(task: String, area: String)] {
    tasks.compactMap { row in
      guard let a = row.area, !a.isEmpty, !areaIDs.contains(a) else { return nil }
      return (row.entityID, a)
    }
  }
  var danglingTaskProjectRefs: [(task: String, project: String)] {
    tasks.compactMap { row in
      guard let p = row.project, !p.isEmpty, !projectIDs.contains(p) else { return nil }
      return (row.entityID, p)
    }
  }
  var danglingProjectAreaRefs: [(project: String, area: String)] {
    projects.compactMap { row in
      guard let a = row.area, !a.isEmpty, !areaIDs.contains(a) else { return nil }
      return (row.entityID, a)
    }
  }

  static func build(from records: [CKRecord]) -> ServerInspectorReport {
    var areas: [AreaRow] = []
    var projects: [ProjectRow] = []
    var tasks: [TaskRow] = []
    for record in records {
      let recName = record.recordID.recordName
      switch record.recordType {
      case AreaCloudKitSchema.recordType:
        let entityID = AreaCloudKitSchema.entityID(from: recName)
        areas.append(.init(
          id: recName,
          entityID: entityID,
          title: (record[AreaCloudKitSchema.Field.title] as? String) ?? ""
        ))
      case ProjectCloudKitSchema.recordType:
        let entityID = ProjectCloudKitSchema.entityID(from: recName)
        projects.append(.init(
          id: recName,
          entityID: entityID,
          title: (record[ProjectCloudKitSchema.Field.title] as? String) ?? "",
          area: record[ProjectCloudKitSchema.Field.area] as? String
        ))
      case TaskCloudKitSchema.recordType:
        tasks.append(.init(
          id: recName,
          entityID: recName,
          title: (record[TaskCloudKitSchema.Field.title] as? String) ?? "",
          area: record[TaskCloudKitSchema.Field.area] as? String,
          project: record[TaskCloudKitSchema.Field.project] as? String,
          status: record[TaskCloudKitSchema.Field.status] as? String
        ))
      default:
        break
      }
    }
    areas.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    projects.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    tasks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    return .init(areas: areas, projects: projects, tasks: tasks)
  }
}

/// Action the inspector wants to perform — surfaced to SettingsView via
/// callback. Keeping the mutator types out of this file lets it stay in
/// the Septena target (which doesn't import SeptenaCore directly).
enum InspectorAction {
  case createArea(id: String, title: String)
  case createProject(id: String, title: String, area: String?)
  /// Clear the `area` field on every Task whose area currently matches
  /// the given id. Used to move tasks pointing at a missing/stale area
  /// (e.g. the literal "inbox" magic value left by migration) into the
  /// real Inbox, which is the area==nil AND project==nil logical bucket.
  case clearAreaFromTasks(areaId: String)
}

struct ServerInspectorSheet: View {
  let report: ServerInspectorReport
  let onAction: (InspectorAction) async -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var createAreaTarget: String?       // dangling area id
  @State private var createProjectTarget: String?    // dangling project id
  @State private var isWorking = false

  var body: some View {
    NavigationStack {
      List {
        Section("Summary") {
          LabeledContent("Areas", value: "\(report.areas.count)")
          LabeledContent("Projects", value: "\(report.projects.count)")
          LabeledContent("Tasks", value: "\(report.tasks.count)")
        }

        let dTaskArea = report.danglingTaskAreaRefs
        let dTaskProj = report.danglingTaskProjectRefs
        let dProjArea = report.danglingProjectAreaRefs
        if !dTaskArea.isEmpty || !dTaskProj.isEmpty || !dProjArea.isEmpty {
          Section {
            // Missing areas (referenced by tasks and/or projects). Merge
            // both sources so a "Create Area …" button shows next to a
            // single row regardless of who references it.
            let missingAreaCounts: [(String, Int)] = {
              var counts: [String: Int] = [:]
              for ref in dTaskArea { counts[ref.area, default: 0] += 1 }
              for ref in dProjArea { counts[ref.area, default: 0] += 1 }
              return counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
            }()
            if !missingAreaCounts.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text("Missing Areas").font(.caption.weight(.semibold))
                ForEach(missingAreaCounts, id: \.0) { id, count in
                  HStack {
                    Text(id).font(.caption.monospaced())
                    Spacer()
                    Text("\(count) ref\(count == 1 ? "" : "s")")
                      .font(.caption).foregroundStyle(.secondary)
                    // "inbox" is a magic logical bucket, not a real area —
                    // tasks referencing it should be cleared to nil so the
                    // Inbox filter (area==nil AND project==nil) catches them.
                    if id == "inbox" {
                      Button("Move to Inbox") {
                        Task {
                          isWorking = true
                          await onAction(.clearAreaFromTasks(areaId: id))
                          isWorking = false
                        }
                      }
                      .buttonStyle(.borderless)
                      .controlSize(.small)
                      .disabled(isWorking)
                    } else {
                      Button("Create…") { createAreaTarget = id }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(isWorking)
                    }
                  }
                }
              }
              .textSelection(.enabled)
            }
            if !dTaskProj.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text("Missing Projects").font(.caption.weight(.semibold))
                let missingProjectCounts = Dictionary(grouping: dTaskProj, by: \.project)
                  .map { ($0.key, $0.value.count) }
                  .sorted { $0.1 > $1.1 }
                ForEach(missingProjectCounts, id: \.0) { id, count in
                  HStack {
                    Text(id).font(.caption.monospaced())
                    Spacer()
                    Text("\(count) ref\(count == 1 ? "" : "s")")
                      .font(.caption).foregroundStyle(.secondary)
                    Button("Create…") { createProjectTarget = id }
                      .buttonStyle(.borderless)
                      .controlSize(.small)
                      .disabled(isWorking)
                  }
                }
              }
              .textSelection(.enabled)
            }
          } header: {
            Label("Dangling references", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          } footer: {
            Text("Fix by creating the missing record (CloudKit Console → Create New Record) with recordName matching the referenced id.")
          }
        }

        Section("Areas (\(report.areas.count))") {
          ForEach(report.areas) { row in
            VStack(alignment: .leading, spacing: 2) {
              Text(row.title.isEmpty ? "(untitled)" : row.title).font(.body)
              Text("id: \(row.entityID)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
              Text(row.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
          }
        }

        Section("Projects (\(report.projects.count))") {
          ForEach(report.projects) { row in
            VStack(alignment: .leading, spacing: 2) {
              Text(row.title.isEmpty ? "(untitled)" : row.title).font(.body)
              Text("id: \(row.entityID)   area: \(row.area ?? "—")")
                .font(.caption.monospaced())
                .foregroundStyle(row.area.map { report.areaIDs.contains($0) } == false ? .red : .secondary)
              Text(row.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
          }
        }

        Section("Tasks (\(report.tasks.count))") {
          ForEach(report.tasks) { row in
            VStack(alignment: .leading, spacing: 2) {
              Text(row.title.isEmpty ? "(untitled)" : row.title).font(.body)
              Text("area: \(row.area ?? "—")   project: \(row.project ?? "—")   status: \(row.status ?? "—")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
              Text(row.entityID).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
          }
        }
      }
      .navigationTitle("Server Inspector")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .disabled(isWorking)
        }
      }
      .sheet(item: Binding(
        get: { createAreaTarget.map { CreateTarget(id: $0, kind: .area) } },
        set: { createAreaTarget = $0?.id }
      )) { target in
        CreateRecordSheet(targetID: target.id, kind: .area, isWorking: $isWorking) { title in
          await onAction(.createArea(id: target.id, title: title))
        }
      }
      .sheet(item: Binding(
        get: { createProjectTarget.map { CreateTarget(id: $0, kind: .project) } },
        set: { createProjectTarget = $0?.id }
      )) { target in
        CreateRecordSheet(targetID: target.id, kind: .project, isWorking: $isWorking) { title in
          await onAction(.createProject(id: target.id, title: title, area: nil))
        }
      }
    }
    #if os(macOS)
    .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 720)
    #endif
  }
}

private struct CreateTarget: Identifiable {
  enum Kind { case area, project }
  let id: String
  let kind: Kind
}

private struct CreateRecordSheet: View {
  let targetID: String
  let kind: CreateTarget.Kind
  @Binding var isWorking: Bool
  let onSubmit: (String) async -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var title: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Id (immutable)", value: targetID)
            .font(.body.monospaced())
          TextField("Title", text: $title)
        } footer: {
          Text("Creates \(kind == .area ? "Area" : "Project") with recordName `\(kind == .area ? "area" : "project"):\(targetID)`. Existing dangling references will resolve on next fetch.")
        }
      }
      .navigationTitle(kind == .area ? "Create Area" : "Create Project")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(isWorking)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            Task {
              isWorking = true
              await onSubmit(title.trimmingCharacters(in: .whitespacesAndNewlines))
              isWorking = false
              dismiss()
            }
          }
          .disabled(isWorking || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    #if os(macOS)
    .frame(minWidth: 460, minHeight: 220)
    #endif
  }
}

private struct DanglingGroup: View {
  let title: String
  let items: [(String, Int)]   // (missingId, count)
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption.weight(.semibold))
      ForEach(items, id: \.0) { id, count in
        HStack {
          Text(id).font(.caption.monospaced())
          Spacer()
          Text("\(count) ref\(count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .textSelection(.enabled)
  }
}
#endif
