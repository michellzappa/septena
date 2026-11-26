import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { remoteToWeb, parseRpc } from "../bin/septena.mjs";

const bin = new URL("../bin/septena.mjs", import.meta.url).pathname;

test("git remotes become web addresses without credentials", () => {
  assert.equal(remoteToWeb("git@github.com:michellzappa/septena.git"), "https://github.com/michellzappa/septena");
  assert.equal(remoteToWeb("https://github.com/michellzappa/septena.git"), "https://github.com/michellzappa/septena");
  assert.equal(remoteToWeb("https://user:token@github.com/a/b"), "https://github.com/a/b");
  assert.equal(remoteToWeb("ssh://git@gitlab.com/group/sub/repo.git"), "https://gitlab.com/group/sub/repo");
  assert.equal(remoteToWeb("/local/path"), null);
});

test("reads a JSON reply and an event-stream reply", () => {
  assert.deepEqual(parseRpc('{"result":{"a":1}}'), { result: { a: 1 } });
  assert.deepEqual(parseRpc('event: message\ndata: {"result":{"a":2}}\n\n'), { result: { a: 2 } });
  assert.equal(parseRpc("nonsense"), null);
});

test("help runs with no key, and a call without a key fails clearly", () => {
  assert.match(execFileSync(process.execPath, [bin, "--help"], { encoding: "utf8" }), /septena add TITLE/);
  try {
    execFileSync(process.execPath, [bin, "today"], { encoding: "utf8", stdio: "pipe", env: { PATH: "", HOME: "/nonexistent" } });
    assert.fail("expected a failure");
  } catch (e) {
    assert.match(String(e.stderr), /No agent key/);
  }
});
