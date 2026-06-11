# Settings Reorganization Proposal

*2026-06-11 · Proposal only — no code changes. Companion to a future implementation
plan. Verified against `Septena/Shell/Settings/SettingsView.swift` as of commit
`0285358` (plus uncommitted intake work).*

## Why

Settings has grown organically to a 5,600-line `SettingsView.swift` with 18+
destinations. The root sidebar today shows:

- 1 identity header (→ Account)
- 11 static rows (Customize, AI, Integrations, Import & Export, Skills, Manage
  Sections, Motion Gallery, Local MCP *(Mac)*, Privacy, About, …)
- ~14 per-section rows (one per installed section, reorderable, dimmed when
  disabled)
- N intake-tracker rows (one per `IntakeKindDTO`, plus "Add tracker…")

That is the exact shape Apple's iOS Settings had before iOS 18 collapsed all
per-app settings into a single **Apps** row. This proposal applies the same
first-principles pass to Septena.

## First principles (borrowed from Apple's Settings)

1. **Identity first.** The Apple ID card sits at the top; Septena's account
   header (name, Septena+, iCloud status) already matches. Keep.
2. **Organize by user intent, not implementation.** "AI", "Skills", "Local
   MCP", and the "Claude" row inside Integrations are four panes answering one
   user question: *what can Claude do with my data?* Apple would never split
   Wi-Fi into "radio", "DHCP", and "captive portal" panes.
3. **One concept, one place.** The section-enabled toggle currently lives in
   both Manage Sections and each section's detail pane; intake trackers appear
   at the root *and* through the Intake section.
4. **Frequency + criticality ordering.** Most-touched panes near the top
   (sections, notifications); About at the bottom; diagnostics invisible.
5. **Progressive disclosure.** The root stays short (~9 rows); depth is fine.
   iOS 18's Apps move is the canonical precedent.
6. **Consumer-clean main surface.** Test benches and repair tools exist, but
   behind one quiet Advanced door (Apple's analog: the Developer pane /
   tap-build-number).

## Diagnosis of the current IA

| Problem | Where it shows today |
| --- | --- |
| Root overload (~26+ rows) | Static destinations + per-section rows + tracker rows (`SettingsView.swift` ~620–708) |
| "Customize" (`.general`) is a junk drawer mixing homepage appearance, time behavior, greeting, animations, notifications, quick actions, app icon | `GeneralSettingsPane` (~line 934) |
| Notifications buried two levels deep under Customize | `NotificationsOverviewPane` (~line 3190) |
| Claude/AI split across four surfaces | `AISettingsPane.swift`, Skills pane (~4746), `LocalMCPSettingsPane.swift`, Claude row in Integrations (~3505) |
| Duplicate enabled-toggle: Manage Sections and section detail are two screens for the same `SectionEntity` state | ~2655 vs ~2841 |
| Intake trackers as top-level rows, disconnected from the Intake section | ~696–708 |
| Developer/diagnostic surfaces user-visible: Motion Gallery, macOS AI provider-force, schema prompts, nutrition CloudKit repair | ~2342, `AISettingsPane.swift`, ~5191, ~5199 |
| `sparkles` SF Symbol used for the Skills row, the "Aware of your day" toggle, and the Claude-nudge toggle — violates the standing no-sparkles iconography rule | skills destination icon, welcome pane, notifications pane |

## Proposed root structure

Nine rows plus the identity header (down from ~26+):

```
[ Identity header → Account ]        person.crop.circle
1. Sections                          square.grid.2x2
2. Home                              house
3. Notifications                     bell.badge
4. General                           slider.horizontal.3
5. Claude & AI                       brain.head.profile
6. Connections                       app.connected.to.app.below.fill
7. Privacy                           hand.raised
8. Data                              externaldrive
9. About                             info.circle   (contains ▸ Advanced)
```

## Pane-by-pane

### Account — unchanged

Name field, Septena+ membership (features list / paywall / mock toggle),
iCloud sync status. Already Apple-shaped.

### Sections — the iOS-18 "Apps" move

One pane absorbing Manage Sections, the per-section root rows, and the tracker
rows:

- Ordered list of all installed sections: glyph + label, dimmed when disabled,
  drag-to-reorder (drives dashboard/sidebar order), **inline enabled toggle**
  (preserves Manage Sections' bulk on/off in one screen), setup/onboarding
  wand button where the plugin declares one.
- Tap → the existing section detail pane, unchanged in substance: color
  swatch, enabled toggle, Show in Next, plugin `detailPaneContent()`,
  auto-rendered notification toggles, Siri tip, skill link, per-section
  export.
- **Intake trackers nest inside the Intake section detail**: one row per kind
  (→ `IntakeManageSheet`) plus "Add tracker…" (→ `IntakeKindWizard`). The
  root "Trackers" group disappears. This pre-aligns with the consumables
  generalization (caffeine/cannabis collapsing into intake kinds).
- The section detail keeps its enabled toggle — it is the deep-link target
  from every drawer's "Customize <Section>" footer. Same `SectionEntity`
  state behind both controls; control duplication is acceptable, the
  *screen* duplication (Manage Sections as a separate destination) is what
  goes away.

### Home — the home tab, in one place

Everything that configures the home tab, pulled out of "Customize":

- **Layout** — homepage renderer picker (tiles / dense / heatmap / rings /
  wheel / correlations) + live preview. Correlations stays Plus-gated.
- **Today timeline** toggle.
- **Welcome** — visibility, name (mirrors Account), tone, data-aware toggle
  (re-iconed, see below).
- **Insights configuration** — correlations window, section filter,
  supplements table, insufficient-data toggle. (It configures the
  correlations *layout*, so it lives with Home rather than at root.)

### Notifications — promoted to root

High-frequency and high-trust; Apple keeps it top-level. Content unchanged:
master toggle, Claude-connection nudge, Coming Up Today / Quiet / Off
overview with rows deep-linking into section detail panes.

### General — the honest small junk drawer

Apple has kept one for 18 years; Septena gets a small one:

- **Time of Day** boundaries (morning/afternoon/evening cutoffs).
- **App Icon** (iOS; Plus-gated colorways).
- **Quick Actions** (iOS Home Screen shortcuts, max 4).
- **Logging animations** toggle (the Motion Gallery itself moves to
  About ▸ Advanced; the user-facing on/off switch stays here).

### Claude & AI — the unification

Merges four surfaces into the one pane users actually think in ("what can
Claude do with my data?"). Matches the already-planned unified "Claude
Access" pane direction:

- **How far AI may reach** — the AI mode radios from `AISettingsPane`.
- **Hosted connection** — the `ClaudeGatewayDetail` card (moved out of
  Integrations), iOS + Mac: connect/refresh to `mcp.septena.app`.
- **Local MCP server** — Mac-only card from `LocalMCPSettingsPane`: toggle,
  scope (this Mac / tailnet), token + rotate, Claude Code connect command.
- **Skills** — connection & conventions (`SkillPreambleView`), per-section
  briefs (`SectionSkillView`), and the copy-gateway-brief button. The copy
  flow must keep using `SectionRegistry.fullSkillMarkdown()` — it is the
  in-app ↔ hosted-gateway lockstep surface.
- The macOS dev provider-force picker moves to About ▸ Advanced.
- This pane naturally hosts the future per-connection access levels
  (read-only / read-write / full) from the MCP delete backlog.

**Iconography:** replace every `sparkles` glyph touched by this reorg (skills
row, "Aware of your day", Claude nudge). Suggested concrete glyphs:
`antenna.radiowaves.left.and.right` (hosted connection), `server.rack`
(local server), `book.closed` (skills/briefs).

### Connections — Integrations, renamed and trimmed

- **Apple:** Reminders, Calendar, Apple Health, Photos, Siri & Shortcuts.
- **Services:** Oura, Withings, GitHub.
- The Claude row leaves for Claude & AI.

### Privacy — unchanged plus one cross-link

Analytics consent, "what is sent" / "what is never sent", Plausible link.
Add a cross-link row to Connections for permission grants (Apple's Privacy &
Security lists permission categories; this is the light-touch equivalent).

### Data — Import & Export, renamed and trimmed

- **Export** — everything + per-section JSON (ShareLink, file sizes).
- **Import** — file picker / paste, preview, apply.
- **Envelope** format reference.
- The nutrition CloudKit repair button and the per-section schema prompts
  move to About ▸ Advanced (power-user/diagnostic, not everyday data tasks).

### About — plus the Advanced door

Logo, version, description, links, platform — unchanged — plus a new
**Advanced** nav row at the bottom containing:

- Motion Gallery (flourish test bench).
- Nutrition CloudKit repair.
- Schema prompts (LLM import prompts per section).
- AI provider-force picker (macOS).

Reachable in release builds behind this one quiet door; optionally
debug-build-only later.

## Migration mapping (old → new)

| Today | Proposed |
| --- | --- |
| Identity header / `.account` | unchanged |
| `.general` "Customize" | split → **Home** + **General** + root **Notifications** |
| `.layout`, `.correlations`, `.welcome` | Home |
| `.timeOfDay`, `.appIcon`, `.quickActions`, animations toggle | General |
| `.notifications` (nested under Customize) | root Notifications |
| `.ai`, `.skills`, `.localMcp`, Claude row in `.integrations` | Claude & AI |
| `.integrations` (remainder) | Connections |
| `.manageSections` + per-section root rows + tracker rows | Sections (trackers under Intake detail) |
| `.importExport` | Data (minus repair + schema prompts) |
| `.motionGallery` | About ▸ Advanced |
| `.siriShortcuts` | unchanged (under Connections ▸ Apple) |
| `.privacy`, `.about` | unchanged |

No `SettingsKey` or storage changes are implied — this is pure navigation IA;
every existing pane is reused, mostly one level deeper. Drawer
"Customize <Section>" deep links (`.section(key)`) keep working unchanged.

## Suggested phasing (when implemented)

1. **Sections collapse** — merge Manage Sections + per-section rows + tracker
   rows into the Sections pane. Biggest win, self-contained.
2. **Customize split** — Home / General / root Notifications.
3. **Claude & AI merge** — move the four surfaces; sweep `sparkles` glyphs in
   the moved rows; rename Integrations → Connections.
4. **Advanced tuck-away** — About ▸ Advanced; move Motion Gallery, repair,
   schema prompts, provider-force.

Each phase is shippable on its own; order minimizes simultaneous churn in
`SettingsDestination`.

## Out of scope / future notes

- **Search/filter over settings rows** — Apple's primary deep-settings
  affordance; a natural follow-up once the hierarchy stabilizes, especially
  on the macOS split view.
- **Consumables generalization** will shrink the section list further;
  the Sections pane already treats trackers as children of Intake.
- **Per-connection Claude access levels** (read-only / read-write / full)
  land inside Claude & AI when built.
