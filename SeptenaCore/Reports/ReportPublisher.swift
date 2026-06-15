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
                          html: String,
                          token: String,
                          expiresAt: String? = nil,
                          baseURL: URL,
                          session: URLSession = .shared) async throws -> URL {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/reports/\(token)"))
    req.httpMethod = "PUT"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body = PushBody(token: token, payload: payload, html: html, expiresAt: expiresAt)
    guard let data = try? JSONEncoder().encode(body) else { throw PublishError.encoding }
    req.httpBody = data
    // App Attest assertion bound to the exact body bytes (best-effort: nil on
    // Simulator / when unsupported — the worker accepts unattested in audit mode).
    await attach(&req, body: data, baseURL: baseURL, session: session)

    let (_, response) = try await session.data(for: req)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else { throw PublishError.badResponse(code) }
    return baseURL.appendingPathComponent("r/\(token)")
  }

  /// Revoke a link — deletes the blob so `/r/<token>` 404s immediately.
  public static func revoke(token: String,
                            baseURL: URL,
                            session: URLSession = .shared) async throws {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/reports/\(token)"))
    req.httpMethod = "DELETE"
    // Revoke binds its assertion to the token bytes (no JSON body).
    await attach(&req, body: Data(token.utf8), baseURL: baseURL, session: session)
    let (_, response) = try await session.data(for: req)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else { throw PublishError.badResponse(code) }
  }

  /// ISO8601 instant `days` from now, or nil for "never".
  public static func expiry(daysFromNow days: Int?) -> String? {
    guard let days else { return nil }
    let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    return ISO8601DateFormatter().string(from: date)
  }

  /// Attach App Attest headers if a valid assertion can be produced. No-op when
  /// unsupported — keeps dev/Simulator working while the worker is in audit mode.
  private static func attach(_ req: inout URLRequest, body: Data, baseURL: URL, session: URLSession) async {
    guard let a = await AppAttestClient.shared.assertion(forBody: body, baseURL: baseURL, session: session) else { return }
    req.setValue(a.keyId, forHTTPHeaderField: "X-Attest-Key-Id")
    req.setValue(a.assertionB64, forHTTPHeaderField: "X-Attest-Assertion")
    req.setValue(a.challenge, forHTTPHeaderField: "X-Attest-Challenge")
  }

  private struct PushBody: Encodable {
    let token: String
    let payload: ReportPayload
    let html: String
    let expiresAt: String?
  }
}
