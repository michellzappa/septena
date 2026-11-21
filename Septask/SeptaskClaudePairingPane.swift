import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Connect Claude pairing sections, driven by `registry/settings.json`
/// (`claude_pairing`, docs/SETTINGS_UX_SPEC.md). Rendered inline at the top of
/// macOS Settings ▸ AI & Agents (`desktopInline: true`), and as a 1-tap pushed
/// page on iOS (`SeptaskClaudePairingPane`).
struct SeptaskClaudePairingSections: View {
  private enum CopiedTarget: Equatable { case url, setupPrompt, starterPrompt }

  private var sync: TaskSyncEngine { .shared }
  @State private var pairCode = ""
  @State private var pairing = false
  @State private var pairResult: (text: String, failed: Bool)?
  @State private var copied: CopiedTarget?
  private static let connectorURL = "https://api.septena.app/mcp"
  private static let setupPrompt = "Set up Septena for me using https://septena.app/agents.md"
  private static let starterPrompt =
    "Set up my Septena areas, projects, and tasks by following https://api.septena.app/onboard.md"

  var body: some View {
    if !sync.signedIn {
      Section {
        Text("Sign in with Apple so Claude can connect to your tasks through your private Septena account.")
          .font(.callout)
          .foregroundStyle(.secondary)
        SeptaskSignInButton()
      } header: {
        Text("Sign in to connect Claude")
      }
    }

    Section {
      LabeledContent("Setup prompt") {
        Button(copied == .setupPrompt ? "Copied" : "Copy") {
          copyText(Self.setupPrompt, target: .setupPrompt)
        }
      }
      LabeledContent("First prompt") {
        Button(copied == .starterPrompt ? "Copied" : "Copy") {
          copyText(Self.starterPrompt, target: .starterPrompt)
        }
      }
      LabeledContent("Connector URL") {
        HStack {
          Text(Self.connectorURL)
            .font(.callout.monospaced())
            .textSelection(.enabled)
          Button(copied == .url ? "Copied" : "Copy") {
            copyText(Self.connectorURL, target: .url)
          }
        }
      }
      HStack {
        TextField("Code from the browser page", text: $pairCode)
          .font(.body.monospaced())
          .onSubmit(approvePairing)
          .disabled(!sync.signedIn)
        Button("Approve", action: approvePairing)
          .disabled(!sync.signedIn || pairing
                    || pairCode.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      if pairing {
        HStack {
          ProgressView().controlSize(.small)
          Text("Approving…").foregroundStyle(.secondary)
        }
      } else if let pairResult {
        Text(pairResult.text)
          .font(.caption)
          .foregroundStyle(pairResult.failed ? .red : .secondary)
      }
    } header: {
      Text("Connect Claude")
    } footer: {
      Text("Paste the setup prompt into Claude, or add the connector URL to Claude as a custom connector. When your browser shows a code, enter it here. Once connected, paste the first prompt to set up your areas, projects and tasks. Only enter a code from a browser window you opened yourself.")
    }
  }

  private func copyText(_ text: String, target: CopiedTarget) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
    copied = target
  }

  private func approvePairing() {
    let code = pairCode.trimmingCharacters(in: .whitespaces)
    guard sync.signedIn, !pairing, !code.isEmpty else { return }
    pairing = true
    pairResult = nil
    Task { @MainActor in
      defer { pairing = false }
      do {
        _ = try await TaskBackendClient.shared.approvePairing(code: code)
        pairCode = ""
        pairResult = ("Approved. Finish in your browser.", false)
        TaskNotices.completeStep(.connectAI)
      } catch TaskBackendError.http(_, let code) where code == "invalid_code" {
        pairResult = ("That code is wrong or has expired.", true)
      } catch TaskBackendError.http(_, let code) where code == "code_used" {
        pairResult = ("That code was already used.", true)
      } catch TaskBackendError.http(_, let code) where code == "too_many_attempts" {
        pairResult = ("Too many wrong codes. Try again in 10 minutes.", true)
      } catch {
        pairResult = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, true)
      }
    }
  }
}

struct SeptaskClaudePairingPane: View {
  var body: some View {
    Form {
      SeptaskClaudePairingSections()
    }
    .formStyle(.grouped)
    .navigationTitle("Connect Claude")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}
