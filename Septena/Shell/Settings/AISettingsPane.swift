import SwiftUI
#if os(iOS)
import UIKit
#endif

// The unified "Claude & AI" pane: the one place the user answers "what can AI
// (and Claude) do with my data?" Combines the global reach dial (`AIMode`) and
// on-device status board with the connections that carry data to a model — the
// hosted Claude gateway and the macOS local MCP server — plus the MCP skill
// briefs. The macOS developer provider-override moved to About ▸ Advanced.
//
// Apple Intelligence is a capability the app can only observe, never request,
// so this pane is where the user learns whether it works here and why not.
// Availability is a live system property (model downloads finish, the user
// flips the toggle), so it's re-sampled on appear and on scene activation.
struct ClaudeAISettingsPane: View {
  @AppStorage(AIPolicy.modeKey) private var mode: AIMode = .auto
  @State private var showExplainer = false
  @State private var aiStatus: OnDeviceAI.Status = .unknown
  @State private var claudeProvider = ClaudeGatewayProvider.shared
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL

  var body: some View {
    Form {
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
        Text("How far AI may reach")
      } footer: {
        Text("Septena never runs AI on your data and never reads it — the intelligence is your own (Apple on-device, Private Cloud Compute, or your Claude). This only sets how far a request may go.")
      }

      Section {
        Button { showExplainer = true } label: {
          Label("How AI helps with your tasks", systemImage: "info.circle")
        }
      }

      connectionsSection
      skillsSection
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showExplainer) { AIExplainerView() }
    .onAppear { aiStatus = OnDeviceAI.status }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { aiStatus = OnDeviceAI.status }
    }
  }

  // MARK: - Connections (Claude gateway + local MCP)

  private var connectionsSection: some View {
    Section {
      NavigationLink {
        ClaudeGatewayDetail()
          .navigationTitle("Claude")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
      } label: {
        HStack {
          Label {
            Text("Claude")
          } icon: {
            Image("ClaudeMark")
              .renderingMode(.template)
              .resizable()
              .scaledToFit()
              .frame(width: 20, height: 20)
          }
          .foregroundStyle(.primary)
          Spacer()
          Text(claudeProvider.isEnabled ? "Connected" : "Connect")
            .font(.subheadline)
            .foregroundStyle(claudeProvider.isEnabled ? Color.green : .secondary)
        }
      }

      // Septask compiles no SettingsView destination graph — link the pane
      // directly (macOS only; the pane type itself is macOS-gated, and the
      // iOS discoverability row needs the full app's destination handling).
      #if SEPTASK
      #if os(macOS)
      NavigationLink {
        LocalMCPSettingsPane()
      } label: {
        Label("MCP Server", systemImage: "server.rack")
      }
      #endif
      #else
      NavigationLink(value: SettingsView.SettingsDestination.localMcp) {
        Label("MCP Server", systemImage: "server.rack")
      }
      #endif
    } header: {
      Text("Connections")
    } footer: {
      #if os(macOS)
      Text("Claude reads and writes your data through the hosted gateway at mcp.septena.app. The MCP Server lets Claude Code on this Mac connect directly, with no gateway hop.")
      #else
      Text("Claude reads and writes your data through the hosted gateway at mcp.septena.app. MCP Server is shown here for discoverability, but hosting it requires the Mac app.")
      #endif
    }
  }

  // Septena's pane renders every section's brief via the SettingsView
  // destination graph; Septask compiles no SectionRegistry, so it links the
  // task brief directly (TasksSkill, shared with TasksPlugin).
  @ViewBuilder
  private var skillsSection: some View {
    #if SEPTASK
    Section {
      NavigationLink {
        TasksSkillPane()
      } label: {
        Label("MCP Skills", systemImage: "book.closed")
      }
    } footer: {
      Text("The brief that teaches a model how to use your tasks through the connection — tools, conventions, examples.")
    }
    #else
    Section {
      NavigationLink(value: SettingsView.SettingsDestination.skills) {
        Label("MCP Skills", systemImage: "book.closed")
      }
    } footer: {
      Text("The briefs that teach a model how to use each section through the connection — tools, conventions, examples.")
    }
    #endif
  }

  // MARK: - Apple Intelligence status

  private var appleIntelligenceSection: some View {
    Section {
      HStack(spacing: 12) {
        Image(systemName: "apple.intelligence")
          .font(.title3)
          .foregroundStyle(.secondary)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text("Apple Intelligence")
          Text(statusLabel).font(.footnote).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Circle().fill(statusColor).frame(width: 10, height: 10)
      }
      if aiStatus == .notEnabled {
        Button("Open Settings", action: openSystemSettings)
      }
    } header: {
      Text("On-device intelligence")
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
      return "The on-device model is ready. Coaches, exercises, and the welcome line run privately on this device."
    case .notEnabled:
      return "Apple Intelligence is turned off. Enable it under Apple Intelligence & Siri in Settings to use coaches and exercises."
    case .modelNotReady:
      return "Apple Intelligence is on, but the on-device model is still downloading. Check back shortly."
    case .deviceNotEligible:
      return "This device can't run Apple Intelligence, so coach chat and exercises aren't offered here. Everything else works normally."
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
