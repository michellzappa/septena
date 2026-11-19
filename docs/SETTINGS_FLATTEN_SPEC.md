# Settings flatten (task app) — spec

**Status:** building. Written 2026-11-19. Scope: the task app (target
`Septask`, product name now Septena). The life app's settings
(`Septena/Shell/Settings/`) are out of scope.

## 1. Goal

Settings has too many subpages. Every root row must hold real settings. A
row that holds one toggle or one link is folded into the page it belongs to.

## 2. Before

`SeptaskSettingsView` root: Account, Tasks, Home, Notifications,
Connections & AI, Sharing & Data, Privacy, Feedback, About. Five of these
held almost nothing:

| Row | Content | Problem |
|---|---|---|
| Home | Text Size (a pushed page) + one toggle | Two settings, one of them a subpage |
| Notifications | A link back to the Tasks badge + one toggle | A pointer and a toggle |
| Connections & AI | One link to "AI Mode & Claude" + 3 app rows | A hub: AI was one tap deeper |
| Sharing & Data | Two "coming soon" rows | No settings at all |
| Feedback | One mail link | One link |

## 3. After

```
Account
Tasks                      the shared Tasks pane, plus inline at the end:
                           Text Size (slider), Completion animations
Connections & AI           ONE page: Apple Intelligence, How far AI may reach,
                           Claude ▸, MCP Skills ▸, Reconnect reminder,
                           Connected Apps: Reminders ▸ Calendar ▸ Things ▸
Privacy                    unchanged
About                      + Send feedback, Advanced ▸ Task backend (Mac)
```

Root: Account + 3 rows + About (was Account + 7 + About).

- **Home** removed. Text Size is inline (`TextSizeSliderSection`, shared, in
  `Septena/Shell/UI/TextSizeScale.swift`); `TextSizeSettingsPane` keeps the
  slider plus its preview for the life app.
- **Notifications** removed. The overdue badge was already on the Tasks pane.
  The Claude reconnect nudge moved to Connections & AI, next to the Claude
  connection it is about.
- **Connections & AI** is one page. `ClaudeAISettingsPane` (shared) takes an
  `extra` section builder; the task app passes its nudge and Connected Apps
  sections. `.claudeAI` (the Tasks pane's "AI and Claude" link) opens the
  same page.
- **Sharing & Data** removed until it has a feature. It comes back as a root
  row when task export or project links ship.
- **Feedback** removed. The mail link is in About.

The root keeps the life app's relative order and palette colors.

## 4. Rules for later changes

1. A root row holds settings, not one link or one toggle.
2. A page that only lists links is not a page: its links become sections on
   the parent.
3. Inline what fits in one section. Push only for a list, a builder, a picker
   grid or a long form.
4. No "coming soon" rows. A feature appears in settings when it ships.
5. Standard SwiftUI: `Form` + `Section` + `NavigationLink(value:)`.

## 5. Open questions for mz

| Question | Default |
|---|---|
| Text Size and animations at the end of Tasks, or a small "Display" root row | End of Tasks |
| Reconnect reminder in Connections & AI | Yes |
| Bring back Sharing & Data when export ships | Yes |
