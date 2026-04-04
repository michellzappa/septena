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

Your Convex deployment is live at:
```
https://fiery-oriole-57.eu-west-1.convex.cloud
```

For development, you can run without a key (public reads). For writes, set your admin key from the dashboard → Settings → API Keys.

Add to Xcode scheme environment variables (Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables):
```
ENGAGE_CONVEX_URL=https://fiery-oriole-57.eu-west-1.convex.cloud
ENGAGE_CONVEX_KEY=your-admin-key
```

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
