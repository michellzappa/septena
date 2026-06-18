import { issueChallenge, verifyAttestation } from "./attest";
import { requireUser } from "./auth";
import type { Env } from "./env";
import { json, notFound, readJson } from "./http";
import { profileResponse, updateProfile } from "./profile";
import { createSupportTicket, getSupportTicket, listSupportTickets, postSupportMessage } from "./support";

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    if (req.method === "POST" && path === "/api/attest/challenge") {
      return json({ challenge: await issueChallenge(env) });
    }

    if (req.method === "POST" && path === "/api/attest/register") {
      const body = await readJson<{ keyId?: string; attestation?: string; challenge?: string }>(req);
      if (body.error) return body.error;
      const b = body.data ?? {};
      if (!b.keyId || !b.attestation || !b.challenge) return json({ error: "missing_fields" }, 400);
      const res = await verifyAttestation(env, {
        keyId: b.keyId,
        attestationB64: b.attestation,
        challenge: b.challenge,
      });
      console.log(`attest.register key=${b.keyId.slice(0, 8)} ok=${res.ok} reason=${res.reason ?? ""}`);
      return res.ok ? json({ ok: true }) : json({ error: res.reason ?? "attestation_failed" }, 400);
    }

    if (req.method === "GET" && path === "/api/me") {
      const auth = await requireUser(env, req, new Uint8Array());
      if (auth.error) return auth.error;
      return json(await profileResponse(env, auth.user!));
    }

    if (req.method === "PATCH" && path === "/api/me/profile") {
      const body = await readJson<unknown>(req);
      if (body.error) return body.error;
      const auth = await requireUser(env, req, body.bytes);
      if (auth.error) return auth.error;
      const result = await updateProfile(env, auth.user!, body.data);
      return result.ok ? json(result.body) : json({ error: result.error }, result.status);
    }

    if (req.method === "GET" && path === "/api/support/tickets") {
      const auth = await requireUser(env, req, new Uint8Array());
      if (auth.error) return auth.error;
      return json(await listSupportTickets(env, auth.user!));
    }

    if (req.method === "POST" && path === "/api/support/tickets") {
      const body = await readJson<unknown>(req);
      if (body.error) return body.error;
      const auth = await requireUser(env, req, body.bytes);
      if (auth.error) return auth.error;
      const result = await createSupportTicket(env, auth.user!, body.data);
      return result.ok ? json(result.body, 201) : json({ error: result.error }, result.status);
    }

    const ticketMatch = path.match(/^\/api\/support\/tickets\/([^/]+)$/);
    if (req.method === "GET" && ticketMatch) {
      const auth = await requireUser(env, req, new Uint8Array());
      if (auth.error) return auth.error;
      const result = await getSupportTicket(env, auth.user!, ticketMatch[1]);
      return result.ok ? json(result.body) : json({ error: result.error }, result.status);
    }

    const messageMatch = path.match(/^\/api\/support\/tickets\/([^/]+)\/messages$/);
    if (req.method === "POST" && messageMatch) {
      const body = await readJson<unknown>(req);
      if (body.error) return body.error;
      const auth = await requireUser(env, req, body.bytes);
      if (auth.error) return auth.error;
      const result = await postSupportMessage(env, auth.user!, messageMatch[1], body.data);
      return result.ok ? json(result.body, 201) : json({ error: result.error }, result.status);
    }

    if (req.method === "GET" && path === "/health") {
      return json({ ok: true, service: "septena-community" });
    }

    return notFound();
  },
};
