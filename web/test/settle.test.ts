import assert from "node:assert/strict";
import test from "node:test";
import { COMPLETION_MOTION, CompletionSettleController } from "../src/lib/settle.ts";

test("completion motion tokens match canonical registry defaults", () => {
  assert.equal(COMPLETION_MOTION.settleDelayMs, 3000);
  assert.equal(COMPLETION_MOTION.fadeOutMs, 350);
  assert.equal(COMPLETION_MOTION.checkPopMs, 280);
  assert.equal(COMPLETION_MOTION.pulseRingMs, 400);
});

test("settle window lingers, enters fadeOut, then clears", async () => {
  const settle = new CompletionSettleController(40, 30);
  settle.start("t1", { reviewGroup: "finished" });
  assert.equal(settle.isSettling("t1"), true);
  assert.equal(settle.isFadingOut("t1"), false);
  assert.equal(settle.reviewGroupOf("t1"), "finished");

  await new Promise((r) => setTimeout(r, 52));
  assert.equal(settle.isSettling("t1"), true);
  assert.equal(settle.isFadingOut("t1"), true);

  await new Promise((r) => setTimeout(r, 40));
  assert.equal(settle.isSettling("t1"), false);
  assert.equal(settle.isFadingOut("t1"), false);
});

test("cancelling a settling task aborts the fade-out", async () => {
  const settle = new CompletionSettleController(40, 30);
  settle.start("t1");
  assert.equal(settle.isSettling("t1"), true);
  settle.cancel("t1");
  assert.equal(settle.isSettling("t1"), false);
  await new Promise((r) => setTimeout(r, 90));
  assert.equal(settle.isSettling("t1"), false);
});

test("clearAll drops every active settle immediately", () => {
  const settle = new CompletionSettleController(100, 50);
  settle.start("a");
  settle.start("b");
  settle.clearAll();
  assert.equal(settle.isSettling("a"), false);
  assert.equal(settle.isSettling("b"), false);
});
