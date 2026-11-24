import SwiftUI

/// Approving a sign-in code (ADR 0016). One flow for both kinds of code, so the
/// user always sees who asks and what they get before anything is approved:
///   - a **device** code: a new phone, tablet or computer signs in to this
///     account (it gets a full app session);
///   - a **connector** code: Claude gets read and write access to the tasks.
/// Enter the code, the app looks it up (`POST /v1/pair/inspect`), the user
/// confirms, then the app approves it for exactly that kind
/// (`POST /v1/pair/approve`). Used by Settings ▸ Account, Settings ▸ Connect
/// Claude and the first run.
struct SeptaskApproveSignInFlow: View {
  /// Starts the lookup at once when the caller already has the code.
  var initialCode: String = ""
  var onApproved: ((BackendPairingRequest.Kind) -> Void)?

  @Environment(\.dismiss) private var dismiss
  @State private var code = ""
  @State private var step: Step = .enter
  /// Connector codes: the name the user gives the agent, and the agent it
  /// replaces (a connection id; nil = a new agent).
  @State private var agentName = ""
  @State private var replaces: String?
  private static let namePrompt = RegistryPrompts.text["nameAgent"]
  private static let replacesPrompt = RegistryPrompts.fixed["agentReplaces"]

  private enum Step: Equatable {
    case enter
    case checking
    case confirm(BackendPairingRequest, approving: Bool)
    case done(BackendPairingRequest)
    case failed(String)
  }

  var body: some View {
    NavigationStack {
      Form { content }
        .formStyle(.grouped)
        .navigationTitle("Approve a sign-in")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(isDone ? "Done" : "Cancel") { dismiss() }
          }
        }
    }
    #if os(macOS)
    .frame(minWidth: 440, minHeight: 380)
    #endif
    .task {
      guard !initialCode.isEmpty, step == .enter else { return }
      code = initialCode
      await check()
    }
  }

  private var isDone: Bool {
    if case .done = step { return true }
    return false
  }

  @ViewBuilder
  private var content: some View {
    switch step {
    case .enter:
      Section {
        TextField("ABCD-EFGH", text: $code)
          .font(.title2.monospaced())
          .multilineTextAlignment(.center)
          .autocorrectionDisabled()
          #if os(iOS)
          .textInputAutocapitalization(.characters)
          #endif
          .onSubmit { Task { await check() } }
      } footer: {
        Text("Enter the code from the other device. If you're connecting Claude, the code is in your browser.")
      }
      Section {
        Button("Continue") { Task { await check() } }
          .disabled(Self.normalized(code) == nil)
      }

    case .checking:
      Section {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Checking the code…").foregroundStyle(.secondary)
        }
      }

    case .confirm(let request, let approving):
      Section {
        RequestSummary(request: request)
      } footer: {
        Text("Only approve a code you started yourself. Septena never asks for a code by email, text or phone call.")
      }
      if request.kind == .connector {
        agentSection(approving: approving)
      }
      Section {
        if approving {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Approving…").foregroundStyle(.secondary)
          }
        } else {
          Button("Approve") { Task { await approve(request) } }
            .fontWeight(.semibold)
          Button("Don't approve", role: .cancel) { dismiss() }
        }
      }

    case .done(let request):
      Section {
        VStack(spacing: 10) {
          Image(systemName: "checkmark.circle.fill")
            .font(.largeTitle)
            .foregroundStyle(.tint)
          Text(Self.doneText(for: request))
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
      }

    case .failed(let message):
      Section {
        Text(message).foregroundStyle(.red)
      }
      Section {
        Button("Try another code") {
          code = ""
          step = .enter
        }
      }
    }
  }

  /// The agent's name, and the agent it replaces. Devices and agents are
  /// separate lists; only an agent gets a name here.
  @ViewBuilder
  private func agentSection(approving: Bool) -> some View {
    Section {
      TextField(Self.namePrompt?.placeholder ?? "", text: $agentName)
        .disabled(approving)
      let agents = AgentRoster.shared.agents
      if !agents.isEmpty {
        Picker(selection: $replaces) {
          Text(Self.replacesPrompt?.options.first?.title ?? "").tag(String?.none)
          ForEach(agents) { agent in
            Text(agent.displayName).tag(String?.some(agent.id))
          }
        } label: {
          Text(Self.replacesPrompt?.title ?? "")
        }
        .disabled(approving)
      }
    } header: {
      Text(Self.namePrompt?.title ?? "")
    } footer: {
      if !AgentRoster.shared.agents.isEmpty, let message = Self.replacesPrompt?.message {
        Text(message)
      }
    }
  }

  // MARK: - Actions

  private func check() async {
    guard let normalized = Self.normalized(code) else { return }
    step = .checking
    do {
      let request = try await TaskBackendClient.shared.inspectPairing(code: normalized)
      code = normalized
      if request.kind == .connector {
        agentName = request.client
        replaces = nil
        await AgentRoster.shared.refresh()
      }
      step = .confirm(request, approving: false)
    } catch {
      step = .failed(Self.message(for: error))
    }
  }

  private func approve(_ request: BackendPairingRequest) async {
    step = .confirm(request, approving: true)
    do {
      try await TaskBackendClient.shared.approvePairing(
        code: code,
        kind: request.kind,
        agentName: request.kind == .connector ? agentName : nil,
        replaces: request.kind == .connector ? replaces : nil
      )
      if request.kind == .connector {
        TaskNotices.completeStep(.connectAI)
        await AgentRoster.shared.refresh()
      }
      step = .done(request)
      onApproved?(request.kind)
    } catch {
      step = .failed(Self.message(for: error))
    }
  }

  // MARK: - Copy

  static func doneText(for request: BackendPairingRequest) -> String {
    switch request.kind {
    case .device: return String(localized: "\(request.client) is signed in.")
    case .connector: return String(localized: "Claude is connected. Go back to your browser to finish.")
    }
  }

  static func message(for error: Error) -> String {
    switch error {
    case TaskBackendError.http(_, let code) where code == "invalid_code":
      return String(localized: "That code is wrong or has expired.")
    case TaskBackendError.http(_, let code) where code == "code_used":
      return String(localized: "That code was already used.")
    case TaskBackendError.http(_, let code) where code == "too_many_attempts":
      return String(localized: "Too many wrong codes. Try again in 10 minutes.")
    default:
      return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  /// Uppercases and drops spaces and dashes (the backend's `normalizePairCode`).
  /// Nil unless the result is 8 characters.
  static func normalized(_ input: String) -> String? {
    let code = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    return code.count == 8 ? code : nil
  }
}

/// Who asks and what they get, before the user approves.
private struct RequestSummary: View {
  let request: BackendPairingRequest

  var body: some View {
    VStack(spacing: 12) {
      icon
        .frame(width: 44, height: 44)
        .foregroundStyle(.tint)
      Text(title)
        .font(.title3.weight(.semibold))
        .multilineTextAlignment(.center)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var icon: some View {
    switch request.kind {
    case .connector:
      Image("ClaudeMark")
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
    case .device:
      Image(systemName: RegistryIcons.sfSymbols["auth.device"] ?? "laptopcomputer.and.iphone")
        .resizable()
        .scaledToFit()
    }
  }

  private var title: String {
    switch request.kind {
    case .device: return String(localized: "Sign in on \(request.client)?")
    case .connector: return String(localized: "Connect \(request.client) to your tasks?")
    }
  }

  private var detail: String {
    switch request.kind {
    case .device:
      return String(localized: "\(request.client) gets full access to your Septena account, including tasks, lists, conversations and settings. It stays signed in until you sign it out.")
    case .connector:
      return String(localized: "\(request.client) can read and change your tasks. You can pause it in AI & Agents.")
    }
  }
}

/// Settings ▸ Account ▸ Approve a sign-in (`registry/settings.json`,
/// surface `sign_in_approval`). Shown only when this device is signed in.
struct SeptaskSignInApprovalSection: View {
  @State private var showingFlow = false

  var body: some View {
    if TaskSyncEngine.shared.signedIn {
      Section {
        Button {
          showingFlow = true
        } label: {
          Label("Approve a sign-in",
                systemImage: RegistryIcons.sfSymbols["settings.sign_in_approval"] ?? "person.badge.key")
        }
        .sheet(isPresented: $showingFlow) {
          SeptaskApproveSignInFlow()
        }
      } footer: {
        Text("To sign in on a new phone, tablet or computer, tap Get a sign-in code on it. Then enter that code here.")
      }
    }
  }
}
