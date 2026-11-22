// Redirect-URI policy, shared by /oauth/register (at registration time)
// and /oauth/authorize (defense in depth — also rejects clients that were
// registered before this validation existed).
//
// This gateway fronts one person's health data, so client origins are
// PINNED: only Claude's and ChatGPT's hosted callbacks and loopback (local MCP clients
// like Claude Code, which listen on a random localhost port) may receive
// auth codes. Add a host here before pointing any new MCP client at the
// gateway.

const PINNED_REDIRECT_HOSTS = new Set([
  "claude.ai",   // https://claude.ai/api/mcp/auth_callback
  "claude.com",  // https://claude.com/api/mcp/auth_callback
  "chatgpt.com", // https://chatgpt.com/connector_platform_oauth_redirect
]);

const MAX_REDIRECT_URI_LENGTH = 512;

function isLoopback(hostname: string): boolean {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]";
}

/// Returns null when the URI is acceptable, else a human-readable reason.
export function validateRedirectUri(uri: string): string | null {
  if (uri.length > MAX_REDIRECT_URI_LENGTH) return "redirect_uri too long";
  let u: URL;
  try {
    u = new URL(uri);
  } catch {
    return "redirect_uri must be an absolute URL";
  }
  if (u.hash) return "redirect_uri must not contain a fragment";
  if (u.username || u.password) return "redirect_uri must not contain credentials";
  const loopback = isLoopback(u.hostname);
  if (u.protocol === "http:") {
    if (!loopback) return "http redirect_uri is only allowed on localhost";
  } else if (u.protocol !== "https:") {
    return "redirect_uri must use https";
  }
  if (!loopback && !PINNED_REDIRECT_HOSTS.has(u.hostname)) {
    return `redirect_uri host "${u.hostname}" is not a known MCP client`;
  }
  return null;
}
