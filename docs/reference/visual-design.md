# Visual Design

## Color palette

Things 3 uses a very restrained palette. Everything is white/black/gray except specific accents.

### Neutrals
- **Background** — pure white (`#FFFFFF`) in light mode
- **Primary text** — near-black (`#1C1C1E` / SwiftUI `.primary`)
- **Secondary text / metadata** — gray (`#8E8E93` / SwiftUI `.secondary`)
- **Tertiary / hints** — lighter gray (`#C7C7CC`)
- **Dividers** — very light gray (`#E5E5EA`), 0.5pt or 1pt
- **Selected row background** — very light blue tint (`#E8F0FE` approx)

### Accent colors (used sparingly)
- **Today star / gold** — `#FFCC00` (system yellow)
- **Inbox blue** — `#4A90E2` (a soft blue, slightly desaturated)
- **Upcoming red/pink** — `#E94D6A` (calendar icon)
- **Anytime teal** — `#4EBFB8`
- **Someday tan** — `#C9A876` (box icon)
- **Logbook green** — `#5FBE7D`
- **Overdue / today flag** — red `#FF3B30`
- **Action button (Magic Plus)** — blue `#0A84FF`, circular, with shadow
- **Badge (count pill)** — red `#FF3B30` with white text for overdue; gray for neutral counts

### Area / Project dots
Each Area uses a hexagonal outline icon in a specific tint. Projects use small circle "pie" icons that fill as they progress. In our screenshots:
- Morning — gray/neutral hex
- Admin — teal hex
- Leads — gray hex (with Core, Signals projects)
- Marketing — gray hex (with Envisioning.com, Community, Newsletter)

Keep Area icons uniformly gray unless the user assigns a color. Project dots inherit the Area color or are gray.

## Typography

Use **SF Pro** (system font). Things uses a slightly rounded weight in places, but we can use the standard system font.

| Role | Size | Weight | Color |
|---|---|---|---|
| Screen title (e.g. "Today", "Inbox") | 28pt | Bold | primary |
| Section header (Area name) | 17pt | Semibold | primary |
| Task title | 16pt | Regular | primary |
| Task metadata (dates, counts) | 13pt | Regular | secondary |
| Sidebar row | 17pt | Regular | primary |
| Sidebar count badge | 13pt | Semibold | varies |
| Quick Find placeholder | 15pt | Regular | tertiary |
| Button ("Done", "Hide later items") | 15pt | Regular | blue/secondary |

Notes:
- Screen titles have a colored icon next to them at the same size (e.g. yellow star + "Today").
- "Hide later items" style affordance is gray, 13pt, left-padded like a row.

## Spacing & layout

- **Row height** — ~44pt for task rows, ~52pt for sidebar rows with larger tap target
- **Horizontal padding** — 20pt (16pt on iPhone SE)
- **Section spacing** — 24pt between Area sections
- **Divider** — 0.5pt hairline, full width minus leading padding, color `#E5E5EA`
- **Checkbox** — 20pt circle, 1.5pt stroke, 12pt leading gap to title
- **Corner radius** — 10pt on cards (calendar events block), 28pt on Magic Plus button, 8pt on pill badges

## Iconography

- Sidebar section icons (Inbox, Today, etc.) are **filled colored shapes** at ~22pt
- Area icons are **outline hexagons** at ~20pt, gray
- Project icons are **outline circles** (pie indicators) at ~18pt, gray
- Use SF Symbols where possible:
  - Inbox: `tray.fill` (tinted blue)
  - Today: `star.fill` (tinted yellow)
  - Upcoming: `calendar` (tinted red)
  - Anytime: `square.stack.3d.up.fill` (tinted teal) or `tray.2.fill`
  - Someday: `archivebox.fill` (tinted tan)
  - Logbook: `checkmark.square.fill` (tinted green)
  - Area: `hexagon` (outline)
  - Project: `circle` or custom pie circle
  - Recurrence: `arrow.triangle.2.circlepath` at small size before/after title
  - Flag: `flag.fill` for overdue/today marker

## Dark mode

Things 3 has a true-black OLED dark mode. For now, build light mode correctly first. Dark mode mirrors: black background, white primary text, darker dividers. Accent colors stay roughly the same.
