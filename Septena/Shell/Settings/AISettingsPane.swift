import SwiftUI
#if os(iOS)
import UIKit
#endif

// The single global "how far AI may reach" dial (`AIMode`) + a link to the
// explainer, and a macOS-only developer provider override. Per-function model
// config is deliberately NOT offered — the router picks per step by capability;
// this is the user's one policy lever. Model: SeptenaCore/AIPolicy.swift.
//
// Also the status board for the on-device engine: Apple Intelligence is a
// capability the app can only observe, never request, so this row (not
// Integrations, which is for connectable data sources) is where the user
// learns whether it works here and why not. Availability is a live system
// property (model downloads finish, the user flips the toggle), so it's
// re-sampled on appear and on scene activation rather than cached.
struct AISettingsPane: View {
  @AppStorage(AIPolicy.modeKey) private var mode: AIMode = .auto
  #if os(macOS)
  @AppStorage(AIPolicy.devForceProviderKey) private var devForce = ""
  #endif
  @State private var showExplainer = false
  @State private var aiStatus: OnDeviceAI.Status = .unknown
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

      #if os(macOS)
      Section {
        Picker("Force provider", selection: $devForce) {
          Text("Off (use the mode above)").tag("")
          ForEach(AIProviderKind.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
        }
      } header: {
        Text("Developer")
      } footer: {
        Text("Pins every reasoning step to one provider — for testing only. Leave Off in normal use.")
      }
      #endif
    }
    .sheet(isPresented: $showExplainer) { AIExplainerView() }
    .onAppear { aiStatus = OnDeviceAI.status }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { aiStatus = OnDeviceAI.status }
    }
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
