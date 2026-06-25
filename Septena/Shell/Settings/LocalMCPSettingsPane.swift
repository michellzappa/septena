#if os(macOS)
import SwiftUI

/// macOS-only Settings pane for the in-process local MCP server. Mirrors the
/// hosted gateway's tool surface but runs inside this app — so a local Claude
/// Code instance can read/write Septena over `127.0.0.1` with no web token and
/// no Cloudflare hop. Off by default.
///
/// See `LocalMCPServer` (SeptenaCore/MCP) for the transport + auth.
struct LocalMCPSettingsPane: View {
  @AppStorage(SettingsKey.localMcpEnabled) private var enabled = false
  @AppStorage(SettingsKey.localMcpToken) private var token = ""
  @AppStorage(MCPDefaultsKey.scope) private var scopeRaw = MCPAccessScope.thisMac.rawValue
  @AppStorage(MCPDefaultsKey.keepAlive) private var keepAlive = false

  private var port: UInt16 { LocalMCPServer.shared.port }
  private var scope: MCPAccessScope { MCPAccessScope(rawValue: scopeRaw) ?? .thisMac }

  /// This Mac's Tailscale IPv4, when the tailnet scope is active and Tailscale
  /// is up. Other tailnet devices dial this instead of 127.0.0.1.
  private var tailnetIP: String? { TailnetAddress.ipv4() }

  /// Host another device should connect to, given the scope.
  private var connectHost: String {
    if scope == .tailnet, let ip = tailnetIP { return ip }
    return "127.0.0.1"
  }

  /// The one-shot command to register this server with Claude Code, with the
  /// live token baked in. Copyable — same one-tap pattern as the gateway's
  /// connector-URL row.
  private var connectCommand: String {
    "claude mcp add --transport http septena-local "
      + "http://\(connectHost):\(port)/mcp "
      + "--header \"Authorization: Bearer \(token)\""
  }

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $enabled) {
          Label("MCP Server", systemImage: "server.rack")
        }
      } footer: {
        Text("Lets Claude Code on this Mac read and write your Septena data "
           + "directly through the app — no gateway, no token round-trip. "
           + "Listens on 127.0.0.1 only and requires the bearer token below.")
      }

      if enabled {
        Section {
          Picker("Access", selection: $scopeRaw) {
            ForEach(MCPAccessScope.allCases, id: \.rawValue) { s in
              Text(s.label).tag(s.rawValue)
            }
          }
          // When tailnet access is on, surface this Mac's tailnet address as a
          // first-class, shareable value — AirDrop/Message it to the other
          // device you want connecting. Choosing "My tailnet" above is the
          // toggle that exposes it; "This Mac only" keeps it hidden.
          if scope == .tailnet, let ip = tailnetIP {
            LabeledContent("Tailnet address") {
              HStack(spacing: 8) {
                Text("\(ip):\(port)")
                  .font(.caption.monospaced())
                  .textSelection(.enabled)
                ShareLink(item: "\(ip):\(port)") {
                  Image(systemName: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
              }
            }
          }
        } footer: {
          if scope == .tailnet {
            if let ip = tailnetIP {
              Text("Other devices on your tailnet can connect at \(ip):\(port). "
                 + "Local Wi-Fi and the public internet still can't — only "
                 + "loopback and Tailscale's 100.64.0.0/10 range are admitted.")
            } else {
              Text("Tailscale doesn't appear to be running — no 100.x address "
                 + "found. Start Tailscale, then reopen this pane. Only this Mac "
                 + "can connect until then.")
            }
          } else {
            Text("Only a Claude Code running on this Mac can connect.")
          }
        }

        Section {
          Toggle(isOn: $keepAlive) {
            Label("Keep serving after quit", systemImage: "powersleep")
          }
        } footer: {
          Text("Keep Septena running in the background after you press ⌘Q so it "
             + "keeps answering Claude Code, instead of quitting. The Dock icon "
             + "and menu bar stay; reopening brings the window back, and "
             + "⌥⌘Q always quits completely. Off by default.")
        }

        Section("Connect Claude Code") {
          VStack(alignment: .leading, spacing: 8) {
            Text(connectCommand)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
            HStack {
              Button {
                copy(connectCommand)
              } label: {
                Label("Copy command", systemImage: "doc.on.doc")
              }
              ShareLink(item: connectCommand) {
                Label("Share…", systemImage: "square.and.arrow.up")
              }
            }
          }
        }

        Section {
          LabeledContent("Token") {
            Text(token.isEmpty ? "—" : token)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
          Button("Rotate token", role: .destructive) {
            token = LocalMCPServer.regenerateToken()
          }
        } footer: {
          Text("Rotating invalidates the old token — re-run the command above "
             + "(or update the header) in Claude Code afterward.")
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: enabled) { _, on in
      if on {
        if token.isEmpty { token = LocalMCPServer.regenerateToken() }
        try? LocalMCPServer.shared.start()
      } else {
        LocalMCPServer.shared.stop()
      }
    }
  }

  private func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
  }
}
#endif
