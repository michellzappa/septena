import SwiftUI
import SwiftData

/// Septask's Settings — the full app's architecture at task-app scale
/// (docs/SEPTASK.md P3): a root list of intent groups with value-based
/// links into panes, exactly `SettingsView`'s shape, ~5 destinations
/// instead of ~20. Shell-only composition: every behavior lives in shared
/// files (`TaskSettingsSections`, `ClaudeAISettingsPane`, `ThingsImportView`,
/// `SettingsMirror`); only app-local concerns (welcome reset, the two About
/// pages) are defined here.
struct SeptaskSettingsView: View {
  enum Destination: Hashable {
    case tasks
    case claudeAI
    case thingsImport
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
            Label("Tasks", systemImage: "checkmark")
          }
          HStack {
            Label("Accent", systemImage: "paintpalette")
            Spacer()
            PaletteSwatchButton(selectedHex: theme.token(for: "tasks")) { hex in
              SettingsMirror.setSectionColor("tasks", hex: hex,
                                             context: modelContext,
                                             engine: ckEngine)
              theme.setColor(hex, for: "tasks")
            }
          }
        } footer: {
          Text("The accent is shared with Septena — changing it here recolors Tasks there too.")
        }

        Section {
          NavigationLink(value: Destination.claudeAI) {
            Label("AI & Claude", systemImage: "brain.head.profile")
          }
          NavigationLink(value: Destination.thingsImport) {
            Label("Import from Things", systemImage: "square.and.arrow.down")
          }
        }

        Section {
          NavigationLink(value: Destination.aboutSeptask) {
            Label("About Septask", systemImage: "info.circle")
          }
          NavigationLink(value: Destination.aboutSeptena) {
            Label("About Septena", systemImage: "circle.hexagongrid")
          }
        }
      }
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

    case .aboutSeptask:
      SeptaskAboutPane()

    case .aboutSeptena:
      AboutSeptenaPane()
    }
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
