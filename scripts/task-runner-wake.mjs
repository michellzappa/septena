#!/usr/bin/env node
/**
 * task-runner-wake.mjs — Lightweight SSE wake listener for mz-mini (F1a, #5).
 *
 * Opens `GET /v1/agent/events/stream` against api.septena.app using Node 24's
 * built-in `fetch` (zero npm dependencies), persists the last seen `rev`
 * cursor across restarts, reconnects with exponential backoff, and triggers
 * `scripts/task-runner.sh` immediately on `assigned`, `user_turn`, and
 * `resumed` events.
 *
 * Auth:
 *   SEPTENA_WAKE_TOKEN       Bearer token (`sa1.*` app session or `sm1.*` MCP OAuth)
 *   SEPTENA_WAKE_TOKEN_FILE  Path to a chmod 600 file holding the bearer token
 *                            (re-read on every reconnect so rotation needs no restart)
 *
 * Options (env):
 *   SEPTENA_API_URL          API origin (default: https://api.septena.app)
 *   SEPTENA_RUNNER_SCRIPT    Runner path (default: ./task-runner.sh next to this script)
 *   SEPTENA_RUNNER_MAX       Passed to --max (default: 2)
 *   SEPTENA_WAKE_STATE_FILE  Cursor state JSON (default: ~/Library/Logs/septena-runner/wake-cursor.json)
 *   SEPTENA_WAKE_DEBOUNCE_MS Coalesce burst events before spawning runner (default: 1500)
 */

import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const WAKE_EVENTS = new Set(["assigned", "user_turn", "resumed"]);

export function isWakeEvent(eventName) {
  return WAKE_EVENTS.has(eventName);
}

/**
 * Computes exponential reconnect backoff with ±20% jitter, capped at maxMs.
 */
export function backoffDelayMs(attempt, baseMs = 1_000, maxMs = 60_000, rand = Math.random) {
  const exp = Math.min(maxMs, baseMs * 2 ** Math.min(attempt, 10));
  const jitter = exp * 0.2 * (rand() * 2 - 1);
  return Math.max(250, Math.round(exp + jitter));
}

/**
 * Incremental SSE frame parser. Feed decoded UTF-8 chunks; returns completed
 * frames `{ id, event, data, retry }` and keeps trailing partial lines in state.
 */
export function createSseParser() {
  let buffer = "";
  let id = null;
  let event = "message";
  let dataLines = [];
  let retry = null;

  function flushEvent(out) {
    if (dataLines.length === 0 && id === null && retry === null) {
      event = "message";
      return;
    }
    out.push({
      id,
      event,
      data: dataLines.join("\n"),
      retry,
    });
    id = null;
    event = "message";
    dataLines = [];
    retry = null;
  }

  return {
    feed(chunk) {
      buffer += chunk;
      const out = [];
      let nlIdx;
      while ((nlIdx = buffer.indexOf("\n")) !== -1) {
        let line = buffer.slice(0, nlIdx);
        buffer = buffer.slice(nlIdx + 1);
        if (line.endsWith("\r")) line = line.slice(0, -1);

        if (line === "") {
          flushEvent(out);
          continue;
        }
        if (line.startsWith(":")) {
          // SSE comment / keepalive
          continue;
        }
        const colon = line.indexOf(":");
        const field = colon === -1 ? line : line.slice(0, colon);
        let value = colon === -1 ? "" : line.slice(colon + 1);
        if (value.startsWith(" ")) value = value.slice(1);

        if (field === "id" && !value.includes("\0")) {
          id = value;
        } else if (field === "event") {
          event = value || "message";
        } else if (field === "data") {
          dataLines.push(value);
        } else if (field === "retry" && /^\d+$/.test(value)) {
          retry = Number(value);
        }
      }
      return out;
    },
  };
}

function log(msg) {
  process.stdout.write(`[${new Date().toISOString()}] task-runner-wake: ${msg}\n`);
}

function warn(msg) {
  process.stderr.write(`[${new Date().toISOString()}] task-runner-wake: ${msg}\n`);
}

function readToken() {
  if (process.env.SEPTENA_WAKE_TOKEN_FILE) {
    try {
      return readFileSync(process.env.SEPTENA_WAKE_TOKEN_FILE, "utf8").trim();
    } catch (e) {
      warn(`could not read SEPTENA_WAKE_TOKEN_FILE: ${e.message}`);
      return "";
    }
  }
  return (process.env.SEPTENA_WAKE_TOKEN || "").trim();
}

function loadCursor(stateFile) {
  try {
    const raw = JSON.parse(readFileSync(stateFile, "utf8"));
    if (typeof raw?.rev === "number" && Number.isSafeInteger(raw.rev) && raw.rev >= 0) {
      return raw.rev;
    }
  } catch {
    // First run or unreadable state file -> start from server head
  }
  return null;
}

function saveCursor(stateFile, rev) {
  try {
    mkdirSync(dirname(stateFile), { recursive: true });
    writeFileSync(stateFile, JSON.stringify({ rev, updatedAt: new Date().toISOString() }) + "\n");
  } catch (e) {
    warn(`could not persist cursor (${rev}): ${e.message}`);
  }
}

function sleep(ms, signal) {
  return new Promise((resolvePromise) => {
    if (signal?.aborted) return resolvePromise();
    const t = setTimeout(resolvePromise, ms);
    signal?.addEventListener(
      "abort",
      () => {
        clearTimeout(t);
        resolvePromise();
      },
      { once: true },
    );
  });
}

async function main() {
  if (process.argv.includes("-h") || process.argv.includes("--help")) {
    console.log(
      "Usage: task-runner-wake.mjs\n" +
        "Env: SEPTENA_WAKE_TOKEN or SEPTENA_WAKE_TOKEN_FILE (required), SEPTENA_API_URL,\n" +
        "     SEPTENA_RUNNER_SCRIPT, SEPTENA_RUNNER_MAX (1|2), SEPTENA_WAKE_STATE_FILE,\n" +
        "     SEPTENA_WAKE_DEBOUNCE_MS",
    );
    process.exit(0);
  }

  const apiUrl = (process.env.SEPTENA_API_URL || "https://api.septena.app").replace(/\/+$/, "");
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const runnerScript = resolve(process.env.SEPTENA_RUNNER_SCRIPT || join(scriptDir, "task-runner.sh"));
  const runnerMax = process.env.SEPTENA_RUNNER_MAX === "1" ? "1" : "2";
  const stateFile = resolve(
    process.env.SEPTENA_WAKE_STATE_FILE || join(homedir(), "Library", "Logs", "septena-runner", "wake-cursor.json"),
  );
  const debounceMs = Math.max(0, Number(process.env.SEPTENA_WAKE_DEBOUNCE_MS || 1_500) || 1_500);

  const shutdown = new AbortController();
  process.on("SIGINT", () => {
    log("received SIGINT, shutting down");
    shutdown.abort();
  });
  process.on("SIGTERM", () => {
    log("received SIGTERM, shutting down");
    shutdown.abort();
  });

  let cursor = loadCursor(stateFile);
  let runnerActive = false;
  let rerunQueued = false;
  let debounceTimer = null;
  let agentsPaused = false;

  function scheduleRunner(reason) {
    if (shutdown.signal.aborted) return;
    if (agentsPaused) {
      log(`ignoring wake (${reason}) while agents are paused`);
      return;
    }
    if (runnerActive) {
      rerunQueued = true;
      log(`runner busy; queued follow-up pass (${reason})`);
      return;
    }
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      debounceTimer = null;
      launchRunner(reason);
    }, debounceMs);
  }

  function launchRunner(reason) {
    if (shutdown.signal.aborted || runnerActive) return;
    runnerActive = true;
    rerunQueued = false;
    log(`waking runner (${reason}) -> ${runnerScript} --max ${runnerMax}`);

    const child = spawn(runnerScript, ["--max", runnerMax], {
      stdio: "inherit",
      env: process.env,
    });
    child.on("error", (err) => {
      warn(`failed to spawn runner: ${err.message}`);
      runnerActive = false;
    });
    child.on("exit", (code, sig) => {
      runnerActive = false;
      log(`runner exited (code=${code ?? "null"}, signal=${sig ?? "none"})`);
      if (code === 3) {
        // Paused or stopped by user: do not re-trigger until unpaused/resumed.
        rerunQueued = false;
        return;
      }
      if (rerunQueued && !shutdown.signal.aborted) {
        scheduleRunner("queued-event");
      }
    });
  }

  let attempt = 0;
  let serverRetryMs = 3_000;

  while (!shutdown.signal.aborted) {
    const token = readToken();
    if (!token) {
      warn("no token in SEPTENA_WAKE_TOKEN or SEPTENA_WAKE_TOKEN_FILE; retrying in 30s");
      await sleep(30_000, shutdown.signal);
      continue;
    }

    const streamUrl = new URL(`${apiUrl}/v1/agent/events/stream`);
    const headers = {
      Authorization: `Bearer ${token}`,
      Accept: "text/event-stream",
    };
    if (cursor !== null) {
      headers["Last-Event-ID"] = String(cursor);
    }

    try {
      log(`connecting to ${streamUrl.toString()}${cursor !== null ? ` (cursor=${cursor})` : ""}`);
      const res = await fetch(streamUrl, {
        method: "GET",
        headers,
        signal: shutdown.signal,
      });

      if (res.status === 401 || res.status === 403) {
        warn(`stream auth failed (${res.status}); check/refresh wake token. Retrying in 60s.`);
        await res.body?.cancel().catch(() => {});
        await sleep(60_000, shutdown.signal);
        continue;
      }

      if (!res.ok || !res.body) {
        warn(`stream returned HTTP ${res.status}`);
        await res.body?.cancel().catch(() => {});
        const delay = backoffDelayMs(attempt++, serverRetryMs);
        await sleep(delay, shutdown.signal);
        continue;
      }

      log("stream connected");
      attempt = 0;
      const parser = createSseParser();
      const decoder = new TextDecoder();
      const reader = res.body.getReader();

      while (!shutdown.signal.aborted) {
        const { done, value } = await reader.read();
        if (done) break;
        const frames = parser.feed(decoder.decode(value, { stream: true }));
        for (const frame of frames) {
          if (frame.retry !== null && frame.retry >= 500) {
            serverRetryMs = Math.min(frame.retry, 60_000);
          }
          if (frame.id && /^\d+$/.test(frame.id)) {
            const rev = Number(frame.id);
            if (cursor === null || rev > cursor) {
              cursor = rev;
              saveCursor(stateFile, cursor);
            }
          }
          if (frame.event === "ready") {
            try {
              const info = JSON.parse(frame.data);
              agentsPaused = info?.paused === true;
              if (cursor === null && typeof info?.head === "number") {
                cursor = info.head;
                saveCursor(stateFile, cursor);
              }
              log(`ready (head=${info?.head}, paused=${agentsPaused})`);
            } catch {
              // ignore malformed ready payload
            }
          } else if (frame.event === "paused") {
            agentsPaused = true;
            log("agents paused by user");
          } else if (frame.event === "unpaused") {
            agentsPaused = false;
            log("agents unpaused by user");
            scheduleRunner("unpaused");
          } else if (isWakeEvent(frame.event)) {
            if (frame.event === "resumed") agentsPaused = false;
            let taskId = "";
            try {
              taskId = JSON.parse(frame.data)?.taskId || "";
            } catch {
              // ignore
            }
            scheduleRunner(`${frame.event}${taskId ? `:${taskId}` : ""}`);
          }
        }
      }

      if (!shutdown.signal.aborted) {
        const delay = backoffDelayMs(attempt++, serverRetryMs);
        log(`stream closed by server; reconnecting in ${delay}ms`);
        await sleep(delay, shutdown.signal);
      }
    } catch (err) {
      if (shutdown.signal.aborted) break;
      const delay = backoffDelayMs(attempt++, serverRetryMs);
      warn(`stream error (${err instanceof Error ? err.message : String(err)}); reconnecting in ${delay}ms`);
      await sleep(delay, shutdown.signal);
    }
  }

  if (debounceTimer) clearTimeout(debounceTimer);
  log("stopped");
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((err) => {
    warn(`fatal: ${err instanceof Error ? err.stack || err.message : String(err)}`);
    process.exit(1);
  });
}
