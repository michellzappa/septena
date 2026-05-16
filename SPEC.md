# Septena — iOS/macOS App

## Stack
- SwiftUI (iOS 17+ / macOS 14+)
- Convex Swift SDK (real-time subscriptions)
- XcodeGen for project generation

## Views

| View | File | Description |
|------|------|-------------|
| Inbox | `Inbox.swift` | Default input, unsorted tasks |
| Today | `Today.swift` | Due today + started today |
| Upcoming | `Upcoming.swift` | 7-day calendar strip |
| Anytime | `Anytime.swift` | Undated open tasks |
| Someday | `Someday.swift` | Someday/maybe tasks |
| Projects | `Projects.swift` | Project list |
| Areas | `Areas.swift` | Area list |
| Logbook | `Logbook.swift` | Completion history |
| Review | `Review.swift` | Filtered: stale + attention-needed |
| TaskDetail | `TaskDetail.swift` | Full task + comments |
| QuickEntry | `QuickEntry.swift` | Natural language input |
| AgentPanel | `AgentPanel.swift` | Agent memory + activity feed |
| ProjectDetail | `ProjectDetail.swift` | Tasks in a project |
| AreaDetail | `AreaDetail.swift` | Tasks in an area |

## Architecture
- `SeptenaCore/` — shared models, Convex client, date parsing
- `Septena/` — SwiftUI views + view models
- Real-time: Convex subscriptions update views automatically

## Build

```bash
cd engage-app
xcodegen generate
xcodebuild -scheme Septena -destination 'platform=iOS Simulator,name=iPhone 16'
```
