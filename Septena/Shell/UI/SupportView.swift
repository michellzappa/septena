// Contact Support (ADR 0054, docs/SUPPORT_SPEC.md §4): the conversation, then
// the form. Shared by iPhone, iPad and Mac: a Settings page on every one, a
// sheet from the iPad Help menu, a window from the Mac Help menu. Copy comes
// from the registry (`surfaces.json` `support`).

import SwiftUI

struct SupportView: View {
  /// The Settings surface and navigation value (`settings.json` `contact_support`).
  static let surfaceID = "contact_support"
  /// The Mac window scene's id.
  static let windowID = "septask-support"

  @State private var center = SupportCenter.shared
  @State private var text = ""
  @State private var email = ""
  @State private var includeDiagnostics = false
  @FocusState private var messageFocused: Bool

  var body: some View {
    Form {
      Section {
        if center.messages.isEmpty {
          Text(RegistrySupport.noMessages)
            .foregroundStyle(.secondary)
        } else {
          ForEach(center.messages) { message in
            SupportMessageRow(message: message)
          }
        }
      }

      Section {
        Link(destination: RegistrySettings.helpURL) {
          HStack {
            Text(RegistrySupport.helpLink)
            Spacer()
            Image(systemName: "arrow.up.right")
              .imageScale(.small)
              .foregroundStyle(.tertiary)
          }
          .contentShape(Rectangle())
        }
      } footer: {
        Text(RegistrySupport.helpHint)
      }

      Section {
        TextField(RegistrySupport.messagePlaceholder, text: $text, axis: .vertical)
          .lineLimit(4...12)
          .focused($messageFocused)
          .accessibilityLabel(RegistrySupport.messageLabel)
          .onChange(of: text) { _, newValue in
            if newValue.count > SupportWire.messageMaxChars {
              text = String(newValue.prefix(SupportWire.messageMaxChars))
            }
            center.resetSendState()
          }
        if center.needsEmail {
          TextField(RegistrySupport.emailFieldLabel, text: $email)
            .textContentType(.emailAddress)
            #if os(iOS)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
        }
      } header: {
        Text(RegistrySupport.messageLabel)
      } footer: {
        if center.needsEmail { Text(RegistrySupport.emailDetail) }
      }

      Section {
        Toggle(RegistrySupport.diagnosticsLabel, isOn: $includeDiagnostics)
      } footer: {
        Text(RegistrySupport.diagnosticsDetail)
      }

      Section {
        Button {
          Task { await send() }
        } label: {
          HStack {
            Text(center.sendState == .sending ? RegistrySupport.sending : RegistrySupport.send)
            if center.sendState == .sending {
              Spacer()
              ProgressView().controlSize(.small)
            }
          }
        }
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
      } footer: {
        statusLine
      }
    }
    .formStyle(.grouped)
    .navigationTitle(RegistrySupport.title)
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .task {
      await center.refresh()
      await center.markRead()
    }
  }

  private var canSend: Bool {
    guard center.sendState != .sending else { return false }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return !center.needsEmail || !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  @ViewBuilder private var statusLine: some View {
    switch center.sendState {
    case .sent:
      Text(RegistrySupport.sent)
    case .failed(let reason):
      VStack(alignment: .leading, spacing: 4) {
        Text(reason).foregroundStyle(.red)
        Button(RegistrySupport.sendAgain) { Task { await send() } }
          .disabled(!canSend)
      }
    case .idle, .sending:
      EmptyView()
    }
  }

  private func send() async {
    let sent = await center.send(text: text, email: email, includeDiagnostics: includeDiagnostics)
    if sent {
      text = ""
      messageFocused = false
    }
  }
}

private struct SupportMessageRow: View {
  let message: SupportWire.Message

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(message.isReply ? (message.authorName.map { "\(RegistrySupport.fromSeptena) · \($0)" } ?? RegistrySupport.fromSeptena) : RegistrySupport.fromYou)
          .font(.septenaLabel)
          .foregroundStyle(message.isReply ? .primary : .secondary)
        Spacer()
        Text(Date(timeIntervalSince1970: message.createdAt / 1000), format: .dateTime.month(.abbreviated).day().hour().minute())
          .font(.septenaCaption)
          .foregroundStyle(.secondary)
      }
      Text(message.text)
        .textSelection(.enabled)
    }
    .padding(.vertical, 2)
  }
}
