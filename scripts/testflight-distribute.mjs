#!/usr/bin/env node
// testflight-distribute.mjs: hand one uploaded iOS build to the external
// TestFlight group that owns the public link, and send it to beta review.
//
// Runs in .github/workflows/testflight-ios.yml after the upload job, on
// Linux, with no dependencies (Node's own crypto signs the ES256 token).
//
// Steps:
//   1. Wait until App Store Connect has processed the build (state VALID).
//   2. Add the "What to Test" text when the build has none.
//   3. Add the build to the group named by TESTFLIGHT_GROUP.
//   4. Submit the build for beta review. Apple allows one build in review
//      at a time, so a refusal here is a notice, not a failure: the build
//      stays in the group and goes to testers with the next approval.
//
// Env: APPLE_API_KEY (.p8 contents), APPLE_API_KEY_ID, APPLE_API_ISSUER_ID,
//      ASC_APP_ID, BUILD_NUMBER, TESTFLIGHT_GROUP (default "Public beta").

import { createPrivateKey, sign } from "node:crypto";

const env = (name, fallback) => {
  const v = process.env[name] ?? fallback;
  if (!v) throw new Error(`${name} is not set`);
  return v;
};

const KEY = createPrivateKey(env("APPLE_API_KEY"));
const KEY_ID = env("APPLE_API_KEY_ID");
const ISSUER = env("APPLE_API_ISSUER_ID");
const APP_ID = env("ASC_APP_ID");
const BUILD_NUMBER = env("BUILD_NUMBER");
const GROUP_NAME = env("TESTFLIGHT_GROUP", "Public beta");

// Tester-facing copy. It went through the humanizer skill on 2026-11-23.
// Change it here only, and run the humanizer again when you do.
const WHAT_TO_TEST =
  "Add a few tasks to Today and to a project. Give one a date, then open the app " +
  "on a second device and check that the change arrives. If you use Claude, connect " +
  "it in Settings, under Connections & AI, and ask it to add a task. Tell me what " +
  "felt slow or confusing.";

const PROCESS_TIMEOUT_MS = 45 * 60 * 1000;
const POLL_MS = 30 * 1000;

const b64url = (buf) => Buffer.from(buf).toString("base64url");

function token() {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "ES256", kid: KEY_ID, typ: "JWT" }));
  const body = b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" }));
  const sig = sign("sha256", Buffer.from(`${head}.${body}`), { key: KEY, dsaEncoding: "ieee-p1363" });
  return `${head}.${body}.${b64url(sig)}`;
}

async function asc(method, path, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : {};
  return { ok: res.ok, status: res.status, json };
}

const errors = (r) => (r.json.errors ?? []).map((e) => `${e.code}: ${e.detail ?? e.title}`).join("; ");
const notice = (msg) => console.log(`::notice::${msg}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForBuild() {
  const query = `/v1/builds?filter[app]=${APP_ID}&filter[version]=${encodeURIComponent(BUILD_NUMBER)}` +
    `&filter[preReleaseVersion.platform]=IOS&limit=1`;
  const deadline = Date.now() + PROCESS_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const r = await asc("GET", query);
    if (!r.ok) throw new Error(`build lookup failed (${r.status}): ${errors(r)}`);
    const build = r.json.data?.[0];
    const state = build?.attributes?.processingState;
    if (state === "VALID") return build.id;
    if (state === "FAILED" || state === "INVALID") throw new Error(`build ${BUILD_NUMBER} processing ${state}`);
    console.log(`build ${BUILD_NUMBER}: ${state ?? "not visible yet"}; waiting`);
    await sleep(POLL_MS);
  }
  throw new Error(`build ${BUILD_NUMBER} was not processed within 45 minutes`);
}

async function ensureWhatToTest(buildId) {
  const r = await asc("GET", `/v1/builds/${buildId}/betaBuildLocalizations`);
  if (!r.ok) throw new Error(`What to Test lookup failed (${r.status}): ${errors(r)}`);
  // App Store Connect creates an empty en-US row for every build, so an
  // existing row does not mean that the text is there.
  const row = r.json.data?.find((l) => l.attributes?.locale === "en-US");
  if (row?.attributes?.whatsNew) return;
  if (row) {
    const u = await asc("PATCH", `/v1/betaBuildLocalizations/${row.id}`, {
      data: { type: "betaBuildLocalizations", id: row.id, attributes: { whatsNew: WHAT_TO_TEST } },
    });
    if (!u.ok) throw new Error(`What to Test failed (${u.status}): ${errors(u)}`);
    return;
  }
  const c = await asc("POST", "/v1/betaBuildLocalizations", {
    data: {
      type: "betaBuildLocalizations",
      attributes: { locale: "en-US", whatsNew: WHAT_TO_TEST },
      relationships: { build: { data: { type: "builds", id: buildId } } },
    },
  });
  if (!c.ok) throw new Error(`What to Test failed (${c.status}): ${errors(c)}`);
}

async function groupId() {
  const r = await asc("GET", `/v1/betaGroups?filter[app]=${APP_ID}&filter[name]=${encodeURIComponent(GROUP_NAME)}&limit=1`);
  const id = r.json.data?.[0]?.id;
  if (!r.ok || !id) throw new Error(`TestFlight group "${GROUP_NAME}" not found`);
  return id;
}

async function main() {
  const buildId = await waitForBuild();
  await ensureWhatToTest(buildId);

  const gid = await groupId();
  const add = await asc("POST", `/v1/betaGroups/${gid}/relationships/builds`, {
    data: [{ type: "builds", id: buildId }],
  });
  if (!add.ok) throw new Error(`adding build to "${GROUP_NAME}" failed (${add.status}): ${errors(add)}`);
  console.log(`build ${BUILD_NUMBER} is in "${GROUP_NAME}"`);

  const sub = await asc("POST", "/v1/betaAppReviewSubmissions", {
    data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: buildId } } } },
  });
  if (sub.ok) {
    console.log(`build ${BUILD_NUMBER} sent to beta review`);
  } else {
    notice(`build ${BUILD_NUMBER} not sent to beta review (${sub.status}): ${errors(sub)}`);
  }
}

main().catch((err) => {
  console.error(`::error::${err.message}`);
  process.exit(1);
});
