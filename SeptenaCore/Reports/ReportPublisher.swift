import Foundation

// MARK: - ReportPublisher
//
// Pushes a computed `ReportPayload` to the reports Worker so it can be served at
// <baseURL>/r/<token>. Compiled but NOT yet wired into the UI — turning on the
// real link is a follow-up once the Worker is deployed (see
// docs/PRACTITIONER_REPORTS_PROTOTYPE.md). Kept here so the app-side half of the
// "auto-refreshing snapshot" is ready to call.
//
// PROTOTYPE transport only: no App Attest assertion yet. The production design
// (App Attest gate, expiry, revoke) is in docs/PRACTITIONER_REPORTS_SPEC.md.

public enum ReportPublisher {

  public enum PublishError: Error { case badResponse(Int), encoding }

  /// PUT the payload to the Worker, keyed by `token`. Returns the public
  /// `/r/<token>` URL on success.
  @discardableResult
  public static func push(payload: ReportPayload,
                          token: String,
                          baseURL: URL,
                          session: URLSession = .shared) async throws -> URL {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/reports/\(token)"))
    req.httpMethod = "PUT"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body = PushBody(token: token, payload: payload)
    guard let data = try? JSONEncoder().encode(body) else { throw PublishError.encoding }
    req.httpBody = data

    let (_, response) = try await session.data(for: req)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else { throw PublishError.badResponse(code) }
    return baseURL.appendingPathComponent("r/\(token)")
  }

  private struct PushBody: Encodable {
    let token: String
    let payload: ReportPayload
  }
}
