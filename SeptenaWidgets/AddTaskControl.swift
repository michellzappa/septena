import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen button — opens Septena on the Today quick-add
/// line. Control Widgets cannot prompt for `requestValueDialog` the way Siri
/// does, so this uses `OpenNewTaskControlIntent` instead of `AddTaskIntent`.
struct AddTaskControl: ControlWidget {
  static let kind = "com.septena.cloud.controls.addTask"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      ControlWidgetButton(action: OpenNewTaskControlIntent()) {
        Label("Add Task", systemImage: "checklist")
      }
    }
    .displayName("Add Task")
    .description("Open Septena to capture a to-do.")
  }
}
