import SwiftUI

// Placeholder: tasks are currently edited inline. This is here so future
// nav links to a task can land somewhere instead of crashing.

struct TaskDetailView: View {
  let task: EngageTask

  var body: some View {
    Form {
      Section { Text(task.title).font(.title3) }
      if let notes = task.notes, !notes.isEmpty {
        Section("Notes") { Text(notes) }
      }
      Section("Meta") {
        if let s = task.scheduled { LabeledContent("Scheduled", value: s) }
        if let d = task.due { LabeledContent("Due", value: d) }
        if let a = task.area { LabeledContent("Area", value: a) }
        if let p = task.project { LabeledContent("Project", value: p) }
        LabeledContent("Status", value: task.status.rawValue)
      }
    }
    .navigationTitle(task.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}
