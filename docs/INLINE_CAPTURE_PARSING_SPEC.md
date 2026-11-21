# Inline natural-language capture in task titles — spec

**Status:** proposal (2026-11-21). Defaults in §6 stand unless mz overrules.
**Decisions:** [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md).
**Builds on:** `SeptenaCore/DateParser.swift`, `Septask/SeptaskKitQuickEntry.swift`, `Septask/SeptaskKitComposer.swift`, `Septena/Shell/Tasks/AddTaskPage.swift`, `Septena/Shell/Tasks/TaskComposer.swift`.
**Tracking issue:** [#133](https://github.com/michellzappa/septena/issues/133).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

## 1. Goal

Let users capture dates, times, repeats, and (once `#96` ships) tags/lists inline while typing a task title — closing the capture-speed gap with Todoist, TickTick, and Superlist without ever fighting literal titles.

**UX / IA ideal (progressive disclosure & never fight the user):**
- Unobtrusive live detection while typing in Mac Quick Entry (`⌃⌥Space`), Mac inline composer, and iOS Quick Add.
- Recognized tokens get a subtle highlight + live pill preview underneath (`When: Fri, Nov 27`).
- **One-tap / Backspace / Esc escape hatch:** Clicking the highlighted token or pressing Backspace immediately after it turns it back into plain literal text for that task.
- Never silently strip words from a title without showing the active pill preview.
- Optional toggle in Settings ▸ Tasks (`Parse dates in titles`, default ON) for users who want pure literal titles.

## 2. Shared parser contract (`SeptenaCore/DateParser.swift`)

Extend `DateParser` with a pure, range-preserving extractor `TitleTokenParser.parse(_ input: String, relativeTo today: Date) -> TitleParseResult`:
- Returns:
  - `cleanedTitle: String` (trimmed, collapsed double spaces)
  - `tokens: [ParsedToken]` — each carrying `range: Range<String.Index>`, `rawText: String`, `kind` (`.scheduled(day)`, `.deadline(day)`, `.time(hhmm)`, `.recurrence(Recurrence)`, `.tag(name)`, `.project(query)`)
  - `suppressedRanges: Set<Range<String.Index>>` (ranges the user tapped to keep literal)
- **Strict false-positive guardrails:**
  - Never parse inside URLs (`http://`, `https://`, `mailto:`) or quoted strings (`"Friday Night Lights"`).
  - Never parse bare numbers alone (only explicit `+3d`, `dec 4`, `tomorrow`, `next fri`, `at 14:00`, `every weekday`).
  - Only parse at word boundaries; if removing a token would leave `cleanedTitle` empty (e.g. a task literally titled `"Tomorrow"`), keep it as literal text!
- **Golden conformance suite (`registry/conformance/title-parser.json`):** Lockstep vectors for Swift, TypeScript (Web `#21`), and Kotlin (Android `#20`), including tricky literal titles (`"Read Friday Night Lights"`, `"123 May 1st Ave"`, `"Check https://example.com/fri"`, `"Every day carry"`).

## 3. UI integration

- **Mac (`SeptaskKitQuickEntry.swift`, `SeptaskKitComposer.swift`):** Highlight matched token ranges in the input field with subtle accent underline/wash; show parsed pills in the existing pill row; clicking a highlighted token (or `⌘Z` right after parse) marks that range literal.
- **iPhone & iPad (`AddTaskPage.swift`, `TaskComposer.swift`):** Same live pill preview above the keyboard accessory bar with one-tap `"Keep as text"` dismissal.
- **Undo:** Submitting creates the task with parsed fields in one `TaskUndo` entry.

## 4. Phases

| Phase | Scope | Depends on |
|---|---|---|
| **NL0 — Pure `TitleTokenParser` & conformance vectors** | Implement `TitleTokenParser` in `SeptenaCore/DateParser.swift` (dates, times `#128`, repeats `#126`, `#project`/`@tag` hooks) + `registry/conformance/title-parser.json` + unit tests. | `#126` RV0 |
| **NL1 — Mac Quick Entry, Composer & iOS Quick Add UI** | Wire live highlight, pill preview, one-tap literal revert, and Settings toggle across Mac & iOS capture surfaces. | NL0 |

## 5. Verification

- Conformance tests pass (0 false positives on tricky-title matrix).
- `SeptenaMac` + `SeptaskMac` builds green.

## 6. Open questions

| Question | Default |
|---|---|
| Enabled by default? | On by default, with one-tap literal revert and a Settings ▸ Tasks toggle *(default)* |
| Initial locale coverage | English + numeric/ISO tokens first, graceful fallback on other locales *(default)* |
| Empty-title guard | If stripping tokens would empty the title, keep text literal *(default)* |
