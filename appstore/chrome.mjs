// Headless Chrome over the DevTools protocol, with Node built-ins only (Node
// 22+ for the global WebSocket). Same approach as septena-site
// scripts/capture-scenes.mjs: the installed Chrome renders, so the pipeline
// needs no Playwright and no browser download. Set CHROME to override the path.

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";
import { pathToFileURL } from "node:url";

const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

export async function openChrome() {
  if (!existsSync(CHROME)) throw new Error(`Chrome not found at ${CHROME}. Set CHROME to an installed Chrome.`);
  const profile = mkdtempSync(join(tmpdir(), "septena-appstore-"));
  const proc = spawn(CHROME, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`,
    "--force-color-profile=srgb", "--hide-scrollbars", "--disable-background-networking", "about:blank"],
    { stdio: ["ignore", "ignore", "pipe"] });
  const exited = once(proc, "exit");
  const endpoint = await new Promise((resolve, reject) => {
    let stderr = "";
    const timer = setTimeout(() => reject(new Error("Chrome startup timed out")), 15000);
    proc.once("exit", (code) => { clearTimeout(timer); reject(new Error(`Chrome exited: ${code}`)); });
    proc.stderr.on("data", (d) => {
      stderr += d;
      const m = stderr.match(/DevTools listening on (ws:\/\/\S+)/);
      if (m) { clearTimeout(timer); resolve(m[1]); }
    });
  });
  const ws = new WebSocket(endpoint);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let serial = 0;
  const pending = new Map();
  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.id && pending.has(msg.id)) {
      const call = pending.get(msg.id); pending.delete(msg.id); clearTimeout(call.timer);
      msg.error ? call.reject(new Error(msg.error.message)) : call.resolve(msg.result);
    }
  };
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = ++serial;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 30000);
    pending.set(id, { resolve, reject, timer });
    ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  const call = (method, params) => send(method, params, sessionId);
  await call("Page.enable");
  await call("Runtime.enable");

  const evaluate = async (expression) => {
    const r = await call("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
    return r.result.value;
  };

  return {
    /** Render an HTML file at exactly width×height CSS px and save a PNG. */
    async screenshot(htmlFile, pngFile, { width, height, ready = "true" }) {
      await call("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false });
      await call("Page.navigate", { url: pathToFileURL(htmlFile).href });
      await evaluate(`(async () => {
        const deadline = Date.now() + 15000;
        while (document.readyState !== "complete") {
          if (Date.now() > deadline) throw Error("page not ready");
          await new Promise(r => setTimeout(r, 20));
        }
        await document.fonts.ready;
        await (${ready});
        await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
      })()`);
      const { data } = await call("Page.captureScreenshot", { format: "png", clip: { x: 0, y: 0, width, height, scale: 1 } });
      writeFileSync(pngFile, Buffer.from(data, "base64"));
    },
    async close() {
      ws.close(); proc.kill(); await exited.catch(() => {});
      rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
    },
  };
}
