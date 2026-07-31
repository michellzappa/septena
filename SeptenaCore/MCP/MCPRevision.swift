import Foundation

// MCP protocol-revision plumbing: era detection, version negotiation, and the
// per-request header contract introduced by revision 2026-07-28.
//
// Revision 2026-07-28 made MCP stateless: no `initialize` handshake, no
// `Mcp-Session-Id`, no GET stream. Every request instead carries its protocol
// version, client identity, and capabilities in `params._meta`, mirrored into
// HTTP headers the server must validate.
//
// This server is DUAL-ERA, which the spec explicitly sanctions ("A dual-era
// server MAY serve both eras concurrently on the same endpoint"). It serves:
//   • modern clients — statelessly, per this revision.
//   • legacy clients — the `initialize` / `notifications/initialized`
//     handshake of 2025-11-25 and earlier.
// Dropping the legacy path is NOT an option yet: every existing
// `claude mcp add --transport http septena-local …` registration speaks it, so
// a modern-only server would break the Macs it is already installed on. The
// era is chosen per request, from how the client opens.
//
// MIRROR: ../septena-mcp-gateway/src/protocol.ts — the constants and era rules
// are duplicated there for the hosted gateway. Keep them identical or the two
// surfaces diverge.

enum MCPRevision {

  /// The revision this server implements natively.
  static let modernVersion = "2026-07-28"

  /// Every revision we will serve, newest first. Legacy entries are honest:
  /// this is a tools-only server, and the tools/list + tools/call contract is
  /// unchanged across all of them, so a client pinned to any of these works.
  /// Returned verbatim in `DiscoverResult.supportedVersions` and in the
  /// `supported` list of an UnsupportedProtocolVersionError.
  static let supportedVersions = [
    modernVersion,
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
  ]

  /// What we answer a legacy `initialize` with when the client asks for a
  /// version we do not serve. Legacy clients have no fall-forward mechanism,
  /// so naming a version we DO support is the only useful reply.
  static let legacyFallbackVersion = "2024-11-05"

  // `_meta` keys defined by the spec. The `io.modelcontextprotocol/` prefix is
  // reserved for the protocol itself; never invent keys under it.
  static let metaProtocolVersionKey = "io.modelcontextprotocol/protocolVersion"
  static let metaClientInfoKey = "io.modelcontextprotocol/clientInfo"
  static let metaClientCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
  static let metaServerInfoKey = "io.modelcontextprotocol/serverInfo"

  // Error codes from the MCP-reserved sub-range (-32020...-32099). NOT the
  // implementation-defined range (-32000...-32019) — these numbers are fixed
  // by the spec and clients switch on them.
  static let errHeaderMismatch = -32020
  static let errUnsupportedProtocolVersion = -32022

  /// How long a client may cache `tools/list`. Section enablement changes
  /// rarely (a Settings toggle), so minutes are safe and cut repeat polling.
  static let toolsListTTLms = 5 * 60 * 1000

  /// `server/discover` is pure server identity — no user data in it, same
  /// answer for every caller — so it caches long and publicly.
  static let discoverTTLms = 60 * 60 * 1000

  enum Era { case modern, legacy }

  // MARK: - Request inspection

  /// The protocol version a modern request declares in `params._meta`, if any.
  static func metaProtocolVersion(_ params: [String: Any]?) -> String? {
    guard let meta = params?["_meta"] as? [String: Any] else { return nil }
    return meta[metaProtocolVersionKey] as? String
  }

  /// Which era a request belongs to.
  ///
  /// The spec's rule for a dual-era server is "select behavior from how the
  /// client opens": a request carrying modern per-request `_meta` is modern;
  /// an `initialize` request is legacy. `server/discover` exists only in the
  /// modern revision, so it is always modern regardless of what else it
  /// carries.
  static func detectEra(method: String, params: [String: Any]?, protocolHeader: String?) -> Era {
    if method == "server/discover" { return .modern }
    if method == "initialize" { return .legacy }
    if metaProtocolVersion(params) != nil { return .modern }
    // The header alone is enough: 2025-06-18 also defined
    // MCP-Protocol-Version, so only a value we recognise as the modern
    // revision flips the era.
    if protocolHeader == modernVersion { return .modern }
    return .legacy
  }

  static func isSupportedVersion(_ v: String) -> Bool {
    supportedVersions.contains(v)
  }

  /// Pick the version to echo in a legacy `initialize` result. Previously we
  /// echoed whatever string the client sent, including versions we do not
  /// implement — that is a false claim of support, and it is what the modern
  /// UnsupportedProtocolVersionError exists to replace.
  static func negotiateLegacyVersion(_ requested: Any?) -> String {
    guard let s = requested as? String, isSupportedVersion(s) else {
      return legacyFallbackVersion
    }
    return s
  }

  // MARK: - Header contract

  /// Decode the Base64 sentinel form (`=?base64?...?=`) clients must use for
  /// header values that are not plain ASCII. Servers MUST decode before
  /// comparing a header to its body value.
  static func decodeHeaderValue(_ raw: String) -> String {
    let prefix = "=?base64?"
    let suffix = "?="
    guard raw.hasPrefix(prefix), raw.hasSuffix(suffix), raw.count > prefix.count + suffix.count
    else { return raw }
    let encoded = String(raw.dropFirst(prefix.count).dropLast(suffix.count))
    guard let data = Data(base64Encoded: encoded),
          let decoded = String(data: data, encoding: .utf8)
    else {
      // Undecodable → return as-is so the comparison below fails loudly with a
      // HeaderMismatch rather than silently accepting a malformed value.
      return raw
    }
    return decoded
  }

  /// Validate the standard request headers a modern Streamable HTTP POST must
  /// carry, per "Server Validation". Returns a human-readable reason on
  /// failure, or nil when the request is well-formed.
  ///
  /// Only ever applied to MODERN requests: legacy clients (including every
  /// existing `claude mcp add` registration) never send these headers, and
  /// rejecting them would break every caller we have today.
  static func validateModernHeaders(
    header: (String) -> String?,
    method: String,
    params: [String: Any]?
  ) -> String? {
    let declared = metaProtocolVersion(params)
    guard let versionHeader = header("MCP-Protocol-Version") else {
      return "missing MCP-Protocol-Version header"
    }
    if let declared, versionHeader != declared {
      return "MCP-Protocol-Version header '\(versionHeader)' does not match body _meta '\(declared)'"
    }

    guard let methodHeader = header("Mcp-Method") else { return "missing Mcp-Method header" }
    if methodHeader != method {
      return "Mcp-Method header '\(methodHeader)' does not match body method '\(method)'"
    }

    // Mcp-Name is required only for the name/uri-addressed methods. Of those,
    // this server implements tools/call alone.
    if method == "tools/call" {
      guard let nameHeader = header("Mcp-Name") else { return "missing Mcp-Name header" }
      if let bodyName = params?["name"] as? String,
         decodeHeaderValue(nameHeader) != bodyName {
        return "Mcp-Name header '\(nameHeader)' does not match body name '\(bodyName)'"
      }
    }

    return nil
  }

  // MARK: - Result shaping

  /// Add the fields every modern result must carry. Legacy results are
  /// returned untouched: a 2024-11-05 client has no schema slot for
  /// `resultType`, and the spec tells modern clients to read a missing
  /// `resultType` as "complete" anyway, so there is nothing to gain by
  /// emitting it to legacy callers.
  ///
  /// Deliberate asymmetry: the `ttlMs`/`cacheScope` hints on `tools/list` ARE
  /// emitted to both eras. They are advisory caching metadata that is equally
  /// true whoever asks, whereas `resultType` carries revision-specific
  /// protocol semantics (complete vs. input_required). Don't "unify" these.
  static func decorate(
    _ result: [String: Any],
    era: Era,
    serverInfo: [String: Any]
  ) -> [String: Any] {
    guard era == .modern else { return result }
    var out = result
    out["resultType"] = "complete"
    var meta = (result["_meta"] as? [String: Any]) ?? [:]
    meta[metaServerInfoKey] = serverInfo
    out["_meta"] = meta
    return out
  }
}

/// One dispatched JSON-RPC response plus the HTTP status it must be sent with.
///
/// The status is load-bearing under the modern transport, not cosmetic: a
/// dual-era CLIENT distinguishes a modern server from a legacy one by
/// inspecting the status (400 for version/header failures, 404 for an unknown
/// method) alongside the body. `body == nil` means "notification — 202, no
/// body".
struct MCPHTTPResponse {
  let status: Int
  let body: [String: Any]?

  static func ok(_ body: [String: Any]) -> MCPHTTPResponse { .init(status: 200, body: body) }
  static let accepted = MCPHTTPResponse(status: 202, body: nil)

  /// The HTTP/1.1 status line the local server writes.
  var statusLine: String {
    switch status {
    case 200: return "200 OK"
    case 202: return "202 Accepted"
    case 400: return "400 Bad Request"
    case 403: return "403 Forbidden"
    case 404: return "404 Not Found"
    case 405: return "405 Method Not Allowed"
    default:  return "\(status) Status"
    }
  }
}
