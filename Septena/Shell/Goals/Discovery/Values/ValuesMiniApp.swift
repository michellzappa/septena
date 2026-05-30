import SwiftUI

enum ValuesMiniApp: DiscoveryMiniApp {
  static let id = "values"
  static let title = "Values"
  static let blurb = "Choose what matters most, then turn it into concrete goals."
  static let systemImage = "star.circle.fill"
  static let accent = Color.red

  static func makeView(onFinish: @escaping ([DraftGoal]) -> Void) -> AnyView {
    AnyView(ValuesFlowView(onFinish: onFinish))
  }
}
