# Septena — iOS/macOS App

A shared task database where humans and AI agents collaborate in real-time. Built with SwiftUI + Convex.

## Stack

- **SwiftUI** — iOS 17+ / macOS 14+
- **Convex** — real-time backend (pure URLSession HTTP client, no SDK)
- **XcodeGen** — project generation

## Quick Start

```bash
git clone https://github.com/envisioning-agent/engage-app.git
cd engage-app
xcodegen generate
open Septena.xcodeproj
```

Add your Convex credentials to the Xcode scheme environment:

| Variable | Value |
|----------|-------|
| `SEPTENA_CONVEX_URL` | `https://your-project.convex.cloud` |
| `SEPTENA_CONVEX_KEY` | Your admin key |

Build and run (⌘R).

## Architecture

```
Septena/
├── App.swift                    # TabView entry point
├── Views/
│   ├── TaskListView.swift        # Generic filterable task list
│   ├── TaskRowView.swift         # Task row: thinking preview, badges
│   ├── TaskDetailView.swift      # Full task: agent bubble, comments, actions
│   ├── QuickEntryView.swift      # New task: When sheet, Move sheet
│   ├── TodayView.swift           # Today, Upcoming, Anytime, Someday, Logbook, Review
│   └── AreasProjectsView.swift   # Areas, Projects, Area/Project detail
SeptenaCore/
├── Models.swift                 # All data types
├── ConvexClient.swift           # Pure URLSession → Convex HTTP API
└── DateParser.swift             # Natural language date parsing
```

## Views

| View | Description |
|------|-------------|
| **Today** | Tasks due today |
| **Upcoming** | Next 7 days |
| **Anytime** | Open tasks with no date |
| **Inbox** | Undated, unprojected tasks |
| **Someday** | Undated, not started |
| **Projects** | Projects grouped by area |
| **Areas** | Areas with project counts |
| **Logbook** | Completion history |
| **Agent** | Agent roster, recent thinking, activity |
| **Review** | Stale + overdue + blocked tasks with agent reasoning inline |

## Key UX Features

### 🤖 Agent Thinking Preview
Task rows with an `agentNote` show a truncated "brain + text" preview — glanceable without opening the task.

### Human Review Banner
Tasks marked `needsHumanReview` by an agent surface a prominent banner with **Accept / Dismiss / Reply** buttons. The agent is waiting.

### Comment Threading
Comments support back-and-forth between human and agent. Human can mark threads **Resolved** to declutter.

### Confidence Indicator
Agents set confidence (0–3) on tasks they own. Low-confidence tasks bubble up in Review. Shown as a colored dot on the row.

### Review with Agent Reasoning
Stale, overdue, and blocked tasks in Review show the agent's `agentNote` and `agentContext` inline — no need to open each task to understand the status.

## Data Model (Convex)

### Task
```typescript
origin: "human" | "agent"
owner: "human" | agentId
agentNote: string?        // agent reasoning visible to human
confidence: 0 | 1 | 2 | 3 // 0=none, 3=high
needsHumanReview: boolean // agent wants human to confirm
agentStatus: "pending" | "in_progress" | "blocked" | "done"
```

### Comment
```typescript
actor: "human" | agentId
body: string
resolved: boolean        // thread can be marked resolved
```

## Development

### Modifying Convex schema
1. Edit `engage-server/engage/convex/schema.ts`
2. Restart `npx convex dev`
3. Update `ConvexClient.swift` dict helpers if needed

### Adding a view
1. Create SwiftUI file in `Septena/Views/`
2. Add to `TabView` in `App.swift`
3. Inject `ConvexClient` via `@EnvironmentObject`

## License

Private — Michell Zappa
