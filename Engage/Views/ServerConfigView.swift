import SwiftUI
import Combine

struct ServerConfigView: View {
    @EnvironmentObject var nav: NavigationState
    @EnvironmentObject var client: AtaskClient

    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var isChecking = false
    @State private var connectionStatus: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Configure Server")
                        .font(.title2).fontWeight(.semibold)
                    Text("Point the app to your Atask backend")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                // Form fields
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server URL")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("http://localhost:8080", text: $serverURL)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("atk_...", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .textContentType(.password)
                    }
                }
                .padding(.horizontal, 24)

                // Connection test
                VStack(spacing: 12) {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            if isChecking {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "network")
                            }
                            Text("Test Connection")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(isChecking || serverURL.isEmpty || apiKey.isEmpty)

                    if !connectionStatus.isEmpty {
                        Text(connectionStatus)
                            .font(.caption)
                            .foregroundStyle(connectionStatus.contains("OK") ? .green : .red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)

                // Save button
                Button {
                    save()
                } label: {
                    Text("Save")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                        .fontWeight(.medium)
                }
                .disabled(serverURL.isEmpty || apiKey.isEmpty)
                .padding(.horizontal, 24)

                Spacer()

                // Footer hint
                Text("The API key is created in the Atask dashboard or via the CLI")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        nav.showingServerConfig = false
                    }
                }
            }
            .onAppear {
                serverURL = nav.serverURL ?? "http://localhost:8080"
                apiKey = nav.apiKey ?? ""
            }
        }
    }

    private func testConnection() async {
        isChecking = true
        connectionStatus = "Testing..."
        do {
            let baseURL = URL(string: serverURL)!
            let testClient = AtaskClient(baseURL: baseURL, apiKey: apiKey)
            let result = try await testClient.ping()
            connectionStatus = "✅ \(result)"
        } catch {
            connectionStatus = "❌ \(error.localizedDescription)"
        }
        isChecking = false
    }

    private func save() {
        nav.serverURL = serverURL
        nav.apiKey = apiKey
        ClientProvider.shared.update(baseURL: URL(string: serverURL)!, apiKey: apiKey)
        nav.showingServerConfig = false
    }
}
