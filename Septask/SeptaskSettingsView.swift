import SwiftUI
import SwiftData

/// Septask's Settings — the full app's architecture (`SettingsView`) at
/// task-app scale (docs/SEPTASK.md P3): an identity header card, then
/// intent-grouped `ColoredGlyph` rows into real panes, then About set apart
/// with disc tiles — the same shape as Septena, stripped to what a task app
/// needs. Shell-only composition: behavior lives in shared files
/// (`TaskSettingsSections`, `ClaudeAISettingsPane`, `ThingsImportView`,
/// `SettingsMirror`, `SettingsStore`, `SettingsChrome`, `ProfileAvatar`);
/// only app-local surfaces (the About pages, task privacy copy) are here.
struct SeptaskSettingsView: View {
  enum Destination: Hashable {
    case account
    case general
    case claudeAI
    case calendar
    case reminders
    case data
    case privacy
    case aboutSeptask
    case aboutSeptena
  }

  @Environment(\.dismiss) private var dismiss
  @AppStorage(SettingsKey.welcomeName) private var welcomeName: String = ""
  @AppStorage(SettingsKey.plusUnlocked) private var plusUnlocked: Bool = false
  @State private var path: [Destination] = []

  var body: some View {
    NavigationStack(path: $path) {
      List {
        // Identity card — the Apple-ID analogue, the full app's top-of-
        // Settings row. There's no Septask account: identity is your iCloud.
        Section {
          NavigationLink(value: Destination.account) {
            HStack(spacing: 14) {
              ProfileAvatar(name: welcomeName, isPlus: plusUnlocked, size: 56)
              VStack(alignment: .leading, spacing: 3) {
                Text(welcomeName.isEmpty ? "Your Profile" : welcomeName)
                  .font(.title3.weight(.semibold))
                  .foregroundStyle(.primary)
                if plusUnlocked {
                  SeptenaPlusBadge()
                } else {
                  FreeAccountBadge()
                }
              }
              Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
          }
        }

        Section {
          NavigationLink(value: Destination.general) {
            row("General", icon: "slider.horizontal.3", tint: 0)
          }
        }

        Section {
          NavigationLink(value: Destination.claudeAI) {
            row("AI & Claude", icon: "brain.head.profile", tint: 5)
          }
          NavigationLink(value: Destination.calendar) {
            row("Calendar", icon: "calendar", tint: 6)
          }
          NavigationLink(value: Destination.reminders) {
            row("Reminders", icon: "checklist", tint: 2)
          }
        }

        Section {
          NavigationLink(value: Destination.data) {
            row("Sharing & Data", icon: "square.and.arrow.up", tint: 1)
          }
          NavigationLink(value: Destination.privacy) {
            row("Privacy", icon: "hand.raised", tint: 3)
          }
        }

        // About rows, set apart below the intent groups like the full app:
        // Septena wears its colorful mark (it points at the bigger app);
        // Septask's own About wears the white-on-gray discs — its icon.
        Section {
          NavigationLink(value: Destination.aboutSeptena) {
            Label {
              Text("About Septena")
            } icon: {
              SeptenaDiscTile(size: glyphSize, colored: true)
            }
          }
          NavigationLink(value: Destination.aboutSeptask) {
            Label {
              Text("About Septask")
            } icon: {
              SeptenaDiscTile(size: glyphSize)
            }
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(SettingsTopGradient())
      .navigationTitle("Settings")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .navigationDestination(for: Destination.self) { destination in
        pane(destination)
      }
    }
    #if os(macOS)
    .macSheetFrame()
    #endif
  }

  private var glyphSize: CGFloat {
    #if os(macOS)
    20
    #else
    29
    #endif
  }

  /// The full app's static-row anatomy: label + `ColoredGlyph` tile, tinted
  /// from the shared root palette by row order.
  private func row(_ title: String, icon: String, tint index: Int) -> some View {
    let color = SettingsAccentPalette.colors[index % SettingsAccentPalette.colors.count]
    return Label {
      Text(title)
    } icon: {
      #if os(macOS)
      ColoredGlyph(icon: icon, color: color, size: 20, glyphRatio: 0.48)
      #else
      ColoredGlyph(icon: icon, color: color, size: 29, glyphRatio: 0.38)
      #endif
    }
  }

  @ViewBuilder
  private func pane(_ destination: Destination) -> some View {
    switch destination {
    case .account:      SeptaskAccountPane()
    case .general:      SeptaskGeneralPane()
    case .claudeAI:     ClaudeAISettingsPane().navigationTitle("AI & Claude")
    case .calendar:     CalendarDetail().navigationTitle("Calendar")
    case .reminders:    RemindersInboxDetail().navigationTitle("Reminders")
    case .data:         SeptaskDataPane()
    case .privacy:      SeptaskPrivacyPane()
    case .aboutSeptask: SeptaskAboutPane()
    case .aboutSeptena: AboutSeptenaPane()
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

// MARK: - General (the task app's "home" settings)

/// The task settings promoted to General — accent, the shared task toggles,
/// and the logging-animation switch. This is the "Tasks section becomes the
/// Home settings" move: in a task app, the task knobs ARE the general knobs.
private struct SeptaskGeneralPane: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SectionTheme.self) private var theme
  @AppStorage(SettingsKey.loggingAnimationsEnabled) private var loggingAnimations = true

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

      Section {
        Toggle(isOn: $loggingAnimations) {
          Label("Completion animations", systemImage: "party.popper")
        }
      } footer: {
        Text("The flourish when you clear Today or check off a task. Off keeps the confirming haptic but skips the motion. Reduce Motion always overrides this.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("General")
  }
}

// MARK: - Data

private struct SeptaskDataPane: View {
  var body: some View {
    Form {
      Section {
        NavigationLink {
          ThingsImportView()
        } label: {
          Label("Import from Things", systemImage: "square.and.arrow.down")
        }
      } footer: {
        Text("A one-time migration from a Things database export. Your Things data is never modified.")
      }
      Section {
        EmptyView()
      } footer: {
        Text("Task export and shareable project links are planned — they'll live here.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Sharing & Data")
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

// MARK: - About Septask

private struct SeptaskAboutPane: View {
  @AppStorage(SeptaskWelcome.completedKey) private var welcomeCompleted = false

  var body: some View {
    Form {
      Section {
        LabeledContent("Version", value: SeptaskAbout.versionString)
      } footer: {
        Text("Septask is a focused window onto your tasks: everything lives in your iCloud, synced by CloudKit, readable by no one else. No accounts, no hosted inference, no servers of ours.")
      }
      Section {
        Button("Show Welcome Again") { welcomeCompleted = false }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("About Septask")
  }
}

enum SeptaskAbout {
  static var versionString: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "\(short) (\(build))"
  }
}

// MARK: - About Septena (the relationship page)

/// Explains how the two apps relate — the product facts docs/SEPTASK.md
/// commits to, in user language. No marketing invention: every claim below
/// traces to a plan invariant (same data, both first-class, hiding ≠
/// deleting, sync scope).
private struct AboutSeptenaPane: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    Form {
      Section {
        Text("Septask is the focused task app from Septena, a private life operating system. Both apps read and write the same tasks, areas, and projects — one dataset in your iCloud, two first-class windows onto it.")
      } header: {
        Text("One dataset, two apps")
      }

      Section {
        Text("Edits made in either app appear in the other, usually within seconds when both are open. Your task accent color and task behavior settings travel too.")
        Text("App-local things stay local: each app has its own welcome, view preferences, and window setup.")
          .foregroundStyle(.secondary)
      } header: {
        Text("What syncs")
      }

      Section {
        Text("Septena adds the rest of life around your tasks — habits, training, nutrition, health, dashboards, and a daily Next list — each an optional section you can enable or hide.")
        Button {
          // Opens Septena when installed; otherwise the website.
          openURL(URL(string: "septena://")!) { accepted in
            if !accepted {
              openURL(URL(string: "https://www.septena.app")!)
            }
          }
        } label: {
          Label("Open Septena", systemImage: "arrow.up.forward.app")
        }
      } header: {
        Text("The full picture")
      }

      Section {
        Text("Deleting either app never deletes your data — it lives in your iCloud, not in the app. And hiding the Tasks section inside Septena never turns Septask off.")
      } header: {
        Text("Good to know")
      } footer: {
        Text("septena.app")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("About Septena")
  }
}
