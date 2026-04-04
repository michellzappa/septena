# Components

Reusable UI pieces. Build these as SwiftUI views that compose into screens.

## TaskRow

The most important component. Used everywhere.

**Anatomy (left → right):**
1. Checkbox circle (20pt, 1.5pt stroke, `.secondary` color; fills blue w/ white check when done)
2. 12pt gap
3. Title (16pt regular, primary color; strikethrough when done, 0.5 opacity)
4. Flexible spacer
5. Right-side metadata (13pt secondary):
   - Repeating glyph (↻) if task repeats
   - Day chip (e.g. "Sun", "Tue") — gray 12pt in a subtle rounded rect for repeating tasks
   - Deadline indicator: `🚩 today` (red) or `🚩 3d left` (gray)
6. Trailing chevron only when row is expanded or in detail mode

**States:**
- Default
- Completed (strikethrough + 0.5 opacity)
- Selected (light blue background tint + radio circle on right)
- Expanded inline (taller, shows detail fields)
- Overdue (red flag + today label)

**Padding:** 20pt horizontal, 12pt vertical (yields ~44pt tall default)
**Divider:** hairline below, inset 20pt from leading edge

## Checkbox

Standalone reusable:
- 20pt × 20pt
- Circle stroke `.secondary` 1.5pt when empty
- When checked: fills with `.blue`, white SF Symbol checkmark inside
- Tap: spring scale 0.9 → 1.1 → 1.0, fills during bounce

## SidebarRow

Used for Inbox, Today, Upcoming, etc. and for Areas/Projects.

**Anatomy:**
- Colored SF Symbol icon (22pt)
- 14pt gap
- Title (17pt regular, primary)
- Flexible spacer
- Optional count badge(s) on right:
  - Red circle badge for overdue (white text, 13pt semibold, 20pt min diameter)
  - Gray count number (13pt, secondary)
- For Area rows: trailing chevron (`chevron.down` rotating to `chevron.right` when collapsed)

**Height:** 48pt
**Padding:** 20pt horizontal

## SectionHeader (inside lists)

Used inside Today/Upcoming/Anytime to group tasks by Area/Project.

**Anatomy:**
- Small hex or pie icon (18pt, area color)
- 8pt gap
- Title (17pt semibold, primary)
- 4pt gap
- Chevron (`chevron.right`, 13pt, secondary) — tapping navigates to the Project
- Hairline divider directly below

**Spacing:** 24pt above (from previous section), 8pt below (before first task row)

## ScreenTitle

Big header at the top of list screens.

**Anatomy:**
- Colored icon (28pt) + title (28pt bold primary)
- Leading-aligned, 20pt horizontal padding
- 16pt top padding below nav bar area
- 20pt bottom padding before content

## QuickFindBar

- Full-width minus 20pt padding on each side
- Background: `#F2F2F7` (systemGray6)
- Height: 36pt
- Corner radius: 10pt
- Content: magnifying glass icon (15pt, secondary) + "Quick Find" placeholder (15pt, tertiary), centered

## MagicPlusButton

- 56pt × 56pt circle
- Background: `.blue` (#0A84FF)
- Shadow: y=4, blur=12, black 15% opacity
- Icon: SF Symbol `plus`, white, 24pt semibold
- Position: bottom-trailing, 20pt from edges (respect safe area)
- Press animation: scale to 0.9 over 0.15s, return with spring

## BottomActionBar (multi-select)

- Dark pill capsule: `#1C1C1E` with 90% opacity, corner radius 28pt
- Height: 56pt
- Content: horizontally spaced actions (When / Move / Delete / •••)
- Each action: icon above label OR icon + label inline, white, 15pt
- Floats 20pt from bottom safe area, centered horizontally
- Slide-up entrance animation

## DateChip (swipe/detail)

Small rounded-rect pill shown during swipe-right or in detail:
- "Today" yellow star
- "This Evening" purple moon icon
- "Tomorrow" sun/day icon
- "Someday" stack icon
- Background: white with thin gray border OR colored fill matching icon
- 12pt padding, 8pt corner radius, 13pt text

## CalendarEventsCard

Shown at top of Today list when there are calendar events.

- Background: `#F2F2F7` (light gray)
- Corner radius: 10pt
- Padding: 12pt
- Content: list of events as "HH:MM Title" in gray 14pt
- Full-width minus 20pt horizontal padding
- 16pt top and bottom margins

## RadioSelectionCircle (multi-select)

- 22pt × 22pt circle
- Empty: gray stroke 1.5pt
- Selected: fills blue with smaller inner white circle (dot) — or blue fill with white check
- Appears on right edge of rows in multi-select mode with slide-in animation
