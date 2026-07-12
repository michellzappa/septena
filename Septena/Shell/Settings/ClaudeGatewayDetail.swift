// Claude gateway connect/status/disconnect — extracted from
// IntegrationsSettingsPane.swift so shells that don't compile the full
// Integrations surface (Septask) can offer the Claude connection — see
// docs/SEPTASK.md.

import SwiftUI

// MARK: - Claude Gateway Detail

/// Connect / status / disconnect for the Septena MCP gateway. "Connect"
/// mints a CloudKit Web Services token and pushes it to mcp.septena.app;
/// the app then re-mints on foreground so Claude keeps working without
/// the user re-authorizing every ~8h. The gateway holds only the rotating
/// token, never the user's data.
struct ClaudeGatewayDetail: View {
  @State private var provider = ClaudeGatewayProvider.shared
  @State private var urlCopied = false
  @State private var isTesting = false
  @State private var testResult: ClaudeGatewayProvider.ConnectionTestResult?

  /// The exact custom-connector address Claude expects (the JSON-RPC MCP
  /// transport endpoint). NOT the bare domain — Claude needs the `/mcp` path.
  private static let connectorURL = "https://mcp.septena.app/mcp"

  var body: some View {
    Form {
      Section {
        if provider.isEnabled {
          Button("Disconnect", role: .destructive) {
            provider.disconnect()
          }
        } else {
          Button("Connect Claude") {
            Task { await provider.connect() }
          }
        }
      } footer: {
        Text("Connecting lets Claude (at claude.ai or in the Claude app) read and write your Septena data via the MCP connector. Your data stays in iCloud — the gateway only relays a short-lived access token, which this app refreshes automatically. Use the address below to add the connector in Claude.")
      }

      Section {
        Button {
          SkillCopy.copy(Self.connectorURL)
          withAnimation { urlCopied = true }
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { urlCopied = false }
          }
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "link").font(.body).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
              Text("Connector address")
              Text(Self.connectorURL)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: urlCopied ? "checkmark.circle.fill" : "doc.on.doc")
              .foregroundStyle(urlCopied ? .green : .secondary)
          }
        }
        .buttonStyle(.plain)
      } header: {
        Text("Add to Claude")
      } footer: {
        Text("In Claude — claude.ai → Settings → Connectors, or the Claude app — add a custom connector and paste this address. You'll be asked to sign in with your Apple ID once to authorize access to your private iCloud data.")
      }

      if provider.isEnabled {
        Section {
          HStack {
            Label("Status", systemImage: "antenna.radiowaves.left.and.right")
            Spacer()
            Text(provider.connectionDisplayState.label)
              .foregroundStyle(claudeConnectionStatusColor(provider.connectionDisplayState))
          }
          if let last = provider.lastRefreshAt {
            ClaudeConnectionTimer(lastRefreshAt: last, dueAt: provider.nudgeFireDate)
          } else {
            HStack {
              Label("Last authenticated", systemImage: "clock.arrow.circlepath")
              Spacer()
              Text("Never").foregroundStyle(.secondary)
            }
          }
          Button {
            Task { await provider.refreshNow() }
          } label: {
            HStack {
              Label("Reauthenticate", systemImage: "lock.rotation")
              Spacer()
              if provider.isRefreshing { ProgressView().controlSize(.small) }
            }
          }
          .disabled(provider.isRefreshing)
          Button {
            Task {
              isTesting = true
              testResult = await provider.testConnection()
              isTesting = false
            }
          } label: {
            HStack {
              Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
              Spacer()
              if isTesting {
                ProgressView().controlSize(.small)
              } else if let testResult {
                Text(testResultLabel(testResult))
                  .font(.caption)
                  .foregroundStyle(testResultColor(testResult))
              }
            }
          }
          .disabled(isTesting)
          if let err = provider.lastError {
            Text(err)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("Connection")
        }
      }

      Section {
        explainerRow(icon: "link",
                     title: "A small relay",
                     text: "Claude talks to Septena through a connector at mcp.septena.app. Add it in Claude (claude.ai or the Claude app) using that address.")
        explainerRow(icon: "lock.icloud",
                     title: "Your data stays private",
                     text: "Reads and writes go straight to your own private iCloud database. The relay never stores your data — it only passes a short-lived access token through.")
        explainerRow(icon: "text.bubble",
                     title: "Ask in plain language",
                     text: "Claude can read and log your tasks, habits, supplements, meals, training and more, just by you asking.")
        explainerRow(icon: "arrow.triangle.2.circlepath",
                     title: "Syncs everywhere",
                     text: "Anything Claude logs shows up across all your devices automatically.")
      } header: {
        Text("How it works")
      } footer: {
        Text("Good to know: Apple only issues short-lived keys for private iCloud data — a few hours, with no server-side renewal. So the app refreshes the connection automatically when you open it, and the “Keep Claude connected” reminder nudges you before it lapses. If it does lapse, Claude simply asks you to open either app to refresh — you won't need to reconnect from claude.ai, and it resumes on its own. Refreshing happens on iPhone and Mac only, not the watch.")
      }
    }
    .formStyle(.grouped)
  }

  private func testResultLabel(_ result: ClaudeGatewayProvider.ConnectionTestResult) -> String {
    switch result {
    case .valid: return "Valid"
    case .expired: return "Expired"
    case .inconclusive: return "Couldn’t tell — offline?"
    }
  }

  private func testResultColor(_ result: ClaudeGatewayProvider.ConnectionTestResult) -> Color {
    switch result {
    case .valid: return .green
    case .expired: return .orange
    case .inconclusive: return .secondary
    }
  }

  @ViewBuilder
  private func explainerRow(icon: String, title: String, text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(width: 24, alignment: .center)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.medium))
        Text(text).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }
}

// Live "time since last connected" + countdown to the auto-refresh horizon.
// `TimelineView` ticks the labels without any manual timer; it stops when the
// pane is offscreen. The "due" line keys off `nudgeFireDate` (lastRefreshAt +
// ~7h) — the same horizon that flips `needsReauth` and arms the reconnect
// nudge — so the number the user sees here matches what the app acts on.
private struct ClaudeConnectionTimer: View {
  let lastRefreshAt: Date
  let dueAt: Date?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { ctx in
      let now = ctx.date
      HStack(alignment: .firstTextBaseline) {
        Label("Connected", systemImage: "clock.arrow.circlepath")
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text("\(Self.compact(now.timeIntervalSince(lastRefreshAt))) ago")
            .foregroundStyle(.secondary)
            .monospacedDigit()
          dueLine(now: now)
        }
      }
    }
  }

  @ViewBuilder
  private func dueLine(now: Date) -> some View {
    if let dueAt {
      let remaining = dueAt.timeIntervalSince(now)
      if remaining > 0 {
        Text("auto-refresh in \(Self.compact(remaining))")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else {
        Text("refresh recommended")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  /// "2h 14m", "46m 03s", "12s" — drops to finer units as the value shrinks so
  /// the trailing digits visibly tick.
  static func compact(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return String(format: "%dm %02ds", m, s) }
    return "\(s)s"
  }
}

func claudeConnectionStatusColor(_ state: ClaudeGatewayProvider.ConnectionDisplayState) -> Color {
  switch state {
  case .connected: return .green
  case .disconnected: return .secondary
  case .reconnectNeeded, .needsAttention: return .orange
  }
}
