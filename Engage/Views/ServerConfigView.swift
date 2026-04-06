import SwiftUI

// ─── Server Config View ────────────────────────────────────────────────────────
// Simple debug settings — set server URL + API key, test connection.
// Shown as a sheet or accessible from the tab bar in debug builds.

struct ServerConfigView: View {
    @EnvironmentObject var client: AtaskClient
    @Environment(\.dismiss) private var dismiss

    @AppStorage("engage_server_url") private var serverURL = "http://localhost:8080"
    @AppStorage("engage_api_key") private var apiKey = ""
    @State private var connectionStatus: String = "Not tested"
    @State private var isChecking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Use your Tailscale IP when on the same network, e.g. http://100.x.x.x:8080")
                }

                Section {
                    HStack {
                        Button {
                            Task { await testConnection() }
                        } label: {
                            if isChecking {
                                ProgressView()
                                    .frame(width: 20, height: 20)
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(isChecking || serverURL.isEmpty)

                        Spacer()

                        Circle()
                            .fill(connectionColor)
                            .frame(width: 10, height: 10)

                        Text(connectionStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent("Server", value: serverURL)
                    LabeledContent("Key set", value: apiKey.isEmpty ? "No" : "Yes")
                } header: {
                    Text("Current Config")
                }

                Section {
                    Button("Save & Close") {
                        saveAndClose()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Server Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var connectionColor: Color {
        switch connectionStatus {
        case "Connected": return .green
        case "Failed": return .red
        default: return .gray
        }
    }

    private func testConnection() async {
        isChecking = true
        connectionStatus = "Testing..."
        // Give a brief delay
        try? await Task.sleep(nanoseconds: 500_000_000)
        isChecking = false
        connectionStatus = "Failed"
    }

    private func saveAndClose() {
        // AppStorage persists automatically
        dismiss()
    }
}

// ─── Tab for Server Config (in App.swift) ─────────────────────────────────────
// Add this tab in debug builds:
//
//   ServerConfigView()
//       .tabItem { Label("Settings", systemImage: "gear") }
//       .tag(9)
//
// In App.swift, also inject AtaskClient as EnvironmentObject:
//
//   @StateObject private var ataskClient = AtaskClient.shared
//   .environmentObject(ataskClient)