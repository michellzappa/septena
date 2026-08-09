import { issueChallenge, rateLimited, verifyAttestation } from "./attest";
import { bindAppleSub, mintSession, verifyAppleIdentityToken } from "./apple";
import { telemetryAdmin } from "./admin";
import { hmacUserHash, requireUser } from "./auth";
import type { Env } from "./env";
import { json, notFound, publicJson, readJson } from "./http";
import { profileResponse, setSupporterTier, updateProfile } from "./profile";
import { createSupportTicket, getSupportTicket, listSupportTickets, postSupportMessage, setTicketStatus } from "./support";
import { addComment, createFeature, getFeature, listFeatures, listPublicFeatures, moderateComment, setVote, updateFeature } from "./features";
import { deleteMyTestimonial, getMyTestimonial, listPublicTestimonials, listTestimonials, moderateTestimonial, putMyTestimonial } from "./testimonials";
import { ingestTelemetry, ingestWeeklyDiagnostics, weeklyDiagnosticsPulse } from "./telemetry";

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    try {
      return await route(req, env);
    } catch (error) {
      const message = String((error as Error)?.message ?? error);
      // A DB CHECK/constraint rejection is a bad request, not a server fault —
      // surface it as 400 instead of a 500 the client can't act on.
      if (/constraint|SQLITE_CONSTRAINT/i.test(message)) {
        return json({ error: "constraint_failed" }, 400);
      }
      console.log(`unhandled error: ${message}`);
      return json({ error: "internal_error" }, 500);
    }
  },
};

async function route(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    // The attest handshake runs before there's a user to key on, so it would
    // otherwise be the one unauthenticated, unthrottled path — and each call
    // does a KV write. Cap it per-IP so it can't be used to burn KV quota.
    if (path === "/api/attest/challenge" || path === "/api/attest/register") {
      const ip = req.headers.get("CF-Connecting-IP") ?? "unknown";
      if (await rateLimited(env, `attest:${ip}`, 60, 60)) {
        return json({ error: "rate_limited" }, 429);
      }
    }

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

    if (req.method === "POST" && path === "/api/telemetry") {
      return ingestTelemetry(env, req);
    }

    if (req.method === "POST" && path === "/api/telemetry/weekly") {
      return ingestWeeklyDiagnostics(env, req);
    }

    if (req.method === "OPTIONS" && path === "/api/public/telemetry") {
      return publicJson({ ok: true });
    }
    if (req.method === "GET" && path === "/api/public/telemetry") {
      return weeklyDiagnosticsPulse(env);
    }

    // Sign in with Apple → a worker session token. The App-Attest substitute
    // for devices without App Attest (native macOS). Verify the Apple identity
    // token once, bind the Apple sub to this CloudKit identity, mint a
    // long-lived session the app replays via X-Septena-Session. See apple.ts.
    if (req.method === "POST" && path === "/api/auth/apple") {
      const ip = req.headers.get("CF-Connecting-IP") ?? "unknown";
      if (await rateLimited(env, `apple:${ip}`, 30, 60)) {
        return json({ error: "rate_limited" }, 429);
      }
      const body = await readJson<{ identityToken?: string }>(req);
      if (body.error) return body.error;
      const identityToken = body.data?.identityToken?.trim() ?? "";
      if (!identityToken) return json({ error: "missing_identity_token" }, 400);
      const cloudKitUserID = req.headers.get("X-Septena-CloudKit-User")?.trim() ?? "";
      if (!cloudKitUserID) return json({ error: "missing_cloudkit_user" }, 400);

      const verified = await verifyAppleIdentityToken(env, identityToken);
      if (!verified.ok) {
        console.log(`apple.verify failed reason=${verified.reason ?? ""}`);
        return json({ error: `apple_${verified.reason ?? "invalid"}` }, 401);
      }
      const userHash = await hmacUserHash(env, cloudKitUserID);
      const bind = await bindAppleSub(env, verified.sub!, userHash);
      if (!bind.ok) return json({ error: "identity_mismatch" }, 403);

      const session = await mintSession(env, userHash, verified.sub!);
      return json({ sessionToken: session.token, expiresAt: session.expiresAt });
    }

    if (req.method === "GET" && path === "/admin/telemetry") {
      return telemetryAdmin(req, env);
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

    // Patronage badge. The app reports its current StoreKit support tier here so
    // the member's profile can show a "Supporter" badge. Client-asserted over
    // the attested/session channel (the badge gates nothing).
    if (req.method === "PUT" && path === "/api/me/support") {
      const body = await readJson<unknown>(req);
      if (body.error) return body.error;
      const auth = await requireUser(env, req, body.bytes);
      if (auth.error) return auth.error;
      const result = await setSupporterTier(env, auth.user!, body.data);
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

    // Maintainer-only: change ticket status (close / reopen).
    if (req.method === "PATCH" && ticketMatch) {
      const body = await readJson<unknown>(req);
      if (body.error) return body.error;
      const auth = await requireUser(env, req, body.bytes);
      if (auth.error) return auth.error;
      const result = await setTicketStatus(env, auth.user!, ticketMatch[1], body.data);
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

    // Public, read-only roadmap for the website — no auth, edge-cached. Mirrors
    // the moderated feature board (votes + counts, no per-user state, no comments).
    if (req.method === "OPTIONS" && path === "/api/public/features") {
      return publicJson({ ok: true });
    }
    if (req.method === "GET" && path === "/api/public/features") {
      return publicJson(await listPublicFeatures(env));
    }

    if (req.method === "GET" && path === "/api/features") {
      const auth = await requireUser(env, req, new Uint8Array());
      if (auth.error) return auth.error;
      return json(await listFeatures(env, auth.user!));
    }

    if (req.method === "POST" && path === "/api/features") {
      const body = await readJson<unknown>(req);
      if (body.error) return body.error;
      const auth = await requireUser(env, req, body.bytes);
      if (auth.error) return auth.error;
      const result = await createFeature(env, auth.user!, body.data);
      return result.ok ? json(result.body, 201) : json({ error: result.error }, result.status);
    }

    const voteMatch = path.match(/^\/api\/features\/([^/]+)\/vote$/);
    if ((req.method === "POST" || req.method === "DELETE") && voteMatch) {
      const auth = await requireUser(env, req, new Uint8Array());
      if (auth.error) return auth.error;
      const result = await setVote(env, auth.user!, voteMatch[1], req.method === "POST");
      return result.ok ? json(result.body) : json({ error: result.error }, result.status);
    }

    const featureCommentMatch = path.match(/^\/api\/features\/([^/]+)\/comments$/);
    if (req.method === "POST" && featureCommentMatch) {
      const body = await readJson<unknown>(req);
      if (body.error) return body.error;
      const auth = await requireUser(env, req, body.bytes);
      if (auth.error) return auth.error;
      const result = await addComment(env, auth.user!, featureCommentMatch[1], body.data);
      return result.ok ? json(result.body, 201) : json({ error: result.error }, result.status);
    }

    // Maintainer-only: hide / unhide / delete / pin a comment.
    const commentModMatch = path.match(/^\/api\/features\/([^/]+)\/comments\/([^/]+)$/);
    if (req.method === "PATCH" && commentModMatch) {
      const body = await readJson<unknown>(req);
      if (body.error) return body.error;
      const auth = await requireUser(env, req, body.bytes);
      if (auth.error) return auth.error;
      const result = await moderateComment(env, auth.user!, commentModMatch[1], commentModMatch[2], body.data);
      return result.ok ? json(result.body) : json({ error: result.error }, result.status);
    }

    const featureMatch = path.match(/^\/api\/features\/([^/]+)$/);
    if (req.method === "GET" && featureMatch) {
      const auth = await requireUser(env, req, new Uint8Array());
      if (auth.error) return auth.error;
      const result = await getFeature(env, auth.user!, featureMatch[1]);
      return result.ok ? json(result.body) : json({ error: result.error }, result.status);
    }

    if (req.method === "PATCH" && featureMatch) {
      const body = await readJson<unknown>(req);
      if (body.error) return body.error;
      const auth = await requireUser(env, req, body.bytes);
      if (auth.error) return auth.error;
      const result = await updateFeature(env, auth.user!, featureMatch[1], body.data);
      return result.ok ? json(result.body) : json({ error: result.error }, result.status);
    }

    // Testimonials — one per user, maintainer-approved before public.
    if (req.method === "OPTIONS" && path === "/api/public/testimonials") {
      return publicJson({ ok: true });
    }
    if (req.method === "GET" && path === "/api/public/testimonials") {
      return publicJson(await listPublicTestimonials(env));
    }

    if (req.method === "GET" && path === "/api/me/testimonial") {
      const auth = await requireUser(env, req, new Uint8Array());
      if (auth.error) return auth.error;
      return json(await getMyTestimonial(env, auth.user!));
    }

    if (req.method === "PUT" && path === "/api/me/testimonial") {
      const body = await readJson<unknown>(req);
      if (body.error) return body.error;
      const auth = await requireUser(env, req, body.bytes);
      if (auth.error) return auth.error;
      const result = await putMyTestimonial(env, auth.user!, body.data);
      return result.ok ? json(result.body) : json({ error: result.error }, result.status);
    }

    if (req.method === "DELETE" && path === "/api/me/testimonial") {
      const auth = await requireUser(env, req, new Uint8Array());
      if (auth.error) return auth.error;
      return json(await deleteMyTestimonial(env, auth.user!));
    }

    if (req.method === "GET" && path === "/api/testimonials") {
      const auth = await requireUser(env, req, new Uint8Array());
      if (auth.error) return auth.error;
      return json(await listTestimonials(env, auth.user!));
    }

    const testimonialModMatch = path.match(/^\/api\/testimonials\/([^/]+)$/);
    if (req.method === "PATCH" && testimonialModMatch) {
      const body = await readJson<unknown>(req);
      if (body.error) return body.error;
      const auth = await requireUser(env, req, body.bytes);
      if (auth.error) return auth.error;
      const result = await moderateTestimonial(env, auth.user!, testimonialModMatch[1], body.data);
      return result.ok ? json(result.body) : json({ error: result.error }, result.status);
    }

    if (req.method === "GET" && path === "/health") {
      return json({ ok: true, service: "septena-community" });
    }

    return notFound();
}
