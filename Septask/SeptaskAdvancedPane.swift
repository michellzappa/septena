import SwiftUI

/// Settings ▸ About ▸ Advanced (depth 2, `registry/settings.json` `advanced`
/// page, docs/SETTINGS_UX_SPEC.md). Holds the sync and storage diagnostics so
/// new users never stumble over them on depth 0 or 1. Cleaned out 2026-11-22:
/// MCP Skills moved to Connect Claude; Paste JSON, weekly diagnostics and the
/// AI beta switches are gone.
struct SeptaskAdvancedPane: View {
  private var sync: TaskSyncEngine { .shared }

  private static let page = RegistrySettings.PageID.advanced
  private static let syncDiagnostics = RegistrySettings.itemBySurface["sync_diagnostics"]

  var body: some View {
    Form {
      // Sync & storage diagnostics
      Section {
        if sync.issues.isEmpty {
          LabeledContent(RegistrySettings.copy("sync_diagnostics", "issues"), value: "None")
        } else {
          ForEach(sync.issues.suffix(20).reversed(), id: \.key) { issue in
            VStack(alignment: .leading, spacing: 2) {
              Text("\(issue.entity.rawValue) \(issue.id)")
                .font(.caption.monospaced())
              Text(issue.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Button(RegistrySettings.copy("sync_diagnostics", "clear")) { sync.clearIssues() }
        }
      } header: {
        Text(Self.syncDiagnostics?.label ?? "")
      } footer: {
        if let detail = Self.syncDiagnostics?.detail { Text(detail) }
      }

      // Only renders when at least one local SwiftData write rolled back this launch.
      StoreHealthSettingsSection()
    }
    .formStyle(.grouped)
    .navigationTitle(RegistrySettings.pageById[Self.page]?.title ?? "")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}
