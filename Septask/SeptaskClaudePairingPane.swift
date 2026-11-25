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
  private static let agentTools = RegistrySettings.section("agent_tools", page: RegistrySettings.PageID.claudePairing)
  private static let skills = RegistrySettings.itemBySurface["mcp_skills"]

  var body: some View {
    if !sync.signedIn {
      Section {
        Text(SeptaskSignIn.appleAvailable
             ? String(localized: "Sign in with Apple so Claude can connect to your tasks through your private Septena account.")
             : RegistrySettings.copy("claude_connector", "signInBody"))
          .font(.callout)
          .foregroundStyle(.secondary)
        SeptaskSignInButton()
      } header: {
        Text(RegistrySettings.copy("claude_connector", "signInHeader"))
      }
    }

    Section {
      LabeledContent(RegistrySettings.copy("claude_connector", "setupPrompt")) {
        Button(copied == .setupPrompt ? RegistrySettings.copy("claude_connector", "copied") : RegistrySettings.copy("claude_connector", "copy")) {
          copyText(Self.setupPrompt, target: .setupPrompt)
        }
      }
      LabeledContent(RegistrySettings.copy("claude_connector", "firstPrompt")) {
        Button(copied == .starterPrompt ? RegistrySettings.copy("claude_connector", "copied") : RegistrySettings.copy("claude_connector", "copy")) {
          copyText(Self.starterPrompt, target: .starterPrompt)
        }
      }
      LabeledContent(RegistrySettings.copy("claude_connector", "connectorUrl")) {
        HStack {
          Text(Self.connectorURL)
            .font(.callout.monospaced())
            .textSelection(.enabled)
          Button(copied == .url ? RegistrySettings.copy("claude_connector", "copied") : RegistrySettings.copy("claude_connector", "copy")) {
            copyText(Self.connectorURL, target: .url)
          }
        }
      }
      SeptaskPairingCodeField()
    } header: {
      Text("Connect Claude")
    } footer: {
      Text(RegistrySettings.copy("claude_connector", "footer"))
    }

    // Agent tools (moved from About ▸ Advanced, 2026-11-22).
    Section {
      NavigationLink {
        TasksSkillPane()
      } label: {
        Label(Self.skills?.label ?? "", systemImage: Self.skills?.sfSymbol ?? "book.closed")
      }
    } header: {
      Text(Self.agentTools?.header ?? "")
    } footer: {
      if let footer = Self.agentTools?.footer { Text(footer) }
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

/// The code field for a sign-in code, on Settings ▸ Connect Claude and in the
/// first run. Continue opens `SeptaskApproveSignInFlow`, which looks the code
/// up and shows who asks before the user approves; so a device code typed
/// here reads "Sign in on <device>?", never "Connect Claude". `onApproved`
/// runs after an approval of either kind.
struct SeptaskPairingCodeField: View {
  var onApproved: (() -> Void)?
  private var sync: TaskSyncEngine { .shared }
  @State private var pairCode = ""
  @State private var reviewing: ReviewedCode?

  private struct ReviewedCode: Identifiable {
    let code: String
    var id: String { code }
  }

  var body: some View {
    HStack {
      TextField(RegistrySettings.copy("claude_connector", "codePlaceholder"), text: $pairCode)
        .font(.body.monospaced())
        .onSubmit(review)
        .disabled(!sync.signedIn)
      Button("Continue", action: review)
        .disabled(!sync.signedIn || SeptaskApproveSignInFlow.normalized(pairCode) == nil)
      if sync.signedIn {
        SeptaskScanCodeButton { scanned in
          reviewing = ReviewedCode(code: scanned)
        }
        .labelStyle(.iconOnly)
      }
    }
    .sheet(item: $reviewing) { reviewed in
      SeptaskApproveSignInFlow(initialCode: reviewed.code) { _ in
        pairCode = ""
        onApproved?()
      }
    }
  }

  private func review() {
    guard sync.signedIn, let code = SeptaskApproveSignInFlow.normalized(pairCode) else { return }
    reviewing = ReviewedCode(code: code)
  }
}

struct SeptaskClaudePairingPane: View {
  var body: some View {
    Form {
      SeptaskClaudePairingSections()
    }
    .formStyle(.grouped)
    .navigationTitle(RegistrySettings.pageById[RegistrySettings.PageID.claudePairing]?.title ?? "")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}
