import SwiftUI
import SwiftData

/// Septask's Settings — the full app's architecture (`SettingsView`) at
/// task-app scale (docs/SEPTASK.md P3): the same root taxonomy as Septena,
/// with a profile card, intent-grouped `ColoredGlyph` rows, and About set
/// apart with a disc tile. The task app keeps its own focused sub-options,
/// but the first level is deliberately identical so moving between the two
/// apps feels natural. Shell-only composition: behavior lives in shared files
/// (`TaskSettingsPane`, `ClaudeAISettingsPane`, `ThingsImportView`,
/// `SettingsMirror`, `SettingsStore`, `SettingsChrome`, `ProfileAvatar`);
/// only app-local surfaces (the About pages, task privacy copy) are here.
struct SeptaskSettingsView: View {
  enum Destination: Hashable {
    case account
    // A short root: every row holds real settings (docs/SETTINGS_FLATTEN_SPEC.md).
    // Text size and completion motion live on the Tasks pane, and feedback in
    // About. Claude pairs through the task backend (About ▸ Advanced).
    case tasks
    case connectionsAI
    case privacy
    case about
    // Focused task-app sub-pages. These are intentionally not root entries.
    case claudeAI
    case calendar
    case reminders
    case thingsImport
    case taskBackend   // sync account and status, connect Claude
  }

  @Environment(\.dismiss) private var dismiss
  @AppStorage(SettingsKey.welcomeName) private var welcomeName: String = ""
  @AppStorage(SettingsKey.plusUnlocked) private var plusUnlocked: Bool = false
  @State private var path: [Destination] = []
  /// Detail selection for the macOS split view (a sidebar+detail Settings
  /// window, matching `SettingsView`). Unused on iOS, which pushes via `path`.
  @State private var selection: Destination? = .tasks

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
        pane(selection ?? .tasks)
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
        // A sheet needs a visible way out besides the drag (VoiceOver,
        // keyboard, iPad form sheets that don't show the grabber).
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
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
    // row. The Septask account is the Sign in with Apple session with the
    // task backend; signed out, the card says so.
    Section {
      entry(.account, selectable: selectable) {
        HStack(spacing: 14) {
          ProfileAvatar(name: welcomeName, isPlus: plusUnlocked, size: 56)
          VStack(alignment: .leading, spacing: 3) {
            Text(welcomeName.isEmpty ? "Your Profile" : welcomeName)
              .font(.title3.weight(.semibold))
              .foregroundStyle(.primary)
            if plusUnlocked { SeptenaPlusBadge() } else { FreeAccountBadge() }
            if !TaskSyncEngine.shared.signedIn {
              Label("Not signed in", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
      }
    }

    // Root rows in the life app's order and palette; only the rows that hold
    // settings in the task app are shown.
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

  /// Root rows, in the same relative order as the life app's
  /// `SettingsView.staticDestinations`.
  private var rootDestinations: [Destination] {
    [.tasks, .connectionsAI, .privacy]
  }

  /// Septena's full root order, with `nil` where Septena shows Sections, so
  /// each row takes the same palette color it has in Septena.
  private static let septenaPaletteOrder: [Destination?] = [
    .tasks, nil, nil, nil, .connectionsAI,
    nil, .privacy, nil,
  ]

  /// One list row, as either a selectable tag (macOS split view) or a
  /// value-based push link (iOS stack).
  @ViewBuilder
  private func entry<L: View>(_ dest: Destination, selectable: Bool,
                              @ViewBuilder label: () -> L) -> some View {
    if selectable {
      #if os(macOS)
      label().settingsSidebarRow(dest, selection: selection)
      #else
      label().tag(dest)
      #endif
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
    case .connectionsAI: return "Connections & AI"
    case .privacy:       return "Privacy"
    case .about:         return "About"
    case .tasks:         return "Tasks"
    case .claudeAI:      return "Connections & AI"
    case .calendar:      return "Calendar"
    case .reminders:     return "Reminders"
    case .thingsImport:  return "Import from Things"
    case .taskBackend:   return "Task backend"
    }
  }

  private func icon(for destination: Destination) -> String {
    switch destination {
    case .account:       return "person.crop.circle"
    case .connectionsAI: return "brain.head.profile"
    case .privacy:       return "hand.raised"
    case .about:         return "info.circle"
    case .tasks:         return "checklist"
    case .claudeAI:      return "brain.head.profile"
    case .calendar:      return "calendar"
    case .reminders:     return "checklist"
    case .thingsImport:  return "square.and.arrow.down"
    case .taskBackend:   return "arrow.up.doc"
    }
  }

  private func tint(for destination: Destination) -> Color {
    guard let index = Self.septenaPaletteOrder.firstIndex(of: destination) else { return .gray }
    return SettingsAccentPalette.colors[index % SettingsAccentPalette.colors.count]
  }

  /// Septask's navigation value for each linked row on the shared Tasks
  /// pane. `.section` is Septena-only (Septask shows the accent inline).
  private static func taskSettingsDestination(_ link: TaskSettingsLink) -> Destination {
    switch link {
    case .section:   return .tasks
    case .reminders: return .reminders
    case .calendar:  return .calendar
    case .things:    return .thingsImport
    case .claudeAI:  return .claudeAI
    }
  }

  @ViewBuilder
  private func pane(_ destination: Destination) -> some View {
    switch destination {
    case .account:       SeptaskAccountPane()
    case .connectionsAI: SeptaskConnectionsAISettingsPane()
    case .privacy:       SeptaskPrivacyPane()
    case .about:         SeptaskAboutPane()
    case .tasks:         TaskSettingsPane(destination: Self.taskSettingsDestination)
                           .navigationTitle(title(for: destination))
    case .claudeAI:      SeptaskConnectionsAISettingsPane()
    case .calendar:      CalendarDetail().navigationTitle(title(for: destination))
    case .reminders:     RemindersInboxDetail().navigationTitle(title(for: destination))
    case .thingsImport:  ThingsImportView().navigationTitle(title(for: destination))
    case .taskBackend:   SeptaskBackendSettingsPane()
    }
  }
}

// MARK: - Account

/// The Apple-ID analogue: editable name + the task-backend sign-in and sync
/// state. No membership section (the support flow is Septena's; Septask
/// stays out of it for v1).
private struct SeptaskAccountPane: View {
  @Environment(\.modelContext) private var modelContext
  // Only the "push allowed" signal `SettingsStore` takes; in Septask the
  // push goes to the task backend and this engine never starts.
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
        Text("Your name syncs across your devices.")
      }

      SeptaskSyncAccountSection()

      // Next to Sync because the two answer the same worry — "is my work
      // actually stored?" — from opposite ends: Sync covers the trip to
      // the server, this covers the local write that has to land first. Renders
      // nothing when no save has failed this launch. Septask has no Data Tools
      // pane (that lives in Septena ▸ Advanced), so this is its only home.
      StoreHealthSettingsSection()

      SeptaskDeleteAccountSection()
    }
    .formStyle(.grouped)
    .navigationTitle("Account")
  }
}

// MARK: - Connections & AI

/// One page, not a hub: the shared AI + Claude sections (the Claude row opens
/// the task backend pane), then Connected Apps (docs/SETTINGS_FLATTEN_SPEC.md).
private struct SeptaskConnectionsAISettingsPane: View {
  var body: some View {
    ClaudeAISettingsPane {
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
    .navigationTitle("Connections & AI")
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
  @AppStorage(SeptaskDiagnosticsCoordinator.enabledKey) private var diagnosticsEnabled = false
  @State private var diagnosticsPreview: SeptaskDiagnosticsBatch?
  @State private var diagnosticsPulse: SeptaskDiagnosticsPulse?
  @State private var loadingPulse = false

  private var level: TelemetryClient.TelemetryLevel {
    TelemetryClient.TelemetryLevel(rawValue: levelRaw) ?? .balanced
  }

  var body: some View {
    Form {
      Section {
        Text("Septask keeps your tasks, areas, projects, task conversations and a few settings (your name, usage data level, hidden calendars) on your devices. When you sign in, they sync through Septena's own server, in a private store for your account. The server encrypts them at rest, but not end to end, because Claude has to be able to read them.")
      } header: {
        Text("Where your data lives")
      }

      Section {
        Text("Once you sign in, your tasks go to Septena's server so your devices stay in sync. Apple's on-device intelligence runs locally. If you connect Claude, it can read and change your tasks on that server. You pair Claude in About, under Advanced ▸ Task backend.")
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
        Toggle("Share anonymous weekly diagnostics", isOn: Binding(
          get: { diagnosticsEnabled },
          set: { enabled in
            diagnosticsEnabled = enabled
            SeptaskDiagnosticsCoordinator.setEnabled(enabled)
            diagnosticsPreview = enabled ? SeptaskDiagnosticsCoordinator.shared.preview() : nil
            if enabled { refreshDiagnosticsPulse() }
            else { diagnosticsPulse = nil }
          }
        ))

        if diagnosticsEnabled {
          DisclosureGroup("What would be shared") {
            ForEach(SeptaskDiagnosticsBatch.dataCatalog, id: \.self) { item in
              Label(item, systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Divider()

            Text("Never: task text, titles, counts, account identity, or a device identifier.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          if let diagnosticsPreview {
            VStack(alignment: .leading, spacing: 4) {
              Text("This week's preview")
                .font(.callout.weight(.medium))
              Text("\(diagnosticsPreview.period) · \(diagnosticsPreview.app.version) (\(diagnosticsPreview.app.build)) · \(diagnosticsPreview.app.platform)")
              Text("Claude: \(diagnosticsPreview.features.claudeConnected ? "on" : "off") · Calendar: \(diagnosticsPreview.features.calendarAccess ? "on" : "off") · Reminders: \(diagnosticsPreview.features.remindersAccess ? "on" : "off")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }

          if loadingPulse {
            ProgressView("Loading Community Pulse…")
          } else if let latest = diagnosticsPulse?.latest {
            VStack(alignment: .leading, spacing: 4) {
              Text("Community Pulse")
                .font(.callout.weight(.medium))
              Text("\(latest.reportingInstalls) anonymous Septena installs reported for \(latest.period).")
              if let version = latest.versions.first {
                Text("Most reported version: \(version.name) (\(version.installs))")
              }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          } else {
            Text("Community Pulse appears once at least five anonymous installs report.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Optional product diagnostics")
      } footer: {
        Text("This is a separate, opt-in weekly summary that helps improve Septena. You don't need it for updates, sync, or support.")
      }

      Section {
        Text("Your tasks and their contents are never sent through analytics. Only anonymous, aggregate usage is sent, at the level you choose above. This setting syncs across your devices.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Privacy")
    .onAppear {
      diagnosticsPreview = diagnosticsEnabled ? SeptaskDiagnosticsCoordinator.shared.preview() : nil
      if diagnosticsEnabled { refreshDiagnosticsPulse() }
    }
  }

  private func refreshDiagnosticsPulse() {
    guard !loadingPulse else { return }
    loadingPulse = true
    Task { @MainActor in
      diagnosticsPulse = await SeptaskDiagnosticsCoordinator.shared.loadPulse()
      loadingPulse = false
    }
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
          Text("Septena")
            .font(.title2.weight(.semibold))
          Text("Tasks that think with you")
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
        Text("Septena is a task app that thinks with you: Inbox, Today, Upcoming, areas, projects, and conversations on any task that needs a moment of thought.")
      } header: {
        Text("A focused task app")
      }

      Section {
        Text("Septena Life is the companion app for the rest of what you track: habits, training, food, sleep, mood, and health. It shows those pieces together over time.")
        Button {
          // Open Septena Life when it is installed; otherwise point to the
          // website so the link never turns into a dead end.
          openURL(URL(string: "septena://")!) { accepted in
            if !accepted {
              openURL(URL(string: "https://www.septena.app")!)
            }
          }
        } label: {
          Label("Open Septena Life", systemImage: "arrow.up.forward.app")
        }
      } header: {
        Text("Septena Life")
      }

      Section {
        Text("Deleting the app from a device does not delete your tasks. They stay in your sync and come back when you install it again.")
      } header: {
        Text("Always your choice")
      }

      Section {
        #if os(macOS)
        Button("Check for Updates…") {
          Task { @MainActor in SeptaskUpdater.shared.checkForUpdates() }
        }
        #if DEBUG
        .disabled(true)
        #else
        .disabled(!SeptaskUpdater.isConfigured)
        #endif
        #endif
        Button("Show Welcome Again") { welcomeCompleted = false }
      }

      Section {
        Link(destination: URL(string: "mailto:mz@envisioning.com?subject=Septena%20feedback")!) {
          Label("Send feedback", systemImage: "paperplane")
        }
      } footer: {
        Text("Tell us what feels great, what gets in the way, or what would make the app more useful. Your email app opens with a feedback subject.")
      }

      Section {
        NavigationLink(value: SeptaskSettingsView.Destination.taskBackend) {
          Label("Task backend", systemImage: "arrow.up.doc")
        }
      } header: {
        Text("Advanced")
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
