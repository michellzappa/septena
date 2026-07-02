import SwiftUI
import SwiftData

/// Septask's dedicated Settings sheet (docs/SEPTASK.md P3). Shell-only
/// composition: every row's behavior lives in shared files — the task
/// toggles in `TaskSettingsSections`, the accent write in `SettingsMirror`
/// (the same synced `SectionEntity.color` Septena's Tasks tile reads), the
/// AI story in `ClaudeAISettingsPane`. Only app-local concerns (welcome
/// reset, about) are defined here.
struct SeptaskSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SectionTheme.self) private var theme
  @AppStorage(SeptaskWelcome.completedKey) private var welcomeCompleted = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack {
            Text("Accent")
            Spacer()
            PaletteSwatchButton(selectedHex: theme.token(for: "tasks")) { hex in
              SettingsMirror.setSectionColor("tasks", hex: hex,
                                             context: modelContext,
                                             engine: ckEngine)
              theme.setColor(hex, for: "tasks")
            }
          }
        } footer: {
          Text("Shared with Septena — changing it here recolors Tasks there too.")
        }

        TaskSettingsSections()

        Section {
          NavigationLink {
            ClaudeAISettingsPane()
              .navigationTitle("AI & Claude")
              #if os(iOS)
              .navigationBarTitleDisplayMode(.inline)
              #endif
          } label: {
            Label("AI & Claude", systemImage: "brain.head.profile")
          }
        } footer: {
          Text("Your AI, your data — Septask never runs hosted inference on your tasks.")
        }

        Section {
          LabeledContent("Version", value: SeptaskAbout.versionString)
          Button("Show Welcome Again") { welcomeCompleted = false }
        } header: {
          Text("About")
        } footer: {
          Text("Septask is a focused window onto the same private task data as Septena: everything lives in your iCloud, synced by CloudKit, readable by no one else.")
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Settings")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    #if os(macOS)
    .macSheetFrame()
    #endif
  }
}

enum SeptaskAbout {
  static var versionString: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "\(short) (\(build))"
  }
}
