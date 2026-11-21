import SwiftUI

/// Settings ▸ About ▸ Advanced (depth 2, `registry/settings.json` `advanced`
/// page, docs/SETTINGS_UX_SPEC.md). Holds power-user, diagnostic, and beta
/// surfaces so new users never stumble over developer knobs on depth 0 or 1.
struct SeptaskAdvancedPane: View {
  private var sync: TaskSyncEngine { .shared }
  @AppStorage(SeptaskDiagnosticsCoordinator.enabledKey) private var diagnosticsEnabled =
    RegistrySettings.Defaults.diagnosticsEnabled
  @AppStorage(AIModelTag.visibilityKey) private var showModelLabels =
    RegistrySettings.Defaults.showModelLabels
  @AppStorage(PCCConfig.routingEnabledKey) private var pccRouting =
    RegistrySettings.Defaults.pccRoutingEnabled
  @AppStorage(PCCConfig.reasoningKey) private var pccReasoning =
    RegistrySettings.Defaults.pccReasoning

  @State private var diagnosticsPreview: SeptaskDiagnosticsBatch?
  @State private var diagnosticsPulse: SeptaskDiagnosticsPulse?
  @State private var loadingPulse = false

  private static let page = RegistrySettings.PageID.advanced
  private static let agentTools = RegistrySettings.section("agent_tools", page: page)
  private static let betaAI = RegistrySettings.section("beta_ai", page: page)
  private static let skills = RegistrySettings.itemBySurface["mcp_skills"]
  private static let syncDiagnostics = RegistrySettings.itemBySurface["sync_diagnostics"]
  private static let weeklyDiagnostics = RegistrySettings.itemBySurface["diagnostics_weekly"]
  private static let modelLabels = RegistrySettings.itemByKey["showModelLabels"]
  private static let pccRoutingItem = RegistrySettings.itemByKey["pccRoutingEnabled"]

  var body: some View {
    Form {
      // Agent tools
      Section {
        NavigationLink {
          TasksSkillPane()
        } label: {
          Label(Self.skills?.label ?? "", systemImage: Self.skills?.sfSymbol ?? "book.closed")
        }
      } header: {
        Text(Self.agentTools?.header ?? "")
      } footer: {
        if let footer = Self.agentTools?.footer { Text(footer) }
      }

      // Sync & storage diagnostics
      Section {
        if sync.issues.isEmpty {
          LabeledContent("Sync issues", value: "None")
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
          Button("Clear sync issues") { sync.clearIssues() }
        }
      } header: {
        Text(Self.syncDiagnostics?.label ?? "")
      } footer: {
        if let detail = Self.syncDiagnostics?.detail { Text(detail) }
      }

      // Only renders when at least one local SwiftData write rolled back this launch.
      StoreHealthSettingsSection()

      // Opt-in weekly product diagnostics (moved from consumer Privacy so
      // Privacy holds one clear usage-data control).
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
        Text(Self.weeklyDiagnostics?.label ?? "")
      } footer: {
        if let detail = Self.weeklyDiagnostics?.detail { Text(detail) }
      }

      // Raw JSON paste utility (moved from consumer Import & Export).
      SeptaskPasteJSONSection()

      // Beta / developer AI switches (moved from consumer AI Preferences).
      Section {
        Toggle(isOn: $showModelLabels) {
          VStack(alignment: .leading, spacing: 2) {
            Text(Self.modelLabels?.label ?? "")
            Text(Self.modelLabels?.detail ?? "")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        if let pcc = OnDeviceAI.pccStatus {
          HStack(spacing: 12) {
            Image(systemName: "cloud")
              .font(.title3)
              .foregroundStyle(.secondary)
              .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
              Text("Private Cloud Compute")
              Text(pcc.available ? (pccRouting ? "In use" : "Available, not in use") : pcc.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Circle()
              .fill(!pcc.available ? Color.gray : (pccRouting ? Color.green : Color.orange))
              .frame(width: 10, height: 10)
          }

          Toggle(isOn: $pccRouting) {
            VStack(alignment: .leading, spacing: 2) {
              Text(Self.pccRoutingItem?.label ?? "")
              Text(Self.pccRoutingItem?.detail ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
          .disabled(!pcc.available)

          Picker(RegistrySettings.label(key: "pccReasoning"), selection: $pccReasoning) {
            ForEach(PCCConfig.Reasoning.allCases, id: \.self) { r in
              Text(r.title).tag(r.rawValue)
            }
          }
          .disabled(!pccRouting)
        }
      } header: {
        Text(Self.betaAI?.header ?? "")
      }
    }
    .formStyle(.grouped)
    .navigationTitle(RegistrySettings.pageById[Self.page]?.title ?? "")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
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
