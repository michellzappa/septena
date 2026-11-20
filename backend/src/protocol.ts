// MCP protocol-revision plumbing: era detection, version negotiation, and the
// per-request header contract introduced by revision 2026-07-28.
//
// Revision 2026-07-28 made MCP stateless: no `initialize` handshake, no
// `Mcp-Session-Id`, no GET stream. Every request instead carries its protocol
// version, client identity, and capabilities in `params._meta`, mirrored into
// HTTP headers the server must validate.
//
// This gateway is DUAL-ERA, which the spec explicitly sanctions ("A dual-era
// server MAY serve both eras concurrently on the same endpoint"). It serves:
//   • modern clients — statelessly, per this revision.
//   • legacy clients — the `initialize` / `notifications/initialized`
//     handshake of 2025-11-25 and earlier.
// Dropping the legacy path is NOT an option yet: Claude's connector has not
// shipped modern support, so a modern-only gateway would take the live
// connector offline. The era is chosen per request, from how the client opens.
//
// MIRROR: ../septena-cloud/SeptenaCore/MCP/MCPRevision.swift — the constants
// and era rules are duplicated there for the in-app server. Keep them
// identical or the two surfaces diverge.

/// The revision this server implements natively.
export const MODERN_VERSION = "2026-07-28";

/// Every revision we will serve, newest first. Legacy entries are honest: this
/// is a tools-only server, and the tools/list + tools/call contract is
/// unchanged across all of them, so a client pinned to any of these works.
/// Returned verbatim in `DiscoverResult.supportedVersions` and in the
/// `supported` list of an UnsupportedProtocolVersionError.
export const SUPPORTED_VERSIONS = [
  MODERN_VERSION,
  "2025-11-25",
  "2025-06-18",
  "2025-03-26",
  "2024-11-05",
] as const;

/// What we answer a legacy `initialize` with when the client asks for a
/// version we do not serve. Legacy clients have no fall-forward mechanism, so
/// naming a version we DO support is the only useful reply.
export const LEGACY_FALLBACK_VERSION = "2024-11-05";

// `_meta` keys defined by the spec. The `io.modelcontextprotocol/` prefix is
// reserved for the protocol itself; never invent keys under it.
export const META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion";
export const META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo";
export const META_CLIENT_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities";
export const META_SERVER_INFO = "io.modelcontextprotocol/serverInfo";

// Error codes from the MCP-reserved sub-range (-32020..-32099). NOT the
// implementation-defined range (-32000..-32019) — these numbers are fixed by
// the spec and clients switch on them.
export const ERR_HEADER_MISMATCH = -32020;
export const ERR_UNSUPPORTED_PROTOCOL_VERSION = -32022;

/// How long a client may cache `tools/list`. Section enablement changes rarely
/// (a Settings toggle), so minutes are safe and cut repeat polling.
export const TOOLS_LIST_TTL_MS = 5 * 60 * 1000;

/// `server/discover` is pure server identity — no user data in it, same answer
/// for every caller — so it caches long and publicly.
export const DISCOVER_TTL_MS = 60 * 60 * 1000;

export type Era = "modern" | "legacy";

export interface JsonRpcMeta {
  [key: string]: unknown;
}

/// Read `params._meta` without assuming any particular params shape.
export function readMeta(params: unknown): JsonRpcMeta | undefined {
  if (!params || typeof params !== "object") return undefined;
  const meta = (params as { _meta?: unknown })._meta;
  return meta && typeof meta === "object" ? (meta as JsonRpcMeta) : undefined;
}

/// The protocol version a modern request declares in `_meta`, if any.
export function metaProtocolVersion(params: unknown): string | undefined {
  const v = readMeta(params)?.[META_PROTOCOL_VERSION];
  return typeof v === "string" ? v : undefined;
}

/// Which era a request belongs to.
///
/// The spec's rule for a dual-era server is "select behavior from how the
/// client opens": a request carrying modern per-request `_meta` is modern; an
/// `initialize` request is legacy. `server/discover` exists only in the modern
/// revision, so it is always modern regardless of what else it carries.
export function detectEra(method: string, params: unknown, protocolHeader?: string): Era {
  if (method === "server/discover") return "modern";
  if (method === "initialize") return "legacy";
  if (metaProtocolVersion(params) !== undefined) return "modern";
  // The header alone is enough: 2025-06-18 also defined MCP-Protocol-Version,
  // so only a value we recognise as the modern revision flips the era.
  if (protocolHeader === MODERN_VERSION) return "modern";
  return "legacy";
}

export function isSupportedVersion(v: string): boolean {
  return (SUPPORTED_VERSIONS as readonly string[]).includes(v);
}

/// Pick the version to echo in a legacy `initialize` result. Previously we
/// echoed whatever string the client sent, including versions we do not
/// implement — that is a false claim of support, and it is what the modern
/// UnsupportedProtocolVersionError exists to replace.
export function negotiateLegacyVersion(requested: unknown): string {
  return typeof requested === "string" && isSupportedVersion(requested)
    ? requested
    : LEGACY_FALLBACK_VERSION;
}

/// Decode the Base64 sentinel form (`=?base64?...?=`) clients must use for
/// header values that are not plain ASCII. Servers MUST decode before
/// comparing a header to its body value.
export function decodeHeaderValue(raw: string): string {
  if (!raw.startsWith("=?base64?") || !raw.endsWith("?=")) return raw;
  const encoded = raw.slice("=?base64?".length, -"?=".length);
  try {
    // atob gives latin-1 bytes; reinterpret them as the UTF-8 the client sent.
    const bytes = Uint8Array.from(atob(encoded), ch => ch.charCodeAt(0));
    return new TextDecoder().decode(bytes);
  } catch {
    // Undecodable → return as-is so the comparison below fails loudly with a
    // HeaderMismatch rather than silently accepting a malformed value.
    return raw;
  }
}

/// Validate the standard request headers a modern Streamable HTTP POST must
/// carry, per "Server Validation". Returns a human-readable reason on failure,
/// or null when the request is well-formed.
///
/// Only ever applied to MODERN requests: legacy clients (including today's
/// Claude connector and every `claude mcp add` registration) never send these
/// headers, and rejecting them would break every existing caller.
export function validateModernHeaders(
  header: (name: string) => string | undefined,
  method: string,
  params: unknown,
): string | null {
  const declared = metaProtocolVersion(params);
  const versionHeader = header("MCP-Protocol-Version");
  if (!versionHeader) return "missing MCP-Protocol-Version header";
  if (declared !== undefined && versionHeader !== declared) {
    return `MCP-Protocol-Version header '${versionHeader}' does not match body _meta '${declared}'`;
  }

  const methodHeader = header("Mcp-Method");
  if (!methodHeader) return "missing Mcp-Method header";
  if (methodHeader !== method) {
    return `Mcp-Method header '${methodHeader}' does not match body method '${method}'`;
  }

  // Mcp-Name is required only for the name/uri-addressed methods. Of those,
  // this server implements tools/call alone.
  if (method === "tools/call") {
    const bodyName = (params as { name?: unknown } | undefined)?.name;
    const nameHeader = header("Mcp-Name");
    if (!nameHeader) return "missing Mcp-Name header";
    if (typeof bodyName === "string" && decodeHeaderValue(nameHeader) !== bodyName) {
      return `Mcp-Name header '${nameHeader}' does not match body name '${bodyName}'`;
    }
  }

  return null;
}

/// Add the fields every modern result must carry. Legacy results are returned
/// untouched: a 2024-11-05 client has no schema slot for `resultType`, and the
/// spec tells modern clients to read a missing `resultType` as "complete"
/// anyway, so there is nothing to gain by emitting it to legacy callers.
///
/// Deliberate asymmetry: the `ttlMs`/`cacheScope` hints on `tools/list` ARE
/// emitted to both eras. They are advisory caching metadata that is equally
/// true whoever asks, whereas `resultType` carries revision-specific protocol
/// semantics (complete vs. input_required). Don't "unify" these.
export function decorateResult(
  result: Record<string, unknown>,
  era: Era,
  serverInfo: { name: string; version: string },
): Record<string, unknown> {
  if (era !== "modern") return result;
  const meta = (result._meta as JsonRpcMeta | undefined) ?? {};
  return {
    resultType: "complete",
    ...result,
    _meta: { ...meta, [META_SERVER_INFO]: serverInfo },
  };
}
