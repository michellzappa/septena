import Foundation
import CryptoKit
#if canImport(DeviceCheck)
import DeviceCheck
#endif

// MARK: - AppAttestClient
//
// Generic App Attest client — proves to a Cloudflare Worker that a write came
// from the genuine, unmodified Septena app on a real Apple device. Anonymous
// (it doesn't identify the user) and keyless (no API token in the open-source
// client). NOT reports-specific: the Feedback feature reuses this verbatim by
// pointing it at its own worker base URL.
//
// Protocol (matches reports-worker/src/attest.ts):
//   • register (once per install): generateKey → fetch challenge →
//     attestKey(clientDataHash: SHA256(challenge)) → POST /api/attest/register
//     {keyId, attestation, challenge}. Persist keyId on success.
//   • per write: fetch challenge → assertion = generateAssertion(keyId,
//     clientDataHash: SHA256(body ‖ challenge)). Send keyId + assertion +
//     challenge alongside the request; the worker recomputes the same hash.
//
// `assertion(forBody:baseURL:)` returns nil when App Attest is unavailable
// (Simulator, enclave-less Mac) or any step fails — callers then send the write
// unattested, which the worker accepts in "audit" mode and rejects in "enforce"
// mode. So enabling enforcement is a server-side flip, not an app change.

public struct AppAttestation: Sendable {
  public let keyId: String
  /// Base64 assertion blob (CBOR { signature, authenticatorData }).
  public let assertionB64: String
  /// The server challenge this assertion was bound to.
  public let challenge: String
}

public actor AppAttestClient {
  public static let shared = AppAttestClient()

  private let keyIdDefaultsKey = "septena.attest.keyId"

  public init() {}

  public var isSupported: Bool {
    #if canImport(DeviceCheck)
    return DCAppAttestService.shared.isSupported
    #else
    return false
    #endif
  }

  /// Produce an assertion binding `body` to a fresh server challenge. Returns
  /// nil if App Attest is unavailable or any step fails (caller proceeds
  /// unattested — fine in audit mode).
  public func assertion(forBody body: Data,
                        baseURL: URL,
                        session: URLSession = .shared) async -> AppAttestation? {
    #if canImport(DeviceCheck)
    let service = DCAppAttestService.shared
    guard service.isSupported else { return nil }
    do {
      let keyId = try await registeredKeyID(service: service, baseURL: baseURL, session: session)
      let challenge = try await fetchChallenge(baseURL: baseURL, session: session)
      let clientDataHash = Data(SHA256.hash(data: body + Data(challenge.utf8)))
      let assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
      return AppAttestation(keyId: keyId,
                            assertionB64: assertion.base64EncodedString(),
                            challenge: challenge)
    } catch {
      SeptenaLog.error("AppAttest.assertion", error)
      return nil
    }
    #else
    return nil
    #endif
  }

  #if canImport(DeviceCheck)
  /// The locally-persisted, server-registered key id — generating + attesting
  /// + registering one on first use.
  private func registeredKeyID(service: DCAppAttestService,
                               baseURL: URL,
                               session: URLSession) async throws -> String {
    if let existing = UserDefaults.standard.string(forKey: keyIdDefaultsKey) {
      return existing
    }
    let keyId = try await service.generateKey()
    let challenge = try await fetchChallenge(baseURL: baseURL, session: session)
    let attestation = try await service.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
    try await register(keyId: keyId, attestation: attestation, challenge: challenge,
                       baseURL: baseURL, session: session)
    UserDefaults.standard.set(keyId, forKey: keyIdDefaultsKey)
    return keyId
  }

  private func register(keyId: String, attestation: Data, challenge: String,
                        baseURL: URL, session: URLSession) async throws {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/attest/register"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
      "keyId": keyId,
      "attestation": attestation.base64EncodedString(),
      "challenge": challenge,
    ])
    let (_, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else { throw AttestError.register(code) }
  }

  private func fetchChallenge(baseURL: URL, session: URLSession) async throws -> String {
    var req = URLRequest(url: baseURL.appendingPathComponent("api/attest/challenge"))
    req.httpMethod = "POST"
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let challenge = obj["challenge"] as? String else {
      throw AttestError.challenge(code)
    }
    return challenge
  }

  private enum AttestError: Error { case register(Int), challenge(Int) }
  #endif
}
