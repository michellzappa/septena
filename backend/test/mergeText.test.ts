import test from "node:test";
import assert from "node:assert/strict";
import { mergeNotes, mergeText } from "../src/store/mergeText.ts";

const cases: [string, string, string, string, string][] = [
  ["changes in different lines", "a\nb\nc", "a\nB\nc", "a\nb\nc\nd", "a\nB\nc\nd"],
  ["both add a line at one place", "milk", "milk\neggs", "milk\nbread", "milk\neggs\nbread"],
  ["both change one line differently", "a\nb", "a\nX\nb", "a\nY\nb", "a\nX\nY\nb"],
  ["different words of one line", "the quick brown fox", "the slow brown fox", "the quick brown cat", "the slow brown cat"],
  ["the same word", "the quick fox", "the slow fox", "the fast fox", "the slow fox\nthe fast fox"],
  ["both write in an empty note", "", "hello", "world", "hello\nworld"],
  ["one deletes what the other changed", "milk", "", "milk and eggs", "milk and eggs"],
  ["one deletes a line the other left", "a\nb\nc", "a\nc", "a\nb\nc\nd", "a\nc\nd"],
  ["both made the same change", "a", "b", "b", "b"],
  ["only the stored text changed", "a", "b", "a", "b"],
];
for (const [name, base, theirs, mine, want] of cases) test(`merge: ${name}`, () => assert.equal(mergeText(base, theirs, mine), want));

test("merge: every line either side added is in the result", () => {
  let seed = 7;
  const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  for (let n = 0; n < 500; n++) {
    const base = Array.from({ length: Math.floor(rnd() * 8) }, (_, i) => `l${i}`);
    const edit = (tag: string) => {
      const out = [...base];
      const added: string[] = [];
      for (let k = 0; k < 3; k++) {
        const at = Math.floor(rnd() * (out.length + 1));
        if (rnd() < 0.6) {
          added.push(`${tag}${n}-${k}`);
          out.splice(at, 0, added[added.length - 1]);
        } else if (out[at]?.startsWith("l")) out.splice(at, 1);
      }
      return { text: out.join("\n"), added };
    };
    const a = edit("a");
    const b = edit("b");
    const merged = mergeText(base.join("\n"), a.text, b.text).split("\n");
    for (const line of [...a.added, ...b.added]) assert.equal(merged.filter((l) => l === line).length, 1, `${n}: ${line}`);
  }
});

test("merge: null is an empty note, and a text over the limit is not merged", () => {
  assert.equal(mergeNotes(null, null, null, 10), null);
  assert.equal(mergeNotes(null, "a", "b", 10), "a\nb");
  assert.equal(mergeNotes("", "aaaaaa", "bbbbbb", 10), "bbbbbb");
});

test("merge: long texts stay fast", () => {
  const base = Array.from({ length: 20_000 }, (_, i) => `line ${i}`);
  const a = base.map((l, i) => (i % 2 ? l : `${l} a`));
  const b = base.map((l, i) => (i % 3 ? l : `${l} b`));
  const start = performance.now();
  mergeText(base.join("\n"), a.join("\n"), b.join("\n"));
  assert.ok(performance.now() - start < 2_000);
});
