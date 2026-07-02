import SwiftUI
import SwiftData

/// Septask's Settings — a visual mirror of the full app's Settings root
/// (docs/SEPTASK.md P3) at task-app scale: the same `ColoredGlyph` icon-tile
/// rows in intent groups, the same top luminance wash, the same disc-tile
/// About treatment, fed by the same value-based destination pattern —
/// fewer rows, identical design. Shell-only composition: behavior lives in
/// shared files (`TaskSettingsSections`, `ClaudeAISettingsPane`,
/// `ThingsImportView`, `SettingsMirror`, `SettingsChrome`); only app-local
/// concerns (welcome reset, the About pages, the privacy explainer) are
/// defined here.
struct SeptaskSettingsView: View {
  enum Destination: Hashable {
    case tasks
    case claudeAI
    case thingsImport
    case privacy
    case aboutSeptask
    case aboutSeptena
  }

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SectionTheme.self) private var theme
  @State private var path: [Destination] = []

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Section {
          NavigationLink(value: Destination.tasks) {
            row("Tasks", icon: "checkmark", tint: 0)
          }
          HStack {
            row("Accent", icon: "paintpalette", tint: 1)
            Spacer()
            PaletteSwatchButton(selectedHex: theme.token(for: "tasks")) { hex in
              SettingsMirror.setSectionColor("tasks", hex: hex,
                                             context: modelContext,
                                             engine: ckEngine)
              theme.setColor(hex, for: "tasks")
            }
          }
        }

        Section {
          NavigationLink(value: Destination.claudeAI) {
            row("AI & Claude", icon: "brain.head.profile", tint: 5)
          }
          NavigationLink(value: Destination.thingsImport) {
            row("Import from Things", icon: "square.and.arrow.down", tint: 3)
          }
          NavigationLink(value: Destination.privacy) {
            row("Privacy", icon: "hand.raised", tint: 4)
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
    Label {
      Text(title)
    } icon: {
      #if os(macOS)
      ColoredGlyph(icon: icon,
                   color: SettingsAccentPalette.colors[index % SettingsAccentPalette.colors.count],
                   size: 20, glyphRatio: 0.48)
      #else
      ColoredGlyph(icon: icon,
                   color: SettingsAccentPalette.colors[index % SettingsAccentPalette.colors.count],
                   size: 29, glyphRatio: 0.38)
      #endif
    }
  }

  @ViewBuilder
  private func pane(_ destination: Destination) -> some View {
    switch destination {
    case .tasks:
      Form { TaskSettingsSections() }
        .formStyle(.grouped)
        .navigationTitle("Tasks")

    case .claudeAI:
      ClaudeAISettingsPane()
        .navigationTitle("AI & Claude")

    case .thingsImport:
      ThingsImportView()

    case .privacy:
      SeptaskPrivacyPane()

    case .aboutSeptask:
      SeptaskAboutPane()

    case .aboutSeptena:
      AboutSeptenaPane()
    }
  }
}

// MARK: - Privacy

/// Task-only privacy explainer (docs/SEPTASK.md keeps this Septask-specific).
/// Every claim traces to the product's architecture — no marketing copy.
private struct SeptaskPrivacyPane: View {
  var body: some View {
    Form {
      Section {
        Text("Your tasks, areas, projects, and task conversations live in your private iCloud database, synced by CloudKit. There is no Septask account and no server of ours holding your data.")
      } header: {
        Text("Where your data lives")
      }
      Section {
        Text("Nothing leaves your devices unless you connect an AI. Apple's on-device intelligence runs locally; connecting Claude routes requests through your own gateway token, which you can disconnect at any time in AI & Claude.")
      } header: {
        Text("What leaves the device")
      }
      Section {
        Text("Inbox filing suggestions learn from your own history, on this device. The model never uploads anywhere.")
      } header: {
        Text("On-device learning")
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
