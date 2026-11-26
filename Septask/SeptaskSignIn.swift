import AuthenticationServices
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Sign-in for the task backend, in one place. Septask is backend-only
// (docs/SEPTASK_BACKEND.md §9, phase 4): signed out, it keeps working on the
// local store and queues every edit in the sync outbox, and it asks to sign in
// on the welcome, on Today, and in Settings ▸ Account. All three ask through
// the pieces below, so the flow exists once. The methods (Apple, email code,
// device approval) come from `registry/sign-in.json` and the server's
// `GET /v1/auth/methods` (ADR 0047, docs/SIGN_IN_SURFACES_SPEC.md).

/// The flow itself: a nonce for Apple, then the identity token to the backend.
@MainActor
enum SeptaskSignIn {
  /// Whether this build may use native Sign in with Apple. Apple grants that
  /// entitlement to App Store and development builds only, never to a
  /// Developer ID one, so the Mac download signs in with a code (ADR 0016).
  static let appleAvailable: Bool = {
    #if os(macOS)
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    return SecTaskCopyValueForEntitlement(task, "com.apple.developer.applesignin" as CFString, nil) != nil
    #else
    return true
    #endif
  }()

  /// Fills Apple's request. Returns the raw nonce, which the backend needs.
  static func prepare(_ request: ASAuthorizationAppleIDRequest) -> String {
    let nonce = TaskBackendClient.makeNonce()
    request.requestedScopes = []
    request.nonce = nonce.hashed
    return nonce.raw
  }

  /// Hands Apple's result to the backend. Returns an error line, or nil when
  /// it worked or the user cancelled.
  static func finish(_ result: Result<ASAuthorization, Error>, rawNonce: String?) async -> String? {
    switch result {
    case .failure(let error):
      if (error as? ASAuthorizationError)?.code == .canceled { return nil }
      return error.localizedDescription
    case .success(let auth):
      guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
            let data = credential.identityToken,
            let token = String(data: data, encoding: .utf8),
            let rawNonce else {
        return String(localized: "Apple sign-in couldn’t be completed.",
                      comment: "Septask sign-in: Apple returned no identity token")
      }
      do {
        try await TaskSyncEngine.shared.signIn(identityToken: token, rawNonce: rawNonce)
        TaskNotices.clearSignInDismissal()
        return nil
      } catch is TaskSyncEngine.AccountSwitchDeclined {
        // The user kept this device's tasks; nothing went wrong.
        return nil
      } catch {
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
    }
  }
}

// MARK: - Methods

/// The sign-in methods this screen offers (ADR 0047,
/// docs/SIGN_IN_SURFACES_SPEC.md §3): the registry's list for this platform,
/// without a method whose flow here is `.unavailable`, one the server has off
/// (`GET /v1/auth/methods`), or one this build does not implement. Until the
/// server answers, and when it cannot be reached, the list is Apple (when
/// this build has it) and device approval: no button that cannot work.
@MainActor @Observable
final class SeptaskSignInMethods {
  static let shared = SeptaskSignInMethods()

  /// The server's list, or nil before the first answer.
  private var serverMethods: Set<String>?
  private var lastFetch: Date?
  private var fetching = false

  var methods: [RegistrySignInMethod] {
    let platform = RegistryPlatform.current
    let on = serverMethods ?? [RegistrySignInMethodId.apple.rawValue, RegistrySignInMethodId.device.rawValue]
    return RegistrySignIn.methods(on: platform).filter { method in
      guard let flow = method.flows[platform], flow != .unavailable else { return false }
      return on.contains(method.id.rawValue) && Self.implements(method.id)
    }
  }

  private static func implements(_ id: RegistrySignInMethodId) -> Bool {
    switch id {
    // Web Apple, Google and Microsoft come with the OIDC routes (#639).
    case .apple: return SeptaskSignIn.appleAvailable
    case .email, .device: return true
    case .google, .microsoft: return false
    }
  }

  /// Asks the server which methods are on. At most once a minute; a failure
  /// keeps the list it had.
  func refresh() async {
    guard !fetching else { return }
    if let lastFetch, Date().timeIntervalSince(lastFetch) < 60 { return }
    fetching = true
    defer { fetching = false }
    guard let ids = try? await TaskBackendClient.shared.signInMethods() else { return }
    serverMethods = Set(ids)
    lastFetch = Date()
  }
}

// MARK: - SwiftUI

/// A step of the sign-in screen.
enum SeptaskSignInStep: String, Identifiable {
  case methods
  case email
  case device

  var id: String { rawValue }
}

/// The sign-in methods, in registry order, with the Terms line under them.
/// Apple runs in place; email and device approval hand their step to
/// `onChoose`. `compact` is the size for an inline notice.
struct SeptaskSignInMethodList: View {
  var compact = false
  let onChoose: (SeptaskSignInStep) -> Void
  @Environment(\.colorScheme) private var colorScheme
  @State private var rawNonce: String?
  @State private var working = false
  @State private var error: String?
  private var available: SeptaskSignInMethods { .shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(available.methods) { method in
        switch method.id {
        case .apple:
          appleButton
        case .email:
          methodButton(method) { onChoose(.email) }
        case .device:
          methodButton(method) { onChoose(.device) }
        default:
          EmptyView()
        }
      }
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      SeptaskSignInTermsLine()
    }
    .task { await available.refresh() }
  }

  @ViewBuilder
  private var appleButton: some View {
    if working {
      ProgressView().controlSize(.small).frame(height: compact ? 32 : 36)
    } else {
      SignInWithAppleButton(.signIn) { request in
        rawNonce = SeptaskSignIn.prepare(request)
      } onCompletion: { result in
        working = true
        Task { @MainActor in
          error = await SeptaskSignIn.finish(result, rawNonce: rawNonce)
          rawNonce = nil
          working = false
        }
      }
      .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
      // Apple's minimum for the "Sign in with Apple" label is 140 x 30.
      .frame(width: compact ? 180 : nil, height: compact ? 32 : 36)
      .frame(maxWidth: 320)
    }
  }

  private func methodButton(_ method: RegistrySignInMethod, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(method.title, systemImage: RegistryIcons.sfSymbols[method.icon] ?? "person.crop.circle")
        .frame(maxWidth: compact ? nil : 320)
    }
    .buttonStyle(.bordered)
    .controlSize(compact ? .regular : .large)
  }
}

/// "By continuing, you agree to the Terms of Use and the Privacy Policy."
/// with both links (#564).
struct SeptaskSignInTermsLine: View {
  var body: some View {
    Text(Self.line)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private static var line: AttributedString {
    var terms = AttributedString(RegistrySignIn.Copy.termsLabel)
    terms.link = RegistrySignIn.termsURL
    var privacy = AttributedString(RegistrySignIn.Copy.privacyLabel)
    privacy.link = RegistrySignIn.privacyURL
    let marker = "\u{1F}"
    let template = RegistrySignIn.Copy.terms(terms: marker, privacy: marker)
    let parts = template.components(separatedBy: marker)
    guard parts.count == 3 else { return AttributedString(template) }
    return AttributedString(parts[0]) + terms + AttributedString(parts[1]) + privacy + AttributedString(parts[2])
  }
}

/// The sign-in screen (ADR 0047): the heading, the methods and the Terms
/// line, then the email or device step in place. Every way in opens it: the
/// Today notice (both shells), and through `SeptaskSignInButton` the first
/// run and Settings ▸ Account. It closes itself once signed in.
struct SeptaskSignInScreen: View {
  var start: SeptaskSignInStep = .methods
  let onClose: () -> Void
  @State private var step: SeptaskSignInStep?
  private var sync: TaskSyncEngine { .shared }

  var body: some View {
    VStack(spacing: 0) {
      switch step ?? start {
      case .methods:
        VStack(alignment: .leading, spacing: 16) {
          Text(RegistrySignIn.Copy.heading).font(.title2.weight(.semibold))
          Text(RegistrySignIn.Copy.subheading)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          SeptaskSignInMethodList { step = $0 }
          HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: onClose)
              .keyboardShortcut(.cancelAction)
          }
        }
        .padding(24)
      case .email:
        SeptaskEmailSignInForm(onClose: onClose)
      case .device:
        SeptaskDeviceSignInSheet(onClose: onClose)
      }
    }
    #if os(macOS)
    .frame(width: 420)
    #else
    .presentationDetents([.medium, .large])
    #endif
    .onChange(of: sync.signedIn) { _, signedIn in
      if signedIn { onClose() }
    }
  }
}

/// Sign-in on the welcome, in Settings and on the Today notice. Full size
/// lists the methods in place; `compact` (the `.signIn` notice in
/// `TaskNotices`) is one button that opens the sign-in screen.
struct SeptaskSignInButton: View {
  var compact = false
  var title: String?
  @State private var presented: SeptaskSignInStep?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if compact {
        Button(title ?? RegistrySignIn.Copy.heading) { presented = .methods }
          .buttonStyle(.bordered)
          .controlSize(.small)
      } else {
        SeptaskSignInMethodList { presented = $0 }
      }
    }
    .sheet(item: $presented) { step in
      SeptaskSignInScreen(start: step) { presented = nil }
    }
  }
}

// MARK: - Email code

/// Sign-in with a code mailed to an address (ADR 0047): the address, Send
/// code, then the code and Sign in. A new address creates an account. Every
/// wait ends: a request fails after the client's timeout, and the code step
/// says so when the code has expired.
struct SeptaskEmailSignInForm: View {
  let onClose: () -> Void

  private enum Field: Hashable { case email, code }

  @State private var email = ""
  @State private var code = ""
  /// The address the live code went to; nil on the address step.
  @State private var sentTo: String?
  @State private var codeLength = 6
  @State private var expiresAt: Date?
  @State private var working = false
  @State private var error: String?
  @FocusState private var focus: Field?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(RegistrySignIn.method(.email)?.title ?? RegistrySignIn.Copy.heading)
        .font(.title2.weight(.semibold))
      if let sentTo {
        Text(RegistrySignIn.Email.codeSent(email: sentTo))
          .fixedSize(horizontal: false, vertical: true)
        codeField
        Button(action: verify) {
          Text(RegistrySignIn.Email.signIn).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(working || code.count != codeLength)
        HStack {
          Button(RegistrySignIn.Email.resend) { send(to: sentTo) }
          Spacer()
          Button(RegistrySignIn.Email.differentEmail, action: useDifferentEmail)
        }
        .buttonStyle(.borderless)
        .disabled(working)
      } else {
        emailField
        Button { send(to: email) } label: {
          Text(RegistrySignIn.Email.sendCode).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(working || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if working { ProgressView().controlSize(.small) }
      if let error {
        Text(error).font(.callout).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      SeptaskSignInTermsLine()
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onClose)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .onAppear { focus = sentTo == nil ? .email : .code }
    // The code's lifetime: once it has passed, say so instead of waiting
    // for a code that can no longer work.
    .task(id: expiresAt) {
      guard let expiresAt else { return }
      let wait = expiresAt.timeIntervalSinceNow
      if wait > 0 {
        do { try await Task.sleep(for: .seconds(wait)) } catch { return }
      }
      if !working { self.error = RegistrySignIn.Errors.codeExpired }
    }
  }

  private var emailField: some View {
    TextField(RegistrySignIn.Email.emailLabel, text: $email,
              prompt: Text(RegistrySignIn.Email.emailPlaceholder))
      .textContentType(.emailAddress)
      #if os(iOS)
      .keyboardType(.emailAddress)
      .textInputAutocapitalization(.never)
      #endif
      .autocorrectionDisabled()
      .textFieldStyle(.roundedBorder)
      .focused($focus, equals: .email)
      .onSubmit { send(to: email) }
      .disabled(working)
  }

  private var codeField: some View {
    TextField(RegistrySignIn.Email.codeLabel, text: $code)
      .textContentType(.oneTimeCode)
      #if os(iOS)
      .keyboardType(.numberPad)
      #endif
      .autocorrectionDisabled()
      .font(.title3.monospacedDigit())
      .textFieldStyle(.roundedBorder)
      .focused($focus, equals: .code)
      .onSubmit(verify)
      .onChange(of: code) { _, value in
        let digits = String(value.filter { ("0"..."9").contains($0) }.prefix(codeLength))
        if digits != value { code = digits }
      }
      .disabled(working)
  }

  /// A plain shape check before the server's own: one `@`, a dot in the domain.
  static func isPlausibleEmail(_ address: String) -> Bool {
    let parts = address.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, address.count <= 254 else { return false }
    let domain = parts[1]
    return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
      && !address.contains(where: \.isWhitespace)
  }

  private func send(to raw: String) {
    let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !working else { return }
    guard Self.isPlausibleEmail(address) else {
      error = RegistrySignIn.Errors.invalidEmail
      return
    }
    working = true
    error = nil
    Task { @MainActor in
      defer { working = false }
      do {
        let sent = try await TaskBackendClient.shared.startEmailSignIn(email: address)
        codeLength = sent.codeLength
        code = ""
        sentTo = address
        expiresAt = Date().addingTimeInterval(TimeInterval(sent.expiresInSeconds))
        focus = .code
      } catch BackendEmailSignInError.invalidRequest {
        self.error = RegistrySignIn.Errors.invalidEmail
      } catch {
        self.error = Self.message(for: error)
      }
    }
  }

  private func verify() {
    guard let sentTo, code.count == codeLength, !working else { return }
    if let expiresAt, expiresAt <= Date() {
      error = RegistrySignIn.Errors.codeExpired
      return
    }
    working = true
    error = nil
    Task { @MainActor in
      defer { working = false }
      do {
        try await TaskSyncEngine.shared.signIn(email: sentTo, code: code)
        TaskNotices.clearSignInDismissal()
        onClose()
      } catch is TaskSyncEngine.AccountSwitchDeclined {
        // The user kept this device's tasks; nothing went wrong.
        onClose()
      } catch BackendEmailSignInError.invalidRequest {
        self.error = RegistrySignIn.Errors.codeExpired
      } catch {
        code = ""
        self.error = Self.message(for: error)
        focus = .code
      }
    }
  }

  private func useDifferentEmail() {
    sentTo = nil
    code = ""
    expiresAt = nil
    error = nil
    focus = .email
  }

  /// The registry's line for a failed start or verify.
  private static func message(for error: Error) -> String {
    switch error {
    case BackendEmailSignInError.wrongCode(let left) where left > 0:
      return RegistrySignIn.Errors.wrongCode(count: left)
    case BackendEmailSignInError.wrongCode, BackendEmailSignInError.tooManyAttempts:
      return RegistrySignIn.Errors.tooManyTries
    case BackendEmailSignInError.expired:
      return RegistrySignIn.Errors.codeExpired
    case BackendEmailSignInError.rateLimited:
      return RegistrySignIn.Errors.rateLimited
    case TaskBackendError.keychainUnavailable:
      return TaskBackendError.keychainUnavailable.errorDescription ?? RegistrySignIn.Errors.network
    default:
      // Unreachable, switched off (503) or an answer this build cannot read.
      return RegistrySignIn.Errors.network
    }
  }
}

/// Settings ▸ Account and the task backend pane: who is signed in, the sync
/// state, and sign-in or sign-out.
struct SeptaskSyncAccountSection: View {
  private static let syncSection = RegistrySettings.section("sync", page: RegistrySettings.PageID.account)
  private var sync: TaskSyncEngine { .shared }
  @State private var copiedAccountID = false

  var body: some View {
    Section {
      if sync.signedIn {
        LabeledContent(Self.syncSection?.header ?? "") {
          Text(statusLine).foregroundStyle(.secondary)
        }
        if let accountID = sync.accountID, !accountID.isEmpty {
          LabeledContent(RegistrySettings.copy("sync_account_status", "accountIdLabel")) {
            HStack(spacing: 8) {
              Text(accountID)
                .font(.septenaMeta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
              Button {
                SeptenaPasteboard.copy(accountID)
                copiedAccountID = true
                Task { @MainActor in
                  try? await Task.sleep(nanoseconds: 2_000_000_000)
                  copiedAccountID = false
                }
              } label: {
                Label(
                  RegistrySettings.copy("sync_account_status", copiedAccountID ? "copied" : "copy"),
                  systemImage: copiedAccountID ? "checkmark" : "doc.on.doc"
                )
              }
              .buttonStyle(.borderless)
            }
          }
        }
        if let error = sync.lastError {
          Text(error).font(.caption).foregroundStyle(.red)
        }
        Button(role: .destructive) {
          Task { await sync.signOut() }
        } label: {
          Label(RegistryActions.title(.accountSignOut), systemImage: "rectangle.portrait.and.arrow.right")
        }
      } else {
        Text(signedOutLine).foregroundStyle(.secondary)
        SeptaskSignInButton()
      }
    } header: {
      if let header = Self.syncSection?.header {
        Text(header)
      }
    } footer: {
      if offered == [.apple, .device] || offered == [.apple] {
        Text("Your tasks sync through Septena's own server at api.septena.app. Sign in with Apple once on each device.")
      }
    }
  }

  private var offered: [RegistrySignInMethodId] { SeptaskSignInMethods.shared.methods.map(\.id) }

  private var signedOutLine: String {
    if sync.hadAccount, sync.pendingOps > 0 {
      return String(localized: "Not signed in. \(sync.pendingOps) changes are waiting on this device and sync when you sign in.",
                    comment: "Septask sync: signed out with queued edits")
    }
    // Apple alone (with device approval) keeps its own line; any other
    // account-creating method takes the sign-in screen's line.
    if offered.contains(.email) { return RegistrySignIn.Copy.subheading }
    if !offered.contains(.apple) { return RegistryDeviceSignIn.intro }
    return String(localized: "Your tasks stay on this device. Sign in with Apple when you want to sync across devices.",
                  comment: "Septask sync: free no-account mode")
  }

  private var statusLine: String {
    var parts: [String] = []
    parts.append(sync.isSyncing ? RegistrySettings.copy("syncStatus", "syncing") : (sync.wsConnected ? "Live" : "Waiting for connection"))
    if sync.pendingOps > 0 { parts.append("\(sync.pendingOps) to send") }
    if let last = sync.lastPull {
      parts.append("updated \(last.formatted(.relative(presentation: .named)))")
    }
    return parts.joined(separator: ", ")
  }
}

// MARK: - Delete account

/// Settings ▸ Account: the in-app account deletion the App Store requires.
/// Draws nothing while signed out (there is no account on this device to
/// delete). The confirmation is a plain window sheet that lists what goes;
/// Cancel is the default button, so Return never deletes.
struct SeptaskDeleteAccountSection: View {
  private var sync: TaskSyncEngine { .shared }
  @State private var confirming = false

  var body: some View {
    if sync.signedIn {
      Section {
        Button(role: .destructive) {
          confirming = true
        } label: {
          Label(RegistrySettings.copy("delete_account", "button"), systemImage: "trash")
        }
        // On the button, not the Section: a Section's modifiers fan out to
        // its rows.
        .sheet(isPresented: $confirming) {
          SeptaskDeleteAccountSheet()
        }
      } footer: {
        Text(RegistrySettings.copy("delete_account", "footer"))
      }
    }
  }
}

private struct SeptaskDeleteAccountSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var working = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(RegistrySettings.copy("delete_account", "title"))
        .font(.title2.weight(.semibold))
      Text(RegistrySettings.copy("delete_account", "intro"))
      VStack(alignment: .leading, spacing: 6) {
        Label(RegistrySettings.copy("delete_account", "tasks"), systemImage: "checklist")
        Label(RegistrySettings.copy("delete_account", "attachments"), systemImage: "paperclip")
        Label(RegistrySettings.copy("delete_account", "conversations"), systemImage: "bubble.left.and.text.bubble.right")
        Label(RegistrySettings.copy("delete_account", "settings"), systemImage: "gearshape")
      }
      .padding(.leading, 4)
      Text(RegistrySettings.copy("delete_account", "consequence"))
      if let error {
        Text(error).font(.callout).foregroundStyle(.red)
      }
      #if os(iOS)
      Spacer(minLength: 0)
      #endif
      HStack {
        if working { ProgressView().controlSize(.small) }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .disabled(working)
        Button(RegistrySettings.copy("delete_account", "button"), role: .destructive) { delete() }
          .disabled(working)
      }
    }
    .padding(24)
    #if os(macOS)
    .frame(width: 420)
    #else
    .presentationDetents([.medium])
    #endif
    .interactiveDismissDisabled(working)
  }

  private func delete() {
    working = true
    error = nil
    Task { @MainActor in
      do {
        try await TaskSyncEngine.shared.deleteAccount()
        dismiss()
        // Back to the first run: Today shows Get started again.
        TaskNotices.resetGetStarted()
      } catch {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        self.error = "\(RegistrySettings.copy("delete_account", "failed")) \(detail)"
        working = false
      }
    }
  }
}

// MARK: - AppKit (the macOS shell's Today list)

#if os(macOS)
/// The sign-in screen as a sheet on the AppKit shell's main window (the Today
/// notice's button and Return on the selected notice).
@MainActor
enum SeptaskSignInWindow {
  private static var sheet: NSWindow?

  static func present(start: SeptaskSignInStep = .methods) {
    guard sheet == nil, let parent = SeptaskKitWindowController.existing?.window else { return }
    let host = NSHostingController(rootView: SeptaskSignInScreen(start: start) { dismiss() })
    let window = NSWindow(contentViewController: host)
    window.title = RegistrySignIn.Copy.heading
    window.styleMask = [.titled]
    sheet = window
    parent.beginSheet(window)
  }

  private static func dismiss() {
    guard let window = sheet else { return }
    window.sheetParent?.endSheet(window)
    sheet = nil
  }
}
#endif
