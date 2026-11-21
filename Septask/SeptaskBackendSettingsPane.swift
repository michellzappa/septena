import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Settings ▸ About ▸ Advanced ▸ Task backend, on Mac and iOS. Septask is
/// backend-only (docs/SEPTASK_BACKEND.md §9, phase 4): there is no iCloud
/// switch and no copy or move-back action any more. This pane shows the
/// sign-in and sync state (the same section as Settings ▸ Account), what
/// the backend refused, and pairs a Claude connector.
///
/// Why no "Copy tasks to backend": it read the CloudKit mirror and needed a
/// running CloudKit engine. The sync engine already sends every local row
/// the backend does not hold (its reconcile diffs each row against what the
/// backend last confirmed), so a re-upload action would add nothing.
struct SeptaskBackendSettingsPane: View {
  private enum CopiedTarget: Equatable { case url, setupPrompt, starterPrompt }

  private var sync: TaskSyncEngine { .shared }
  /// MCP connector pairing.
  @State private var pairCode = ""
  @State private var pairing = false
  @State private var pairResult: (text: String, failed: Bool)?
  @State private var copied: CopiedTarget?
  private static let connectorURL = "https://api.septena.app/mcp"
  private static let setupPrompt = "Set up Septena for me using https://septena.app/agents.md"
  private static let starterPrompt =
    "Set up my Septena areas, projects, and tasks by following https://api.septena.app/onboard.md"

  var body: some View {
    Form {
      SeptaskSyncAccountSection()
      connectorSection
      if !sync.issues.isEmpty { issuesSection }
    }
    .formStyle(.grouped)
    .navigationTitle("Task backend")
  }

  private var connectorSection: some View {
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
      Text("Connect your AI")
    } footer: {
      Text("Paste the setup prompt into your AI assistant, or add the connector URL manually. When your browser shows a code, enter it here. Once connected, paste the first prompt to populate your areas, projects, and tasks. Only enter a code from a browser window you opened yourself.")
    }
  }

  private var issuesSection: some View {
    Section {
      ForEach(sync.issues.suffix(20).reversed(), id: \.key) { issue in
        VStack(alignment: .leading, spacing: 2) {
          Text("\(issue.entity.rawValue) \(issue.id)")
            .font(.caption.monospaced())
          Text(issue.reason)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Button("Clear") { sync.clearIssues() }
    } header: {
      Text("Not synced")
    } footer: {
      Text("Changes the backend refused, newest first. The backend kept its own version of each.")
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
