import SwiftUI
#if os(iOS)
import UIKit
#endif

// AI on this device (`ai_preferences`, docs/SETTINGS_UX_SPEC.md):
// Apple Intelligence availability, the global reach dial (`AIMode`), and the
// plain-language explainer. Beta/developer controls (`showModelLabels`, PCC
// entitlement routing) live in `About ▸ Advanced`; `MCP Skills` lives in
// `Agents` (section "Connect an agent").
//
// `SeptaskAIPreferencesSections` renders as Form sections inside
// `SeptaskAIPreferencesPane`, the AI on this device page that every platform
// pushes from General (registry/settings.json `ai_preferences`).
struct SeptaskAIPreferencesSections: View {
  @AppStorage(AIPolicy.modeKey) private var mode: AIMode = .auto
  @State private var showExplainer = false
  @State private var aiStatus: OnDeviceAI.Status = .unknown
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL

  private static let reachSection = RegistrySettings.section("reach", page: RegistrySettings.PageID.aiPreferences)
  private static let explainer = RegistrySettings.itemBySurface["ai_explainer"]

  var body: some View {
    appleIntelligenceSection

    Section {
      ForEach(AIMode.allCases, id: \.self) { m in
        let unsupported = (m == .onDeviceOnly && aiStatus == .deviceNotEligible)
        Button { mode = m } label: {
          HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text(m.title).foregroundStyle(.primary)
              Text(m.blurb).font(.footnote).foregroundStyle(.secondary)
              if unsupported {
                Text("Not supported on this device.")
                  .font(.footnote).foregroundStyle(.orange)
              }
            }
            Spacer(minLength: 0)
            if mode == m { Image(systemName: "checkmark").foregroundStyle(.tint) }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unsupported)
        .opacity(unsupported ? 0.5 : 1)
      }
    } header: {
      Text(Self.reachSection?.header ?? "")
    } footer: {
      if let footer = Self.reachSection?.footer { Text(footer) }
    }

    Section {
      Button { showExplainer = true } label: {
        Label(Self.explainer?.label ?? "", systemImage: Self.explainer?.sfSymbol ?? "info.circle")
      }
      .sheet(isPresented: $showExplainer) { AIExplainerView() }
    }
    .onAppear { aiStatus = OnDeviceAI.status }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { aiStatus = OnDeviceAI.status }
    }
  }

  private var appleIntelligenceSection: some View {
    Section {
      HStack(spacing: 12) {
        Image(systemName: "apple.intelligence")
          .font(.title3)
          .foregroundStyle(.secondary)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(RegistrySettings.label(surface: "apple_intelligence_status"))
          Text(statusLabel).font(.footnote).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Circle().fill(statusColor).frame(width: 10, height: 10)
      }
      if aiStatus == .notEnabled {
        Button("Open Settings", action: openSystemSettings)
      }
    } footer: {
      Text(statusFooter)
    }
  }

  private var statusLabel: String {
    switch aiStatus {
    case .available: return "Available"
    case .notEnabled: return "Off"
    case .modelNotReady: return "Downloading"
    case .deviceNotEligible: return "Not supported"
    case .unknown: return "Unavailable"
    }
  }

  private var statusColor: Color {
    switch aiStatus {
    case .available: return .green
    case .notEnabled, .modelNotReady: return .orange
    case .deviceNotEligible, .unknown: return .gray
    }
  }

  private var statusFooter: String {
    switch aiStatus {
    case .available:
      return "The on-device model is ready. Task conversations and local filing help run privately on this device."
    case .notEnabled:
      return "Apple Intelligence is turned off. Enable it under Apple Intelligence & Siri in Settings to use on-device task conversations."
    case .modelNotReady:
      return "Apple Intelligence is on, but the on-device model is still downloading. Check back shortly."
    case .deviceNotEligible:
      return "This device can't run Apple Intelligence, so on-device task conversations aren't offered here. Everything else works normally."
    case .unknown:
      return "On-device intelligence is unavailable right now."
    }
  }

  private func openSystemSettings() {
    #if os(iOS)
    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    #elseif os(macOS)
    if let url = URL(string: "x-apple.systempreferences:") { openURL(url) }
    #endif
  }
}

struct SeptaskAIPreferencesPane: View {
  var body: some View {
    Form {
      SeptaskAIPreferencesSections()
    }
    .formStyle(.grouped)
    .navigationTitle(RegistrySettings.pageById[RegistrySettings.PageID.aiPreferences]?.title ?? "")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}
