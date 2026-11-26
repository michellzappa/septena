import assert from "node:assert/strict";
import test from "node:test";
import { decideAccountSwitch } from "../src/lib/sync/accountSwitch.ts";
import type { OutboxOp, TaskRow } from "../src/lib/types.ts";

const task = (fields: Partial<TaskRow> = {}): TaskRow => ({ id: "t", title: "Task", status: "open", ...fields });
const op = { clientOpId: "op1" } as unknown as OutboxOp;

test("the same account or no stored account keeps the local data", () => {
  assert.deepEqual(decideAccountSwitch({ userId: "u1", tasks: [task()], outbox: [op] }, "u1"), { kind: "keep" });
  assert.deepEqual(decideAccountSwitch({ userId: null, tasks: [task()], outbox: [op] }, "u2"), { kind: "keep" });
});

test("another account with nothing local wipes without asking", () => {
  assert.deepEqual(decideAccountSwitch({ userId: "u1", tasks: [], outbox: [] }, "u2"), { kind: "wipe" });
  assert.deepEqual(
    decideAccountSwitch({ userId: "u1", tasks: [task({ kind: "heading" })], outbox: [] }, "u2"),
    { kind: "wipe" },
  );
});

test("another account with tasks or unsent changes asks first", () => {
  assert.deepEqual(
    decideAccountSwitch({ userId: "u1", tasks: [task(), task({ id: "t2", status: "done" })], outbox: [] }, "u2"),
    { kind: "ask", summary: { tasks: 2, unsent: 0 } },
  );
  assert.deepEqual(decideAccountSwitch({ userId: "u1", tasks: [], outbox: [op] }, "u2"), {
    kind: "ask",
    summary: { tasks: 0, unsent: 1 },
  });
});
