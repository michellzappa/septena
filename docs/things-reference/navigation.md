# Navigation

Things 3 uses a **sidebar → list → detail** hierarchy. On iPhone this is a `NavigationStack` push model (NOT a tab bar).

## Top level: Sidebar (root)

The sidebar IS the home screen. It is a single scrollable list with three sections:

### 1. Quick Find (top)
A pill-shaped search field at the very top, light gray background, magnifying glass + "Quick Find" placeholder. Tapping it opens a full-screen search over all tasks.

### 2. Smart Lists (system)
Fixed, always-present rows in this order:
- **Inbox** (unsorted new items) — count badge on right
- **Today** — overdue count badge (red pill) + total count
- **Upcoming** (scheduled future items)
- **Anytime** (no date, actionable now)
- **Someday** (no date, not actionable yet)
- **Logbook** (completed items archive)

Counts appear right-aligned, gray. Overdue-in-Today shows a red circular badge with the overdue count, THEN the total count.

### 3. Areas & Projects (user-defined)
- Each **Area** is a collapsible header with a hex icon + name + disclosure chevron
- Nested **Projects** appear below the Area with a circle "pie" icon
- Tapping the Area row navigates into an Area overview
- Tapping a Project navigates into the Project's task list
- Tapping the chevron expands/collapses the Area's project children inline

### Magic Plus button (floating)
A blue circular button, bottom-right, ~56pt diameter, with a plus icon and soft shadow. Always visible on every screen.

## Second level: List (Inbox, Today, Project, Area, etc.)

Pushed onto the stack. Contains:
- **Back chevron** top-left (iOS default)
- **More menu** top-right (•••  in a circle outline) for list options
- **Big title** with colored icon (e.g. "⭐ Today" at 28pt bold)
- **Optional subtitle block** (e.g. calendar events in Today shown as a subtle gray-tinted card at top)
- **Tasks**, optionally grouped by **Project headers** inside the list (in Today, e.g. "Admin", "Envisioning.com")

Groups inside a list (Today, Upcoming, Anytime) use small project/area headers:
- Hex or pie icon + bold project name + chevron (taps to navigate to the project)
- Thin divider below the header
- Tasks nested under it

## Third level: Task detail

When a task is tapped, it **expands inline** in the list with a spring animation (NOT a modal push in most cases). The task row grows to show:
- Title field (large, editable)
- Notes field (multiline, placeholder "Notes")
- Checklist items (optional)
- Metadata row: When (date), Tags, Deadline, List (project)
- Delete button at bottom

Tapping outside or "Done" collapses it back. This inline expansion is a signature Things interaction.

For our first pass, a push-to-detail screen is acceptable — but plan for inline expansion later.

## Multi-select mode

Triggered by:
- Long-press on a task row, OR
- Tapping "Select" from the ••• menu

Behavior:
- Each row grows a **radio-style circle** on the right edge
- Selected rows get a **light blue tint background**
- A **bottom action bar** slides up from the bottom: pill-shaped dark capsule containing **When**, **Move**, **Delete**, **•••**
- "Done" button appears top-right to exit multi-select
- Tapping rows toggles selection

## Transitions

- **Push**: standard iOS slide (NavigationStack default is fine)
- **Inline task expand**: spring animation, 0.35s, slight scale from 1.0 → 1.0 with height grow
- **Multi-select bar**: slide up from bottom, 0.25s ease-out
- **Checkbox tap**: checkbox fills with spring, title strikes through, row fades to 0.5 opacity over ~0.4s, then slides out of list after ~0.6s delay
- **Magic Plus tap**: scales to 0.9 on press, then expands into an entry field at the bottom of the current list
- **Magic Plus drag**: user can drag it up into the list, and a horizontal line shows where the new task will be inserted
