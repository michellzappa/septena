import type { Context } from "hono";
import pkg from "../package.json";
import type { Env } from "./env.js";
import { logEvent } from "./util.js";
import {
  type Era,
  SUPPORTED_VERSIONS,
  DISCOVER_TTL_MS,
  ERR_HEADER_MISMATCH,
  ERR_UNSUPPORTED_PROTOCOL_VERSION,
  decorateResult,
  detectEra,
  isSupportedVersion,
  metaProtocolVersion,
  negotiateLegacyVersion,
  validateModernHeaders,
} from "./protocol.js";

// The MCP JSON-RPC envelope, shared by every MCP endpoint this Worker serves:
// the live CloudKit connector (src/mcp.ts, mcp.septena.app) and the read-only
// task-backend preview (src/shadow/mcp.ts, api.septena.app). One copy of the
// dual-era rules (src/protocol.ts) and the envelope around them, so the two
// endpoints cannot drift on protocol behavior. Data sources and tool sets stay
// in the endpoint modules.

// Single source of truth for the server version — the MCP `serverInfo.version`
// must always match package.json so a deployed Worker maps to a tagged release.
const SERVER_VERSION = pkg.version;

/// Identity reported in `serverInfo`, on both eras.
export const SERVER_INFO = { name: "septena-mcp-gateway", version: SERVER_VERSION };

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number | string | null;
  method: string;
  params?: Record<string, unknown>;
}

export interface ToolAnnotations {
  title: string;
  readOnlyHint: boolean;
  destructiveHint: boolean;
  idempotentHint: boolean;
  openWorldHint: boolean;
}

export type Tool = {
  name: string;
  title: string;
  description: string;
  inputSchema: unknown;
  annotations: ToolAnnotations;
};

/// The live connector's protected-resource document. Default for
/// `unauthorized()` so the live 401 stays byte-identical.
export const LIVE_RESOURCE_METADATA = "https://mcp.septena.app/.well-known/oauth-protected-resource";

/// Parse the JSON-RPC body and run the per-request protocol checks: reply 202
/// to notifications, pick the era, and for modern requests validate the
/// header/body agreement and the declared version. Returns a finished
/// Response when the request ends here, else the request and its era.
export async function readRpcRequest(
  c: Context<{ Bindings: Env }>,
): Promise<Response | { req: JsonRpcRequest; era: Era }> {
  const req = (await c.req.json().catch(() => null)) as JsonRpcRequest | null;
  if (!req || req.jsonrpc !== "2.0" || !req.method) {
    return rpcError(req?.id ?? null, -32600, "Invalid Request");
  }

  // JSON-RPC notifications carry no id; per spec the server must not reply.
  // MCP clients send notifications/initialized after the handshake — answer
  // with a bare 202 instead of a "Method not found" error.
  if (req.id === undefined || req.id === null || req.method.startsWith("notifications/")) {
    return new Response(null, { status: 202 });
  }

  // --- Protocol era (see src/protocol.ts) ---------------------------------
  // Modern (2026-07-28) requests declare their version per-request and are
  // served statelessly; legacy clients keep the `initialize` handshake. A
  // request never changes era mid-flight, so this is decided once, here.
  const era: Era = detectEra(req.method, req.params, c.req.header("MCP-Protocol-Version"));

  if (era === "modern") {
    // Header/body agreement is a MUST: an intermediary may route on the
    // header while we execute the body, so a mismatch is a security bug, not
    // a nicety. Legacy callers never send these and are never checked.
    const reason = validateModernHeaders(name => c.req.header(name), req.method, req.params);
    if (reason) {
      logEvent("header_mismatch", { method: req.method, reason });
      return rpcError(req.id, ERR_HEADER_MISMATCH, `Header mismatch: ${reason}`, era, 400);
    }

    // Version support is now answered honestly. We used to echo whatever
    // version string the client sent, which claimed support for revisions we
    // do not implement; the modern reply is an explicit error naming what we
    // actually serve so the client can retry on a mutually supported one.
    const declared = metaProtocolVersion(req.params) ?? c.req.header("MCP-Protocol-Version");
    if (declared !== undefined && !isSupportedVersion(declared)) {
      return rpcError(
        req.id,
        ERR_UNSUPPORTED_PROTOCOL_VERSION,
        "Unsupported protocol version",
        era,
        400,
        { supported: SUPPORTED_VERSIONS, requested: declared },
      );
    }
  }

  return { req, era };
}

/// Answer the protocol-level methods that carry no user data:
/// `server/discover`, `initialize` and `ping`. Returns null for any other
/// method, which the endpoint then dispatches itself.
///
/// `initializeInstructions` is optional on purpose: the live connector's
/// legacy `initialize` result has never carried instructions, and leaving the
/// option unset keeps that reply byte-identical.
export function answerProtocolMethod(
  req: JsonRpcRequest,
  era: Era,
  opts: { instructions: string; initializeInstructions?: string },
): Response | null {
  switch (req.method) {
    case "server/discover":
      // MUST be implemented by every modern server. Pure identity — no
      // data-source call, no user data — so it is the same for every caller
      // and caches publicly.
      return rpcResult(
        req.id,
        {
          supportedVersions: SUPPORTED_VERSIONS,
          capabilities: { tools: {} },
          instructions: opts.instructions,
          ttlMs: DISCOVER_TTL_MS,
          cacheScope: "public",
        },
        era,
      );
    case "initialize": {
      // Legacy handshake. Retained deliberately: Claude's connector has not
      // shipped 2026-07-28 support, so removing this takes the live
      // connector offline. Answer with a version we genuinely serve rather
      // than echoing the client's request blindly.
      const requested = (req.params as { protocolVersion?: unknown } | undefined)?.protocolVersion;
      const result: Record<string, unknown> = {
        protocolVersion: negotiateLegacyVersion(requested),
        capabilities: { tools: {} },
        serverInfo: SERVER_INFO,
      };
      if (opts.initializeInstructions !== undefined) result.instructions = opts.initializeInstructions;
      return rpcResult(req.id, result, era);
    }
    case "ping":
      // Removed in 2026-07-28, kept for legacy clients that health-probe
      // with it. Must be a fast empty result that never touches a data
      // source, or clients judge the connector unhealthy.
      return rpcResult(req.id, {}, era);
    default:
      return null;
  }
}

/// Unknown JSON-RPC method. Modern transport pins it to HTTP 404 (with the
/// JSON-RPC body distinguishing us from a legacy server that simply doesn't
/// host this endpoint). Legacy clients keep the 200 they expect.
export function methodNotFound(req: JsonRpcRequest, era: Era): Response {
  return rpcError(
    req.id,
    -32601,
    `Method not found: ${req.method}`,
    era,
    era === "modern" ? 404 : 200,
  );
}

/// Success envelope. Modern results additionally carry `resultType` and the
/// server's identity in `_meta`; legacy results are byte-identical to what
/// this gateway has always emitted.
export function rpcResult(
  id: JsonRpcRequest["id"],
  result: Record<string, unknown>,
  era: Era = "legacy",
): Response {
  return Response.json({
    jsonrpc: "2.0",
    id,
    result: decorateResult(result, era, SERVER_INFO),
  });
}

/// Error envelope. `status` exists because the modern transport maps certain
/// protocol errors onto HTTP status codes (400 for version/header failures,
/// 404 for an unknown method) — that status is how a dual-era CLIENT tells a
/// modern server from a legacy one, so it is load-bearing, not cosmetic.
export function rpcError(
  id: JsonRpcRequest["id"],
  code: number,
  message: string,
  era: Era = "legacy",
  status = 200,
  data?: unknown,
): Response {
  const error = data === undefined ? { code, message } : { code, message, data };
  return Response.json({ jsonrpc: "2.0", id, error }, { status: era === "modern" ? status : 200 });
}

export function unauthorized(reason?: string, resourceMetadata = LIVE_RESOURCE_METADATA): Response {
  // RFC 9728 / MCP 2025-06: the `resource_metadata` parameter points clients
  // at the endpoint's /.well-known/oauth-protected-resource doc, from which
  // they learn the authorization server. Without it, Claude's MCP client
  // cannot discover where to re-run OAuth on a 401 and falls back to "user
  // must reconnect manually" — the daily-disconnect symptom we fixed.
  const params = [
    'Bearer realm="septena-mcp"',
    'error="invalid_token"',
    `resource_metadata="${resourceMetadata}"`,
  ];
  if (reason) logEvent("unauthorized", { reason });
  return new Response("Unauthorized", {
    status: 401,
    headers: { "WWW-Authenticate": params.join(", ") },
  });
}
