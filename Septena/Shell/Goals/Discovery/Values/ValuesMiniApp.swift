import SwiftUI

enum ValuesMiniApp: DiscoveryMiniApp {
  static let id = "values"
  static let title = String(localized: "Values", comment: "Discovery mini-app title")
  static let blurb = String(localized: "Choose what matters most, then turn it into concrete goals.", comment: "Discovery mini-app blurb")
  static let systemImage = "star.circle.fill"
  static let accent = Color.red

  static func makeView(onFinish: @escaping ([DraftGoal]) -> Void) -> AnyView {
    AnyView(ValuesFlowView(onFinish: onFinish))
  }
}
