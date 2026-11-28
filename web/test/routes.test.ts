import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  buildWebUrl,
  destinationPath,
  hasPendingAuthOrShareParams,
  isPlainLeftClick,
  parseWebRoute,
  settingsPath,
  taskPagePath,
} from "../src/lib/routes.ts";

describe("web URL routing", () => {
  it("parses canonical smart-list routes without flagging canonicalize", () => {
    const cases: Array<[string, string, "completed" | "deleted"]> = [
      ["/today", "today", "completed"],
      ["/review", "review", "completed"],
      ["/upcoming", "upcoming", "completed"],
      ["/repeating", "repeating", "completed"],
      ["/anytime", "anytime", "completed"],
      ["/starred", "starred", "completed"],
      ["/logbook", "logbook", "completed"],
      ["/logbook/deleted", "logbook", "deleted"],
    ];

    for (const [pathname, expectedId, expectedTab] of cases) {
      const parsed = parseWebRoute(pathname);
      assert.deepEqual(parsed.destination, { kind: "smart", id: expectedId }, pathname);
      assert.equal(parsed.logbookTab, expectedTab, pathname);
      assert.equal(parsed.canonicalize, false, pathname);
      assert.equal(
        buildWebUrl({
          destination: parsed.destination!,
          logbookTab: parsed.logbookTab,
          tagFilterId: null,
          taskPageId: null,
          settingsOpen: false,
          settingsTab: "general",
        }),
        pathname,
      );
    }
  });

  it("canonicalizes root, aliases, trailing slashes, and unknown paths", () => {
    assert.deepEqual(parseWebRoute("/"), {
      destination: { kind: "smart", id: "today" },
      logbookTab: "completed",
      tagFilterId: null,
      taskPageId: null,
      settingsOpen: false,
      settingsTab: undefined,
      expandFaded: false,
      canonicalize: true,
    });

    const inbox = parseWebRoute("/inbox");
    assert.deepEqual(inbox.destination, { kind: "smart", id: "today" });
    assert.equal(inbox.canonicalize, true);

    const someday = parseWebRoute("/someday");
    assert.deepEqual(someday.destination, { kind: "smart", id: "anytime" });
    assert.equal(someday.canonicalize, true);

    const starred = parseWebRoute("/starred");
    assert.deepEqual(starred.destination, { kind: "smart", id: "starred" });
    assert.equal(starred.canonicalize, false);

    const faded = parseWebRoute("/faded");
    assert.deepEqual(faded.destination, { kind: "smart", id: "review" });
    assert.equal(faded.expandFaded, true);
    assert.equal(faded.canonicalize, true);

    const deleted = parseWebRoute("/deleted");
    assert.deepEqual(deleted.destination, { kind: "smart", id: "logbook" });
    assert.equal(deleted.logbookTab, "deleted");
    assert.equal(deleted.canonicalize, true);

    const unknown = parseWebRoute("/something-unknown");
    assert.deepEqual(unknown.destination, { kind: "smart", id: "today" });
    assert.equal(unknown.canonicalize, true);

    const trailing = parseWebRoute("/upcoming/");
    assert.deepEqual(trailing.destination, { kind: "smart", id: "upcoming" });
    assert.equal(trailing.canonicalize, true);
  });

  it("round-trips area, project, and tag filter URLs", () => {
    const area = parseWebRoute("/area/work-1", "?tag=urgent");
    assert.deepEqual(area.destination, { kind: "area", id: "work-1" });
    assert.equal(area.tagFilterId, "urgent");
    assert.equal(area.canonicalize, false);
    assert.equal(
      buildWebUrl({
        destination: area.destination!,
        logbookTab: "completed",
        tagFilterId: area.tagFilterId,
        taskPageId: null,
        settingsOpen: false,
        settingsTab: "general",
      }),
      "/area/work-1?tag=urgent",
    );

    const proj = parseWebRoute("/project/abc1");
    assert.deepEqual(proj.destination, { kind: "project", id: "abc1" });
    assert.equal(proj.canonicalize, false);
    assert.equal(destinationPath({ kind: "project", id: "abc1" }), "/project/abc1");

    const pluralAlias = parseWebRoute("/projects/abc1");
    assert.deepEqual(pluralAlias.destination, { kind: "project", id: "abc1" });
    assert.equal(pluralAlias.canonicalize, true);

    const encoded = parseWebRoute("/area/a%20b");
    assert.deepEqual(encoded.destination, { kind: "area", id: "a b" });
    assert.equal(destinationPath({ kind: "area", id: "a b" }), "/area/a%20b");
  });

  it("round-trips task page URLs and preserves priority over background destination", () => {
    const task = parseWebRoute("/task/cevyq9");
    assert.equal(task.destination, null);
    assert.equal(task.taskPageId, "cevyq9");
    assert.equal(task.canonicalize, false);
    assert.equal(taskPagePath("cevyq9"), "/task/cevyq9");

    assert.equal(
      buildWebUrl({
        destination: { kind: "project", id: "abc1" },
        logbookTab: "completed",
        tagFilterId: "tag1",
        taskPageId: "cevyq9",
        settingsOpen: false,
        settingsTab: "general",
      }),
      "/task/cevyq9",
    );
  });

  it("parses and builds settings tab URLs", () => {
    assert.equal(settingsPath("account"), "/settings/account");
    assert.equal(settingsPath("agents"), "/settings/agents");
    assert.equal(settingsPath("connections"), "/settings/connections");

    const bare = parseWebRoute("/settings");
    assert.equal(bare.settingsOpen, true);
    assert.equal(bare.settingsTab, "general");
    assert.equal(bare.canonicalize, true);

    const agents = parseWebRoute("/settings/agents");
    assert.equal(agents.settingsOpen, true);
    assert.equal(agents.settingsTab, "agents");
    assert.equal(agents.canonicalize, false);

    // The old AI & Agents URL still opens the Agents tab and canonicalizes.
    const aiAlias = parseWebRoute("/settings/ai-agents");
    assert.equal(aiAlias.settingsOpen, true);
    assert.equal(aiAlias.settingsTab, "agents");
    assert.equal(aiAlias.canonicalize, true);

    assert.equal(
      buildWebUrl({
        destination: { kind: "smart", id: "today" },
        logbookTab: "completed",
        tagFilterId: null,
        taskPageId: "cevyq9",
        settingsOpen: true,
        settingsTab: "privacy",
      }),
      "/settings/privacy",
    );
  });

  it("detects transient OIDC and Web Share query params", () => {
    assert.equal(hasPendingAuthOrShareParams(""), false);
    assert.equal(hasPendingAuthOrShareParams("?tag=abc"), false);
    assert.equal(hasPendingAuthOrShareParams("?oidc_code=123"), true);
    assert.equal(hasPendingAuthOrShareParams("?oidc_link=1&oidc_code=123"), true);
    assert.equal(hasPendingAuthOrShareParams("?share_title=Buy+milk"), true);
  });

  it("distinguishes plain left clicks from modified or middle clicks", () => {
    assert.equal(isPlainLeftClick({ button: 0, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false }), true);
    assert.equal(isPlainLeftClick({ button: 0, metaKey: true, ctrlKey: false, shiftKey: false, altKey: false }), false);
    assert.equal(isPlainLeftClick({ button: 0, metaKey: false, ctrlKey: true, shiftKey: false, altKey: false }), false);
    assert.equal(isPlainLeftClick({ button: 1, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false }), false);
  });
});
