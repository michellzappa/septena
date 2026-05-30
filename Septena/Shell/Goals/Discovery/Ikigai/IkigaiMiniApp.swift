import SwiftUI

enum IkigaiMiniApp: DiscoveryMiniApp {
  static let id = "ikigai"
  static let title = "Purpose"
  static let blurb = "Map what you love, do well, can offer, and want to serve."
  static let systemImage = "sparkles"
  static let accent = Color.teal

  static func makeView(onFinish: @escaping ([DraftGoal]) -> Void) -> AnyView {
    AnyView(IkigaiFlowView(onFinish: onFinish))
  }
}
