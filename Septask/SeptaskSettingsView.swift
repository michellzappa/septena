import SwiftUI
import SwiftData

/// Septask's Settings — the full app's architecture (`SettingsView`) at
/// task-app scale (docs/SEPTASK.md P3): the same root taxonomy as Septena,
/// with a profile card, intent-grouped `ColoredGlyph` rows, and About set
/// apart with a disc tile. The task app keeps its own focused sub-options,
/// but the first level is deliberately identical so moving between the two
/// apps feels natural. Shell-only composition: behavior lives in shared files
/// (`TaskSettingsSections`, `ClaudeAISettingsPane`, `ThingsImportView`,
/// `SettingsMirror`, `SettingsStore`, `SettingsChrome`, `ProfileAvatar`);
/// only app-local surfaces (the About pages, task privacy copy) are here.
struct SeptaskSettingsView: View {
  enum Destination: Hashable {
    case account
    // Same root destinations, in the same order, as `SettingsView`.
    case sections
    case home
    case notifications
    case connectionsAI
    case sharingData
    case privacy
    case feedback
    case about
    // Focused task-app sub-pages. These are intentionally not root entries.
    case tasks
    case claudeAI
    case calendar
    case reminders
    case thingsImport
  }

  @Environment(\.dismiss) private var dismiss
  @AppStorage(SettingsKey.welcomeName) private var welcomeName: String = ""
  @AppStorage(SettingsKey.plusUnlocked) private var plusUnlocked: Bool = false
  @State private var path: [Destination] = []
  /// Detail selection for the macOS split view (a sidebar+detail Settings
  /// window, matching `SettingsView`). Unused on iOS, which pushes via `path`.
  @State private var selection: Destination? = .sections

  var body: some View {
    #if os(macOS)
    // macOS: a NavigationSplitView (persistent sidebar + detail), sized and
    // Escape-closable like SettingsView — hosted in a real Settings window
    // (SeptaskApp), so it carries native traffic lights, not a Done button.
    NavigationSplitView {
      // Let the native source-list material render — no gradient wash behind a
      // macOS sidebar (matches SettingsView's macOS sidebar). The iOS branch
      // below keeps the gradient, where it's a sheet, not a source list.
      List(selection: $selection) { listContent(selectable: true) }
        .navigationTitle("Settings")
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
    } detail: {
      NavigationStack {
        pane(selection ?? .sections)
          .navigationDestination(for: Destination.self) { pane($0) }
      }
    }
    .frame(width: 820, height: 600)
    .onExitCommand { dismiss() }
    #else
    // iOS/iPad: the same list, pushed in a NavigationStack sheet — matching
    // SettingsView's compact presentation and its drag-to-dismiss affordance.
    NavigationStack(path: $path) {
      List { listContent(selectable: false) }
        .scrollContentBackground(.hidden)
        .background(SettingsTopGradient())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Destination.self) { pane($0) }
    }
    .presentationDragIndicator(.visible)
    #endif
  }

  /// The Settings root list — identical rows on both platforms. `selectable`
  /// picks the navigation idiom: `.tag` for the macOS split view's
  /// `List(selection:)`, a `NavigationLink(value:)` for the iOS push stack.
  @ViewBuilder
  private func listContent(selectable: Bool) -> some View {
    // Identity card — the Apple-ID analogue, the full app's top-of-Settings
    // row. There's no Septask account: identity is your iCloud.
    Section {
      entry(.account, selectable: selectable) {
        HStack(spacing: 14) {
          ProfileAvatar(name: welcomeName, isPlus: plusUnlocked, size: 56)
          VStack(alignment: .leading, spacing: 3) {
            Text(welcomeName.isEmpty ? "Your Profile" : welcomeName)
              .font(.title3.weight(.semibold))
              .foregroundStyle(.primary)
            if plusUnlocked { SeptenaPlusBadge() } else { FreeAccountBadge() }
          }
          Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
      }
    }

    // Keep this root in lockstep with Septena's SettingsView. The destinations
    // below each row can stay task-specific; the familiar scan pattern cannot.
    Section {
      ForEach(rootDestinations, id: \.self) { destination in
        entry(destination, selectable: selectable) { rootRow(destination) }
      }
    }

    // About is set apart below the intent groups exactly as it is in Septena.
    // The white-on-gray discs are Septask's own mark.
    Section {
      entry(.about, selectable: selectable) {
        Label { Text("About") } icon: { SeptenaDiscTile(size: glyphSize) }
      }
    }
  }

  /// Septena's root Settings order. Keep this list parallel with
  /// `SettingsView.staticDestinations` so colors, labels, and muscle memory
  /// remain aligned between the focused and full apps.
  private var rootDestinations: [Destination] {
    [.sections, .home, .notifications, .connectionsAI,
     .sharingData, .privacy, .feedback]
  }

  /// One list row, as either a selectable tag (macOS split view) or a
  /// value-based push link (iOS stack).
  @ViewBuilder
  private func entry<L: View>(_ dest: Destination, selectable: Bool,
                              @ViewBuilder label: () -> L) -> some View {
    if selectable {
      label().tag(dest)
    } else {
      NavigationLink(value: dest) { label() }
    }
  }

  private var glyphSize: CGFloat {
    #if os(macOS)
    20
    #else
    29
    #endif
  }

  /// The full app's static-row anatomy: label + `ColoredGlyph` tile, tinted
  /// from the shared root palette by the identical root-row order.
  private func rootRow(_ destination: Destination) -> some View {
    let color = tint(for: destination)
    return Label {
      Text(title(for: destination))
    } icon: {
      #if os(macOS)
      ColoredGlyph(icon: icon(for: destination), color: color, size: 20, glyphRatio: 0.48)
      #else
      ColoredGlyph(icon: icon(for: destination), color: color, size: 29, glyphRatio: 0.38)
      #endif
    }
  }

  private func title(for destination: Destination) -> String {
    switch destination {
    case .account:       return "Account"
    case .sections:      return "Sections"
    case .home:          return "Home"
    case .notifications: return "Notifications"
    case .connectionsAI: return "Connections & AI"
    case .sharingData:   return "Sharing & Data"
    case .privacy:       return "Privacy"
    case .feedback:      return "Feedback"
    case .about:         return "About"
    case .tasks:         return "Tasks"
    case .claudeAI:      return "AI"
    case .calendar:      return "Calendar"
    case .reminders:     return "Reminders"
    case .thingsImport:  return "Import from Things"
    }
  }

  private func icon(for destination: Destination) -> String {
    switch destination {
    case .account:       return "person.crop.circle"
    case .sections:      return "square.grid.2x2"
    case .home:          return "house"
    case .notifications: return "bell.badge"
    case .connectionsAI: return "brain.head.profile"
    case .sharingData:   return "square.and.arrow.up"
    case .privacy:       return "hand.raised"
    case .feedback:      return "bubble.left.and.bubble.right"
    case .about:         return "info.circle"
    case .tasks:         return "checklist"
    case .claudeAI:      return "brain.head.profile"
    case .calendar:      return "calendar"
    case .reminders:     return "checklist"
    case .thingsImport:  return "square.and.arrow.down"
    }
  }

  private func tint(for destination: Destination) -> Color {
    guard let index = rootDestinations.firstIndex(of: destination) else { return .gray }
    return SettingsAccentPalette.colors[index % SettingsAccentPalette.colors.count]
  }

  @ViewBuilder
  private func pane(_ destination: Destination) -> some View {
    switch destination {
    case .account:       SeptaskAccountPane()
    case .sections:      SeptaskSectionsPane()
    case .home:          SeptaskHomePane()
    case .notifications: SeptaskNotificationsPane()
    case .connectionsAI: SeptaskConnectionsAISettingsPane()
    case .sharingData:   SeptaskSharingDataPane()
    case .privacy:       SeptaskPrivacyPane()
    case .feedback:      SeptaskFeedbackPane()
    case .about:         SeptaskAboutPane()
    case .tasks:         SeptaskTaskSettingsPane()
    case .claudeAI:      ClaudeAISettingsPane().navigationTitle(title(for: destination))
    case .calendar:      CalendarDetail().navigationTitle(title(for: destination))
    case .reminders:     RemindersInboxDetail().navigationTitle(title(for: destination))
    case .thingsImport:  ThingsImportView().navigationTitle(title(for: destination))
    }
  }
}

// MARK: - Account

/// The Apple-ID analogue: editable name + iCloud sync state. No membership
/// section (the support flow is Septena's; Septask stays out of it for v1).
private struct SeptaskAccountPane: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store
  @AppStorage(SettingsKey.welcomeName) private var welcomeName: String = ""
  @AppStorage(SettingsKey.plusUnlocked) private var plusUnlocked: Bool = false

  var body: some View {
    Form {
      Section {
        HStack(spacing: 16) {
          ProfileAvatar(name: welcomeName, isPlus: plusUnlocked, size: 64)
          VStack(alignment: .leading, spacing: 4) {
            TextField("Your name", text: $welcomeName)
              .font(.title2.weight(.semibold))
              .textContentType(.givenName)
              #if os(iOS)
              .textInputAutocapitalization(.words)
              #endif
              .onChange(of: welcomeName) { _, newValue in
                store.setWelcomeName(newValue, context: modelContext, engine: ckEngine)
              }
            if plusUnlocked {
              SeptenaPlusBadge()
            } else {
              FreeAccountBadge()
            }
          }
        }
        .padding(.vertical, 6)
      } footer: {
        Text("Your name and supporter status are shared with Septena via iCloud. There's no Septask account — your identity is your Apple ID, and supporting happens in Septena.")
      }

      Section {
        HStack {
          Label("Sync", systemImage: iCloudStatus.symbol)
          Spacer()
          Text(iCloudStatus.text).foregroundStyle(.secondary)
        }
      } header: {
        Text("iCloud")
      } footer: {
        Text("Septask keeps your tasks in your private iCloud — nothing lives on a server of ours.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Account")
  }

  private var iCloudStatus: (text: String, symbol: String) {
    switch ckEngine.accountStatus {
    case .available:              return ("Active", "checkmark.icloud.fill")
    case .noAccount:              return ("No iCloud account", "exclamationmark.icloud.fill")
    case .restricted:             return ("Restricted", "xmark.icloud.fill")
    case .temporarilyUnavailable: return ("Temporarily unavailable", "exclamationmark.icloud.fill")
    default:                      return ("Checking…", "icloud")
    }
  }
}

// MARK: - Sections

/// Septena's Sections root condensed to Septask's one always-on domain. This
/// preserves the same route (Settings → Sections → Tasks) without implying
/// that the focused app can add, remove, or configure life domains.
private struct SeptaskSectionsPane: View {
  @Environment(SectionTheme.self) private var theme

  var body: some View {
    Form {
      Section {
        NavigationLink(value: SeptaskSettingsView.Destination.tasks) {
          HStack(spacing: 12) {
            ColoredGlyph(icon: "checklist", color: theme.color(for: "tasks"),
                         size: glyphSize, glyphRatio: glyphRatio)
            VStack(alignment: .leading, spacing: 2) {
              Text("Tasks")
              Text("Inbox, Today, areas, and projects")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      } footer: {
        Text("Tasks is always on in Septask. Set its color and behavior here; shared task settings carry over to Septena.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Sections")
  }

  private var glyphSize: CGFloat {
    #if os(macOS)
    20
    #else
    29
    #endif
  }

  private var glyphRatio: CGFloat {
    #if os(macOS)
    0.48
    #else
    0.38
    #endif
  }
}

// MARK: - Tasks

/// The single section detail in the focused app. Septena exposes these same
/// controls at Settings → Sections → Tasks; the route stays parallel even
/// though Septask has no other sections to list.
private struct SeptaskTaskSettingsPane: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SectionTheme.self) private var theme

  var body: some View {
    Form {
      Section {
        HStack {
          Text("Accent")
          Spacer()
          PaletteSwatchButton(selectedHex: theme.token(for: "tasks")) { hex in
            SettingsMirror.setSectionColor("tasks", hex: hex,
                                           context: modelContext, engine: ckEngine)
            theme.setColor(hex, for: "tasks")
          }
        }
      } footer: {
        Text("The accent is shared with Septena — changing it here recolors Tasks there too.")
      }

      TaskSettingsSections()
    }
    .formStyle(.grouped)
    .navigationTitle("Tasks")
  }
}

// MARK: - Home

/// Septask's Home counterpart: presentation preferences for its focused task
/// home, rather than the full app's dashboard-layout controls.
private struct SeptaskHomePane: View {
  @AppStorage(SettingsKey.loggingAnimationsEnabled) private var loggingAnimations = true
  @AppStorage(SeptaskNextFold.showInTodayKey) private var showNextInToday = true

  var body: some View {
    Form {
      Section {
        NavigationLink {
          TextSizeSettingsPane()
        } label: {
          Label("Text Size", systemImage: "textformat.size")
        }
      } footer: {
        Text("Sets the app's text size on this device. It doesn't change Septena.")
      }

      Section {
        Toggle(isOn: $showNextInToday) {
          Label("Next in Today", systemImage: "arrow.right")
        }
      } footer: {
        Text("Appends your Next feed — suggestions, chores, habits, supplements, and today's log — as a foldable section at the end of Today. Everything checks off here exactly like in Septena.")
      }

      Section {
        Toggle(isOn: $loggingAnimations) {
          Label("Completion animations", systemImage: "party.popper")
        }
      } footer: {
        Text("The flourish when you clear Today or check off a task. Off keeps the confirming haptic but skips the motion. Reduce Motion always overrides this.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Home")
  }
}

// MARK: - Notifications

/// Septask's notification surface: the overdue badge (driven by the shared
/// BadgeManager this app starts at launch) and the Claude reconnect nudge
/// (armed from ClaudeGatewayProvider in core). Septena's per-section nudge
/// scheduler is SectionRegistry-driven and doesn't run here; task deadline
/// reminders are the planned addition.
private struct SeptaskNotificationsPane: View {
  @AppStorage(SettingsKey.badgeShowOverdue) private var taskBadge: Bool = false
  @AppStorage(ClaudeGatewayProvider.connectionNudgeKey) private var claudeNudge: Bool = true

  var body: some View {
    Form {
      Section {
        Toggle("Show overdue indicator on app icon", isOn: $taskBadge)
      } header: {
        Text("Badge")
      } footer: {
        Text("Marks the app icon while any task is overdue — the same count as Today's overdue pill. On Mac it's a dock dot; per-device, so each device opts in on its own.")
      }

      Section {
        Toggle(isOn: $claudeNudge) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Claude connection")
            Text("A quiet reminder when the Claude connection needs a refresh.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Nudges")
      } footer: {
        Text("The reminder is scheduled by whichever app you last used, so reconnecting works entirely from Septask. Reminders for task deadlines are planned — they'll live here.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Notifications")
    // Like Septena, ask only once the user intentionally opens this screen —
    // never as a surprise during Septask launch.
    .task {
      guard claudeNudge else { return }
      await ClaudeReconnectNudge.shared.requestAuthorizationIfNeeded()
    }
    .onChange(of: claudeNudge) { _, enabled in
      Task { @MainActor in
        if enabled {
          await ClaudeReconnectNudge.shared.requestAuthorizationIfNeeded()
        }
        ClaudeReconnectNudge.shared.reconcile()
      }
    }
  }
}

// MARK: - Connections & AI

/// Septena's connection hub narrowed to the services a task-focused app can
/// actually use. Keeping them here removes Calendar and Reminders from the
/// root while preserving the same mental model as the full app.
private struct SeptaskConnectionsAISettingsPane: View {
  var body: some View {
    Form {
      Section {
        NavigationLink(value: SeptaskSettingsView.Destination.claudeAI) {
          Label("AI Mode & Claude", systemImage: "brain.head.profile")
        }
      } footer: {
        Text("Choose how AI can help with tasks and connect Claude through your own gateway token.")
      }

      Section {
        NavigationLink(value: SeptaskSettingsView.Destination.reminders) {
          Label("Reminders", systemImage: "checklist")
        }
        NavigationLink(value: SeptaskSettingsView.Destination.calendar) {
          Label("Calendar", systemImage: "calendar")
        }
        NavigationLink(value: SeptaskSettingsView.Destination.thingsImport) {
          Label("Things", systemImage: "square.and.arrow.down")
        }
      } header: {
        Text("Connected Apps")
      } footer: {
        Text("Bring Reminders into your Inbox, weave calendar events into Today and Upcoming, or make a one-time migration from Things. Your source data is never modified.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Connections & AI")
  }
}

// MARK: - Sharing & Data

/// The matching root exists before the task app has a broad export surface.
/// It gives imports, exports, and future project links one stable home instead
/// of making the root taxonomy diverge as those capabilities arrive.
private struct SeptaskSharingDataPane: View {
  var body: some View {
    Form {
      Section {
        availabilityRow("Task export", icon: "square.and.arrow.up")
        availabilityRow("Project links", icon: "link")
      } header: {
        Text("Task Data")
      } footer: {
        Text("Your tasks already sync privately through iCloud. Export and shareable project links will appear here when they are ready.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Sharing & Data")
  }

  private func availabilityRow(_ title: String, icon: String) -> some View {
    HStack {
      Label(title, systemImage: icon)
      Spacer()
      Text("Coming soon")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Feedback

/// Septena's feedback root, task-app specific for now. The full app owns the
/// connected community surfaces; Septask still gives task users a clear, named
/// place to send product feedback instead of burying that route under About.
private struct SeptaskFeedbackPane: View {
  var body: some View {
    Form {
      Section {
        Link(destination: URL(string: "mailto:mz@envisioning.com?subject=Septask%20feedback")!) {
          Label("Send task feedback", systemImage: "paperplane")
        }
      } footer: {
        Text("Tell us what feels great, what gets in the way, or what would make Septask more useful. Your email app opens with a Septask feedback subject.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Feedback")
  }
}

// MARK: - Privacy (task-only)

/// Telemetry transparency (the real level dial, via SettingsStore) plus a
/// task-scoped data-locality explainer. App Lock is intentionally absent —
/// Septask doesn't mount the lock cover yet, so the toggle would be a lie.
private struct SeptaskPrivacyPane: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store
  @AppStorage(SettingsKey.telemetryLevel) private var levelRaw: String =
    TelemetryClient.TelemetryLevel.balanced.rawValue

  private var level: TelemetryClient.TelemetryLevel {
    TelemetryClient.TelemetryLevel(rawValue: levelRaw) ?? .balanced
  }

  var body: some View {
    Form {
      Section {
        Text("Your tasks, areas, projects, and task conversations live in your private iCloud database, synced by CloudKit. There is no Septask account and no server of ours holding your data.")
      } header: {
        Text("Where your data lives")
      }

      Section {
        Text("Nothing leaves your devices unless you connect an AI. Apple's on-device intelligence runs locally; connecting Claude routes requests through your own gateway token, which you can disconnect any time in AI & Claude.")
      } header: {
        Text("What leaves the device")
      }

      Section {
        Picker("Usage data", selection: Binding(
          get: { level },
          set: { store.setTelemetryLevel($0, context: modelContext, engine: ckEngine) }
        )) {
          ForEach(TelemetryClient.TelemetryLevel.allCases, id: \.self) { lvl in
            Text(lvl.title).tag(lvl)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } header: {
        Text("Anonymous usage data")
      } footer: {
        Text(level.summary)
      }

      Section {
        Text("Your tasks and their contents are never sent through analytics — only anonymous, aggregate usage at the level you choose above. This setting syncs across your devices via iCloud.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Privacy")
  }
}

// MARK: - About

private struct SeptaskAboutPane: View {
  @AppStorage(SeptaskWelcome.completedKey) private var welcomeCompleted = false
  @Environment(\.openURL) private var openURL

  var body: some View {
    Form {
      Section {
        VStack(spacing: 6) {
          SeptenaDiscTile(size: 72)
            .padding(.bottom, 6)
          Text("Septask")
            .font(.title2.weight(.semibold))
          Text("Focused tasks, in your iCloud")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text("Version \(SeptaskAbout.versionString)")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
      }

      Section {
        Text("Septask gives your task life a dedicated, calm home: Inbox, Today, Upcoming, areas, projects, and task conversations. It stands on its own for the days when tasks are all you want to think about.")
      } header: {
        Text("A focused task app")
      }

      Section {
        Text("Septask is part of Septena, the private app for the things you choose to track across your life. Septena adds optional sections for habits, training, nutrition, sleep, mood, health, and more — then lets you see those pieces together over time.")
        Text("Neither app is a lesser version of the other. Septask makes task work the whole experience; Septena puts that same work in a wider personal picture.")
          .foregroundStyle(.secondary)
      } header: {
        Text("Part of Septena")
      }

      Section {
        Text("Both apps read and write the same tasks, areas, projects, and task conversations in your private iCloud. Add or change something in either app and it appears in the other — one dataset, two first-class ways to use it.")
        Text("Each app keeps its own welcome, view preferences, and window setup, so you can use either one without rearranging the other.")
          .foregroundStyle(.secondary)
      } header: {
        Text("One private dataset")
      }

      Section {
        Button {
          // Open the full app when it is installed; otherwise point to the
          // website so the relationship never turns into a dead end.
          openURL(URL(string: "septena://")!) { accepted in
            if !accepted {
              openURL(URL(string: "https://www.septena.app")!)
            }
          }
        } label: {
          Label("Open Septena", systemImage: "arrow.up.forward.app")
        }
      } header: {
        Text("See the wider picture")
      }

      Section {
        Text("Deleting either app does not delete your data, and hiding Tasks in Septena does not turn Septask off. Your data stays in your iCloud, not in an account or on a server of ours.")
      } header: {
        Text("Always your choice")
      }

      Section {
        Button("Show Welcome Again") { welcomeCompleted = false }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("About")
  }
}

enum SeptaskAbout {
  static var versionString: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "\(short) (\(build))"
  }
}
