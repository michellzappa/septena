import SwiftUI
import WidgetKit

@main
struct SeptaskWidgetsBundle: WidgetBundle {
  var body: some Widget {
    SeptaskTasksWidget()
    #if os(iOS)
    SeptaskDoActivity()
    #endif
  }
}
