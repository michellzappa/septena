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
  @State private var copied: CopiedTarget?
  private static let connectorURL = "https://api.septena.app/mcp"
  // One copy of each prompt, shared with the first run (`registry/surfaces.json`).
  private static let setupPrompt = RegistryFirstRun.setupPrompt
  private static let starterPrompt = RegistryFirstRun.firstPrompt

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
      SeptaskPairingCodeField()
    } header: {
      Text("Connect Claude")
    } footer: {
      Text("Paste the setup prompt into Claude, or add the connector URL to Claude as a custom connector. When your browser shows a code, enter it here. Once connected, paste the first prompt to set up your areas, projects and tasks. Only enter a code from a browser window you opened yourself.")
    }
  }

  private func copyText(_ text: String, target: CopiedTarget) {
    SeptaskClipboard.copy(text)
    copied = target
  }
}

/// Puts text on the system pasteboard, on both platforms.
@MainActor
enum SeptaskClipboard {
  static func copy(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
  }
}

/// The pairing code Claude's browser page shows, approved through the task
/// backend. Used by Settings ▸ Connect Claude and by the first run, so the
/// approval and its error copy exist once. `onApproved` runs after success.
struct SeptaskPairingCodeField: View {
  var onApproved: (() -> Void)?
  private var sync: TaskSyncEngine { .shared }
  @State private var pairCode = ""
  @State private var pairing = false
  @State private var pairResult: (text: String, failed: Bool)?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
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
    }
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
        onApproved?()
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
