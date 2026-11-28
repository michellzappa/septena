#!/usr/bin/env node
// Check a TestFlight promotion before signing or uploading an archive.
// External builds require green CI for the exact main SHA and must not reuse
// a build number already present in App Store Connect. Internal device builds
// use a separate version train and keep their existing approval boundary.

import { appendFileSync } from "node:fs";
import { createPrivateKey, sign } from "node:crypto";

const env = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set`);
  return value;
};

const b64url = (value) => Buffer.from(value).toString("base64url");

function appStoreToken() {
  const now = Math.floor(Date.now() / 1000);
  const keyId = env("APPLE_API_KEY_ID");
  const issuer = env("APPLE_API_ISSUER_ID");
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const claims = b64url(JSON.stringify({ iss: issuer, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" }));
  const signature = sign("sha256", Buffer.from(`${header}.${claims}`), {
    key: createPrivateKey(env("APPLE_API_KEY")),
    dsaEncoding: "ieee-p1363",
  });
  return `${header}.${claims}.${b64url(signature)}`;
}

function setOutput(key, value) {
  const line = `${key}=${value}\n`;
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, line);
  else process.stdout.write(line);
}

function addSummary(heading, detail) {
  const summary = process.env.GITHUB_STEP_SUMMARY;
  if (summary) appendFileSync(summary, `## ${heading}\n\n${detail}\n\n`);
}

function report({ ready, reason, detail, sourceSha, buildNumber, marketingVersion, group }) {
  console.log(`::notice::${detail}`);
  setOutput("ready", String(ready));
  setOutput("reason", reason);
  addSummary(
    ready ? "TestFlight promotion preflight passed" : "TestFlight promotion skipped",
    `${detail}\n\n- Source: \`${sourceSha}\`\n- Version/build: ${marketingVersion} (${buildNumber})\n- Group: ${group}`,
  );
}

async function githubJson(path) {
  const response = await fetch(`https://api.github.com${path}`, {
    headers: {
      Authorization: `Bearer ${env("GITHUB_TOKEN")}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
    },
  });
  const body = await response.text();
  if (!response.ok) throw new Error(`GitHub API request failed (${response.status}): ${body.slice(0, 400)}`);
  return JSON.parse(body);
}

async function appleJson(path) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    headers: { Authorization: `Bearer ${appStoreToken()}` },
  });
  const body = await response.text();
  if (!response.ok) throw new Error(`App Store Connect build lookup failed (${response.status}): ${body.slice(0, 400)}`);
  return JSON.parse(body);
}

async function main() {
  const sourceSha = env("SOURCE_SHA");
  const buildNumber = env("BUILD_NUMBER");
  const marketingVersion = env("MARKETING_VERSION");
  const group = env("TESTFLIGHT_GROUP");

  if (process.env.DEVICE_BUILD === "true") {
    report({
      ready: true,
      reason: "internal-device-build",
      detail: "Internal device build; external release checks do not apply.",
      sourceSha,
      buildNumber,
      marketingVersion,
      group,
    });
    return;
  }

  const repository = env("GITHUB_REPOSITORY");
  const [owner, repo] = repository.split("/");
  if (!owner || !repo) throw new Error(`Invalid GITHUB_REPOSITORY: ${repository}`);

  const branch = await githubJson(`/repos/${owner}/${repo}/branches/main`);
  if (branch.commit.sha !== sourceSha) {
    report({
      ready: false,
      reason: "main_moved",
      detail: `main advanced to ${branch.commit.sha.slice(0, 12)} after this candidate was selected; run a new promotion.`,
      sourceSha,
      buildNumber,
      marketingVersion,
      group,
    });
    return;
  }

  const runs = await githubJson(
    `/repos/${owner}/${repo}/actions/workflows/ci.yml/runs?head_sha=${encodeURIComponent(sourceSha)}&per_page=100`,
  );
  const pushRuns = (runs.workflow_runs ?? [])
    .filter((run) => run.event === "push" && run.head_branch === "main" && run.head_sha === sourceSha)
    .sort((left, right) => right.run_number - left.run_number);
  const latestRun = pushRuns[0];
  if (!latestRun || latestRun.status !== "completed" || latestRun.conclusion !== "success") {
    const state = latestRun
      ? `${latestRun.status}${latestRun.conclusion ? ` (${latestRun.conclusion})` : ""}`
      : "no push CI run found";
    report({
      ready: false,
      reason: "ci_not_green",
      detail: `CI for ${sourceSha.slice(0, 12)} is ${state}; no TestFlight archive was made.`,
      sourceSha,
      buildNumber,
      marketingVersion,
      group,
    });
    return;
  }

  const appId = env("ASC_APP_ID");
  const buildQuery = `/v1/builds?filter[app]=${encodeURIComponent(appId)}` +
    `&filter[version]=${encodeURIComponent(buildNumber)}` +
    `&filter[preReleaseVersion.version]=${encodeURIComponent(marketingVersion)}` +
    "&filter[preReleaseVersion.platform]=IOS&limit=1";
  const existing = await appleJson(buildQuery);
  if (existing.data?.length) {
    report({
      ready: false,
      reason: "already_uploaded",
      detail: `Build ${marketingVersion} (${buildNumber}) already exists in App Store Connect; no duplicate archive was made.`,
      sourceSha,
      buildNumber,
      marketingVersion,
      group,
    });
    return;
  }

  report({
    ready: true,
    reason: "green-new-build",
    detail: `CI run [#${latestRun.run_number}](${latestRun.html_url}) passed; the build is not already in App Store Connect.`,
    sourceSha,
    buildNumber,
    marketingVersion,
    group,
  });
}

main().catch((error) => {
  console.error(`::error::${error.message}`);
  process.exit(1);
});
