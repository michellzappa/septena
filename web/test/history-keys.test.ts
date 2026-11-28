import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { historyStepForKey } from "../src/lib/historyKeys.ts";

const press = (key: string, mods: Partial<{ ctrlKey: boolean; metaKey: boolean; altKey: boolean; shiftKey: boolean }> = {}) => ({
  key,
  ctrlKey: false,
  metaKey: false,
  altKey: false,
  shiftKey: false,
  ...mods,
});

describe("web Back / Forward keys (#849)", () => {
  it("maps Ctrl-[ and Ctrl-] off the Mac", () => {
    assert.equal(historyStepForKey(press("[", { ctrlKey: true }), { isMac: false, typing: false }), "back");
    assert.equal(historyStepForKey(press("]", { ctrlKey: true }), { isMac: false, typing: false }), "forward");
  });

  it("leaves Cmd-[ / Cmd-] on a Mac to the browser", () => {
    assert.equal(historyStepForKey(press("[", { metaKey: true }), { isMac: true, typing: false }), null);
    assert.equal(historyStepForKey(press("[", { ctrlKey: true }), { isMac: true, typing: false }), null);
  });

  it("never acts while typing in a field", () => {
    assert.equal(historyStepForKey(press("[", { ctrlKey: true }), { isMac: false, typing: true }), null);
  });

  it("ignores other keys and modifiers", () => {
    assert.equal(historyStepForKey(press("["), { isMac: false, typing: false }), null);
    assert.equal(historyStepForKey(press("[", { ctrlKey: true, shiftKey: true }), { isMac: false, typing: false }), null);
    assert.equal(historyStepForKey(press("[", { ctrlKey: true, altKey: true }), { isMac: false, typing: false }), null);
    assert.equal(historyStepForKey(press("k", { ctrlKey: true }), { isMac: false, typing: false }), null);
  });
});
