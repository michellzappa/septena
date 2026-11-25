import Foundation
import SwiftData

// Lookups over the generated registry copy (ADR 0020). The copy and its
// translations live in `registry/surfaces.json` and `registry/l10n/`; this
// file only finds a row by id, or counts what a prompt's wording needs.
// Never put wording here.

extension RegistryPromptCopy {
  /// A fork prompt's choice title by option id.
  func optionTitle(_ id: RegistryPromptOptionID) -> String {
    guard let option = options.first(where: { $0.id == id }) else {
      preconditionFailure("registry prompt \(self.id) has no option \(id)")
    }
    return option.title
  }
}

extension RegistryPrompts {
  /// A text prompt (New / Rename Section, Area, Project) by id.
  static func textPrompt(_ id: RegistryPromptID) -> RegistryTextPrompt {
    guard let row = text[id] else { preconditionFailure("registry/surfaces.json has no text prompt \(id)") }
    return row
  }

  /// A prompt with fixed copy (Delete Section, Delete Account, …) by id.
  static func prompt(_ id: RegistryPromptID) -> RegistryPromptCopy {
    guard let row = fixed[id] else { preconditionFailure("registry/surfaces.json has no prompt \(id)") }
    return row
  }
}

/// The confirmation every shell shows before an area / project delete: what
/// goes, how many tasks go with it, where they go, and that ⌘Z brings it all
/// back. This counts; the wording is `registry/surfaces.json` `prompts`
/// (`RegistryPrompts.deleteArea` / `deleteProject`), one for every shell.
@MainActor
extension RegistryPrompts {
  static func deleteProject(id: String, title: String, context: ModelContext) -> RegistryPromptCopy {
    let tasks = LocalCache.allTasks(in: context).filter { $0.project == id }.count
    return deleteProject(name: title, tasks: tasks)
  }

  static func deleteArea(id: String, title: String, context: ModelContext) -> RegistryPromptCopy {
    let projectIDs = Set(((try? context.fetch(FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.area == id }
    ))) ?? []).map(\.id))
    let tasks = LocalCache.allTasks(in: context).filter {
      $0.area == id || $0.project.map(projectIDs.contains) == true
    }.count
    return deleteArea(name: title, projects: projectIDs.count, tasks: tasks)
  }
}
