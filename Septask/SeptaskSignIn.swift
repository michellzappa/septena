import AuthenticationServices
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Sign in with Apple for the task backend, in one place. Septask is
// backend-only (docs/SEPTASK_BACKEND.md §9, phase 4): signed out, it keeps
// working on the local store and queues every edit in the sync outbox, and it
// asks to sign in on the welcome, on Today, and in Settings ▸ Account. All
// three ask through the pieces below, so the flow exists once.

/// The flow itself: a nonce for Apple, then the identity token to the backend.
@MainActor
enum SeptaskSignIn {
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
      } catch {
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
    }
  }
}

// MARK: - SwiftUI

/// The Apple button, with progress and the error line under it. `compact`
/// is the size for an inline notice (the `.signIn` notice in `TaskNotices`); the full size
/// is for the welcome and Settings.
struct SeptaskSignInButton: View {
  var compact = false
  @Environment(\.colorScheme) private var colorScheme
  @State private var rawNonce: String?
  @State private var working = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if working {
        ProgressView().controlSize(.small)
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
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
  }
}

/// Settings ▸ Account and the task backend pane: who is signed in, the sync
/// state, and sign-in or sign-out.
struct SeptaskSyncAccountSection: View {
  private var sync: TaskSyncEngine { .shared }

  var body: some View {
    Section {
      if sync.signedIn {
        LabeledContent("Sync") {
          Text(statusLine).foregroundStyle(.secondary)
        }
        if let error = sync.lastError {
          Text(error).font(.caption).foregroundStyle(.red)
        }
        Button(role: .destructive) {
          Task { await sync.signOut() }
        } label: {
          Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
        }
      } else {
        Text(signedOutLine).foregroundStyle(.secondary)
        SeptaskSignInButton()
      }
    } header: {
      Text("Sync")
    } footer: {
      Text("Your tasks sync through Septena's own server at api.septena.app. Sign in with Apple once on each device.")
    }
  }

  private var signedOutLine: String {
    if sync.hadAccount, sync.pendingOps > 0 {
      return String(localized: "Not signed in. \(sync.pendingOps) changes are waiting on this device and sync when you sign in.",
                    comment: "Septask sync: signed out with queued edits")
    }
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
          Label("Delete account", systemImage: "trash")
        }
        // On the button, not the Section: a Section's modifiers fan out to
        // its rows.
        .sheet(isPresented: $confirming) {
          SeptaskDeleteAccountSheet()
        }
      } footer: {
        Text("Deletes your account and all your tasks on the Septena server.")
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
      Text("Delete your account?")
        .font(.title2.weight(.semibold))
      Text("This deletes the following from the Septena server:")
      VStack(alignment: .leading, spacing: 6) {
        Label("Your tasks, areas and projects", systemImage: "checklist")
        Label("Your attachments", systemImage: "paperclip")
        Label("Your task conversations", systemImage: "bubble.left.and.text.bubble.right")
        Label("Your synced settings", systemImage: "gearshape")
      }
      .padding(.leading, 4)
      Text("It also removes your tasks from this device and signs you out. You can’t undo this.")
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
        Button("Delete account", role: .destructive) { delete() }
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
        self.error = String(localized: "Couldn't delete your account. Nothing was deleted. \(detail)",
                            comment: "Delete account sheet: the server call failed")
        working = false
      }
    }
  }
}

// MARK: - AppKit (the macOS shell's Today list)

#if os(macOS)
/// Runs the Apple sheet for an AppKit button. One shared instance: the
/// controller holds its delegate weakly.
@MainActor
final class SeptaskAppKitSignIn: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding {
  static let shared = SeptaskAppKitSignIn()

  private var rawNonce: String?
  private var controller: ASAuthorizationController?

  func start() {
    guard controller == nil else { return }
    let request = ASAuthorizationAppleIDProvider().createRequest()
    rawNonce = SeptaskSignIn.prepare(request)
    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self
    controller.presentationContextProvider = self
    self.controller = controller
    controller.performRequests()
  }

  nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? NSWindow()
    }
  }

  nonisolated func authorizationController(controller: ASAuthorizationController,
                                           didCompleteWithAuthorization authorization: ASAuthorization) {
    MainActor.assumeIsolated { finish(.success(authorization)) }
  }

  nonisolated func authorizationController(controller: ASAuthorizationController,
                                           didCompleteWithError error: Error) {
    MainActor.assumeIsolated { finish(.failure(error)) }
  }

  private func finish(_ result: Result<ASAuthorization, Error>) {
    let nonce = rawNonce
    rawNonce = nil
    controller = nil
    Task { @MainActor in
      if let error = await SeptaskSignIn.finish(result, rawNonce: nonce) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn’t sign in",
                                   comment: "Septask sign-in: failure alert title")
        alert.informativeText = error
        alert.runModal()
      }
    }
  }
}

#endif
