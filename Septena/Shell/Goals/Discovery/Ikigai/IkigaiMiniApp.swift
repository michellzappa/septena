import SwiftUI

enum IkigaiMiniApp: DiscoveryMiniApp {
  static let id = "ikigai"
  static let title = String(localized: "Purpose", comment: "Discovery mini-app title")
  static let blurb = String(localized: "Map what you love, do well, can offer, and want to serve.", comment: "Discovery mini-app blurb")
  static let systemImage = "sparkles"
  static let accent = Color.teal

  static func makeView(onFinish: @escaping ([DraftGoal]) -> Void) -> AnyView {
    AnyView(IkigaiFlowView(onFinish: onFinish))
  }
}
