import SwiftUI

struct DraftGoal: Identifiable, Hashable {
  enum Kind: Hashable {
    case purpose
    case commitment
  }

  let id = UUID()
  var text: String
  var sections: [String] = []
  var include = true
  var kind: Kind = .commitment
  var metricKey: String? = nil
  var metricWindow: String? = nil
  var metricComparator: String? = nil
  var metricTarget: Double? = nil
  var metricBaseline: Double? = nil
}

@MainActor
protocol DiscoveryMiniApp {
  static var id: String { get }
  static var title: String { get }
  static var blurb: String { get }
  static var systemImage: String { get }
  static var accent: Color { get }
  static func makeView(onFinish: @escaping ([DraftGoal]) -> Void) -> AnyView
}

struct DiscoveryMiniAppDescriptor: Identifiable {
  let id: String
  let title: String
  let blurb: String
  let systemImage: String
  let accent: Color
  let makeView: @MainActor (@escaping ([DraftGoal]) -> Void) -> AnyView
}

extension DiscoveryMiniApp {
  static var descriptor: DiscoveryMiniAppDescriptor {
    DiscoveryMiniAppDescriptor(
      id: id,
      title: title,
      blurb: blurb,
      systemImage: systemImage,
      accent: accent,
      makeView: makeView
    )
  }
}

struct AnyDiscoveryMiniApp: Identifiable {
  let id: String
  let descriptor: DiscoveryMiniAppDescriptor

  init(descriptor: DiscoveryMiniAppDescriptor) {
    self.id = descriptor.id
    self.descriptor = descriptor
  }
}

@MainActor
enum DiscoveryRegistry {
  static let all: [DiscoveryMiniAppDescriptor] = [
    IkigaiMiniApp.descriptor,
  ]
}
