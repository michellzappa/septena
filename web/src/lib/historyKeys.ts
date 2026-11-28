// Back / Forward through visited lists on web (#849, registry app.goBack /
// app.goForward). The URL already holds the destination (src/lib/routes.ts),
// so browser history is the navigation history and the step is
// history.back() / history.forward().
//
// Safari, Chrome and Firefox on a Mac already go Back / Forward on Cmd-[ /
// Cmd-]. Handling those keys again would step twice, so the app leaves them
// to the browser. Elsewhere the primary key is Ctrl, and no browser binds
// Ctrl-[ / Ctrl-], so the app maps them. Text fields keep their own keys.

import { ACTIONS_CATALOG } from "./generated/registries.ts";

export type HistoryStep = "back" | "forward";

export interface HistoryKeyEvent {
  key: string;
  ctrlKey: boolean;
  metaKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
}

const BACK_KEY = ACTIONS_CATALOG.actions["app.goBack"].shortcut.key;
const FORWARD_KEY = ACTIONS_CATALOG.actions["app.goForward"].shortcut.key;

/** Apple platforms, where the primary key is Cmd (same test as the shortcuts sheet). */
export function isMacPlatform(): boolean {
  return typeof navigator !== "undefined" && /Mac|iPhone|iPad/i.test(navigator.platform || navigator.userAgent);
}

/** The history step the app runs for this key press, or null when the browser or a field owns it. */
export function historyStepForKey(e: HistoryKeyEvent, opts: { isMac: boolean; typing: boolean }): HistoryStep | null {
  if (opts.isMac || opts.typing) return null;
  if (!e.ctrlKey || e.metaKey || e.altKey || e.shiftKey) return null;
  if (e.key === BACK_KEY) return "back";
  if (e.key === FORWARD_KEY) return "forward";
  return null;
}
