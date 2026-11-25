import Foundation

/// Base URL of the community worker (`community-worker/`), which receives the
/// app's telemetry. Override with UserDefaults while running `wrangler dev`.
public enum CommunityEndpoint {
  public static let defaultBaseURL = URL(string: "https://community.septena.app")!

  public static var baseURL: URL {
    if let s = UserDefaults.standard.string(forKey: "septena.community.baseURL"),
       let u = URL(string: s) {
      return u
    }
    return defaultBaseURL
  }
}
