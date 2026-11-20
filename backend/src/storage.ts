import type { Env } from "./env.js";

// KV-backed OAuth client registrations (RFC 7591 dynamic client
// registration) for the api.septena.app connector.

export interface ClientRecord {
  clientId: string;
  redirectUris: string[];
  name?: string;
  createdAt: number;
}

// `keyPrefix` keeps each authorization server's registrations apart: the live
// connector uses the default `client:`, the api.septena.app preview `v2:client:`
// (src/shadow/), so a client registered with one is unknown to the other.
export async function putClient(env: Env, c: ClientRecord, keyPrefix = "client:"): Promise<void> {
  await env.CLIENTS.put(`${keyPrefix}${c.clientId}`, JSON.stringify(c));
}

export async function getClient(env: Env, clientId: string, keyPrefix = "client:"): Promise<ClientRecord | null> {
  const raw = await env.CLIENTS.get(`${keyPrefix}${clientId}`);
  return raw ? (JSON.parse(raw) as ClientRecord) : null;
}
