import SwiftUI

// The single global "how far AI may reach" dial (`AIMode`) + a link to the
// explainer, and a macOS-only developer provider override. Per-function model
// config is deliberately NOT offered — the router picks per step by capability;
// this is the user's one policy lever. Model: SeptenaCore/AIPolicy.swift.
struct AISettingsPane: View {
  @AppStorage(AIPolicy.modeKey) private var mode: AIMode = .auto
  #if os(macOS)
  @AppStorage(AIPolicy.devForceProviderKey) private var devForce = ""
  #endif
  @State private var showExplainer = false

  var body: some View {
    Form {
      Section {
        ForEach(AIMode.allCases, id: \.self) { m in
          Button { mode = m } label: {
            HStack(alignment: .top, spacing: 12) {
              VStack(alignment: .leading, spacing: 2) {
                Text(m.title).foregroundStyle(.primary)
                Text(m.blurb).font(.footnote).foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
              if mode == m { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
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
  }
}
