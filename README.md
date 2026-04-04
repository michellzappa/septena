# Engage — iOS/macOS App

## Setup

### 1. Install XcodeGen

```bash
brew install xcodegen
```

### 2. Generate the Xcode project

```bash
xcodegen generate
```

### 3. Configure Convex credentials

Create `~/.engage.env` (or add to your shell profile):

```bash
export ENGAGE_CONVEX_URL=https://your-project.convex.cloud
export ENGAGE_CONVEX_KEY=your-admin-key
```

Or add to Xcode's scheme environment variables in Xcode's Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables.

### 4. Open and build

```bash
open Engage.xcodeproj
```

Or via CLI:

```bash
xcodebuild -scheme Engage -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## File Structure

```
Engage/
├── App.swift                     # App entry + navigation
├── Assets.xcassets/             # Colors, app icon
└── Views/
    ├── TaskListView.swift        # Generic task list (used by Today/Upcoming/etc.)
    ├── TaskDetailView.swift     # Task detail + comments
    ├── QuickEntryView.swift      # Natural language quick entry
    ├── TodayView.swift           # Today, Upcoming, Anytime, Someday, Logbook, Review
    └── AreasProjectsView.swift   # Areas, Projects, AreaDetail, ProjectDetail

EngageCore/
├── Models.swift                 # All data types
├── ConvexClient.swift           # Convex Swift SDK client
└── DateParser.swift             # Natural language date parsing
```

## Views

| View | Description |
|------|-------------|
| Inbox | Unsorted, undated tasks |
| Today | Due / started today |
| Upcoming | 7-day calendar strip |
| Anytime | Undated open tasks |
| Someday | Someday/maybe |
| Projects | All projects |
| Areas | All areas |
| Logbook | Completion history |
| Review | Stale + overdue + blocked |
