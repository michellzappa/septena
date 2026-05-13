import SwiftUI

struct ServerConfigView: View {
  @EnvironmentObject var nav: NavigationState
  @EnvironmentObject var theme: SectionTheme
  @Environment(\.dismiss) private var dismiss

  @State private var serverURL: String = ""
  @State private var isChecking = false
  @State private var connectionStatus: String = ""

  var body: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ScreenTitle(icon: "server.rack", iconTint: Theme.inkSecondary, title: "Septena Server")

          Text("Point Engage at your Septena backend.")
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, Theme.hPadding)
            .padding(.bottom, Theme.sectionSpacing)

          // URL field
          fieldLabel("Server URL")
          TextField("http://100.74.150.55:7000", text: $serverURL)
            .font(.septenaTaskTitle)
            .foregroundStyle(Theme.inkPrimary)
            .autocapitalization(.none)
            .keyboardType(.URL)
            .textContentType(.URL)
            .padding(12)
            .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
              RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.border, lineWidth: 1)
            )
            .padding(.horizontal, Theme.hPadding)
            .padding(.bottom, 16)

          // Test + status
          Button { Task { await testConnection() } } label: {
            HStack(spacing: 8) {
              if isChecking {
                ProgressView().scaleEffect(0.8)
              } else {
                Image(systemName: "network").font(.system(size: 14))
              }
              Text("Test Connection").font(.septenaButton)
            }
            .foregroundStyle(theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
          }
          .disabled(isChecking || serverURL.isEmpty)
          .padding(.horizontal, Theme.hPadding)

          if !connectionStatus.isEmpty {
            Text(connectionStatus)
              .font(.septenaMeta)
              .foregroundStyle(connectionStatus.hasPrefix("✅") ? .green : Theme.overdueRed)
              .multilineTextAlignment(.center)
              .frame(maxWidth: .infinity)
              .padding(.top, 10)
              .padding(.horizontal, Theme.hPadding)
          }

          // Save
          Button { save() } label: {
            Text("Save")
              .font(.septenaButton)
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
          }
          .disabled(serverURL.isEmpty)
          .padding(.horizontal, Theme.hPadding)
          .padding(.top, Theme.sectionSpacing)

          Spacer(minLength: 24)

          Text("No auth — Septena is reachable on the tailnet.")
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.hPadding)
            .padding(.bottom, 24)
        }
      }
    .background(Theme.paperBackground)
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { serverURL = nav.serverURL }
  }

  @ViewBuilder
  private func fieldLabel(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: 11, weight: .semibold, design: .monospaced))
      .tracking(0.8)
      .foregroundStyle(Theme.inkSecondary)
      .padding(.horizontal, Theme.hPadding)
      .padding(.bottom, 6)
  }

  private func testConnection() async {
    isChecking = true
    connectionStatus = "Testing…"
    defer { isChecking = false }
    guard let url = URL(string: serverURL) else {
      connectionStatus = "❌ Invalid URL"; return
    }
    do {
      let testClient = SeptenaClient(baseURL: url)
      let result = try await testClient.ping()
      connectionStatus = "✅ \(result)"
    } catch {
      connectionStatus = "❌ \(error.localizedDescription)"
    }
  }

  private func save() {
    guard let url = URL(string: serverURL) else { return }
    nav.serverURL = serverURL
    ClientProvider.shared.update(baseURL: url)
    Task { await theme.refresh(from: ClientProvider.shared.client) }
    dismiss()
  }
}
