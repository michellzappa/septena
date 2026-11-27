import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Connect an Agent sections, driven by `registry/settings.json`
/// (`claude_pairing`, docs/SETTINGS_UX_SPEC.md). Rendered as a pushed subpage
/// on every platform (iOS, macOS, Web, Android).
struct SeptaskClaudePairingSections: View {
  private enum CopiedTarget: Equatable { case url, setupPrompt, starterPrompt }

  private var sync: TaskSyncEngine { .shared }
  @State private var copied: CopiedTarget?
  private static let connectorURL = "https://api.septena.app/mcp"
  // One copy of each prompt, shared with the first run (`registry/surfaces.json`).
  private static let setupPrompt = RegistryFirstRun.setupPrompt
  private static let starterPrompt = RegistryFirstRun.firstPrompt
  private static let connectorSection = RegistrySettings.section("connector", page: RegistrySettings.PageID.claudePairing)
  private static let agentTools = RegistrySettings.section("agent_tools", page: RegistrySettings.PageID.claudePairing)
  private static let skills = RegistrySettings.itemBySurface["mcp_skills"]

  var body: some View {
    if !sync.signedIn {
      Section {
        Text(RegistrySettings.copy("claude_connector", "signInBody"))
          .font(.callout)
          .foregroundStyle(.secondary)
        SeptaskSignInButton()
      } header: {
        Text(RegistrySettings.copy("claude_connector", "signInHeader"))
      }
    }

    Section {
      copyRow(
        title: RegistrySettings.copy("claude_connector", "connectorUrl"),
        subtitle: Self.connectorURL,
        monospacedSubtitle: true,
        target: .url,
        value: Self.connectorURL
      )
      copyRow(
        title: RegistrySettings.copy("claude_connector", "setupPrompt"),
        subtitle: RegistrySettings.copy("claude_connector", "setupPromptDetail"),
        monospacedSubtitle: false,
        target: .setupPrompt,
        value: Self.setupPrompt
      )
      copyRow(
        title: RegistrySettings.copy("claude_connector", "firstPrompt"),
        subtitle: RegistrySettings.copy("claude_connector", "firstPromptDetail"),
        monospacedSubtitle: false,
        target: .starterPrompt,
        value: Self.starterPrompt
      )
    } header: {
      if let header = Self.connectorSection?.header { Text(header) }
    } footer: {
      Text(RegistrySettings.copy("claude_connector", "connectorUrlDetail"))
    }

    Section {
      SeptaskPairingCodeField()
    } header: {
      Text(RegistrySettings.copy("claude_connector", "approveHeader"))
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

  private func copyRow(
    title: String,
    subtitle: String,
    monospacedSubtitle: Bool,
    target: CopiedTarget,
    value: String
  ) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(subtitle)
          .font(monospacedSubtitle ? .caption.monospaced() : .caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer(minLength: 12)
      Button(copied == target ? RegistrySettings.copy("claude_connector", "copied") : RegistrySettings.copy("claude_connector", "copy")) {
        copyText(value, target: target)
      }
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

/// The code field for a connection code, on Settings ▸ Connect an Agent and in
/// the first run. Continue opens `SeptaskApproveSignInFlow`, which looks the
/// code up and shows who asks before the user approves. `onApproved` runs after
/// an approval of either kind.
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
    HStack(spacing: 10) {
      TextField(RegistrySettings.copy("claude_connector", "codePlaceholder"), text: $pairCode)
        .font(.body.monospaced())
        .autocorrectionDisabled()
        #if os(macOS)
        .textFieldStyle(.roundedBorder)
        #else
        .textInputAutocapitalization(.characters)
        #endif
        .onSubmit(review)
        .disabled(!sync.signedIn)
      Button(RegistrySettings.copy("sign_in_approval", "continue"), action: review)
        .disabled(!sync.signedIn || SeptaskApproveSignInFlow.normalized(pairCode) == nil)
      #if os(iOS)
      if sync.signedIn {
        SeptaskScanCodeButton { scanned in
          reviewing = ReviewedCode(code: scanned)
        }
        .labelStyle(.iconOnly)
      }
      #endif
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
