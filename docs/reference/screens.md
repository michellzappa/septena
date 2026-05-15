# Screens

Screen-by-screen spec, mapped to the user's screenshots.

## 1. Sidebar (root)

**Reference: screenshot 1**

Scrollable single-column list on white background. No nav bar, no title bar.

**Layout top-to-bottom:**
1. Status bar space
2. 8pt
3. **QuickFindBar** pill (see components.md)
4. 20pt
5. **Smart Lists section** (no header text):
   - Inbox (blue tray, "2" count gray)
   - Today (yellow star, red "1" badge + "29" gray)
   - Upcoming (red calendar)
   - Anytime (teal stack)
   - Someday (tan box)
   - Logbook (green check-square)
6. Hairline divider, inset 20pt leading
7. 16pt
8. **Areas section** (no header text):
   - Morning ☀️ (hex icon, chevron.down) — expanded
   - Admin (hex icon, chevron.down) — collapsed (empty in screenshot)
   - Leads (hex, chevron.down) — expanded, shows:
     - Core (pie circle icon)
     - Signals (pie circle icon)
   - Hairline divider between Areas
   - Marketing (hex, chevron.down) — expanded, shows:
     - Envisioning.com (pie)
     - Community (pie)
     - Newsletter (pie)
9. Bottom: Magic Plus button floating

**Note:** "Morning ☀️" has an emoji suffix in its title — support inline emoji in Area/Project names.

## 2. Inbox list

**Reference: screenshot 2**

Minimal list of unscheduled tasks.

**Layout:**
1. Status bar
2. Nav area: back chevron top-left, •••  menu top-right
3. **ScreenTitle**: blue tray icon + "Inbox" (28pt bold)
4. 20pt gap
5. Task rows (no grouping, no metadata on right in Inbox):
   - "Clean out previous submissions for Cartogram"
   - "3x10 pull-ups"
6. Magic Plus floating bottom-right

Inbox is deliberately stripped down — just title + checkbox.

## 3. Today list

**Reference: screenshot 3**

The most complex list view. Shows calendar + tasks grouped by project.

**Layout:**
1. Nav area: back chevron, ••• menu
2. **ScreenTitle**: yellow star + "Today"
3. **CalendarEventsCard**:
   - "09:00 Gym"
   - "13:30 Almoço"
   - "17:00 Reservation with Apple Support"
4. 16pt
5. Ungrouped tasks (no section header):
   - "Schedule new Apple"
6. 24pt
7. **SectionHeader**: green hex + "Admin >"
8. Task rows with deadline chips on right:
   - "Upload PDFs SVB ⭐"  |  🚩 today (red)
   - "XoloNL Invoices"  |  🚩 3d left (gray)
   - "R$178 M3"  |  🚩 1d left (gray)
   - "CZ Messages"
   - "CZ Payment → Envisioning NL"
9. 24pt
10. **SectionHeader**: blue pie + "Envisioning.com >"
11. Tasks:
    - "Methodology updates"
    - "Services pages feedback Richard"
    - "Content strategy feedback Claude"
    - "Strategy Convos > Implementation Plan"
12. Magic Plus floating

**Notes:**
- Task titles can contain star emoji (⭐) and arrows (→, >) as meaningful content
- Right-side flag chips are red only when "today"; gray for future dates
- Section headers are tappable and navigate to the underlying project

## 4. Project list (Morning ☀️)

**Reference: screenshot 4**

A project/area list showing repeating tasks.

**Layout:**
1. Nav area
2. **ScreenTitle**: hex icon + "Morning ☀️" + ••• (inline with title, not top-right)
3. **Subsection header**: red calendar icon + "Upcoming" (17pt semibold)
4. Hairline divider
5. Task rows (repeating tasks):
   - ↻ [Sun] 5g creatine ↻
   - ↻ [Sun] Face ↻
   - ↻ [Sun] Exercise ↻
   - ↻ [Sun] Dishes ↻
   - ↻ [Sun] Breakfast ↻
   - ↻ [Sun] Walk Lupi ↻
   - ↻ [Tue] Teeth ↻
6. 24pt
7. "Hide later items" link (13pt secondary, tappable)
8. Magic Plus floating

**Notes:**
- Leading recurrence glyph (↻) indicates repeating
- Day chip ([Sun], [Tue]) is a small gray rounded rect with 12pt text
- Trailing ↻ mirrors the leading glyph — visual rhythm
- The ••• appears inline with the title for Area/Project screens (not in nav bar)

## 5. Multi-select state

**Reference: screenshot 5**

Same Morning list, but in multi-select mode with one item selected.

**Layout changes from screen 4:**
- "Done" button appears top-right (pill, blue background, white text)
- Each task row grows a **RadioSelectionCircle** on the right edge
- "Breakfast" row has a filled blue circle (selected) and light blue tint background
- **BottomActionBar** floats at bottom with [When, Move, Delete, •••]
- Magic Plus is hidden while in multi-select

## Screens we also need (not shown)

- **Upcoming** — tasks grouped by date (Today/Tomorrow/This Week headers)
- **Anytime** — tasks grouped by Area/Project, no dates
- **Someday** — similar to Anytime but for unscheduled "maybe" items
- **Logbook** — completed tasks grouped by completion date
- **Task detail (inline expand)** — title + notes + checklist + metadata
- **Quick entry** — what appears when Magic Plus is tapped
- **Date picker sheet** — Today/Evening/Tomorrow/Someday/Custom
- **Area detail** — overview of projects inside an area
