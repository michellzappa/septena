#if os(macOS)
import AuthenticationServices
import SwiftUI

/// Settings ▸ About ▸ Advanced ▸ Task backend (preview). Mac only. Phase 1 of
/// docs/SEPTASK_BACKEND.md §9: sign in to api.septena.app with Apple and copy
/// every task, area, project, conversation and attachment there. The logic
/// lives in `TaskBackendImporter` (SeptenaCore); this view only drives it.
struct SeptaskBackendSettingsPane: View {
  @Environment(\.colorScheme) private var colorScheme
  private var importer: TaskBackendImporter { .shared }
  /// The raw nonce of the Sign in with Apple request in flight. Apple gets
  /// its hash; the backend gets this value.
  @State private var rawNonce: String?
  @State private var signingIn = false
  @State private var signInError: String?

  var body: some View {
    Form {
      Section {
        if importer.signedIn {
          Label("Signed in", systemImage: "checkmark.seal")
            .foregroundStyle(.secondary)
          Button(role: .destructive) {
            Task { await importer.signOut() }
          } label: {
            Label("Sign out of backend", systemImage: "rectangle.portrait.and.arrow.right")
          }
          .disabled(importer.phase == .running)
        } else if signingIn {
          HStack {
            ProgressView().controlSize(.small)
            Text("Signing in…").foregroundStyle(.secondary)
          }
        } else {
          SignInWithAppleButton(.signIn) { request in
            let nonce = TaskBackendClient.makeNonce()
            rawNonce = nonce.raw
            request.requestedScopes = []
            request.nonce = nonce.hashed
          } onCompletion: { result in
            handleSignIn(result)
          }
          .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
          .frame(height: 32)
        }
        if let signInError {
          Text(signInError).font(.caption).foregroundStyle(.red)
        }
      } header: {
        Text("Account")
      } footer: {
        Text("Sign in with Apple to reach the task backend at api.septena.app. The sign-in stays on this Mac.")
      }

      Section {
        Button {
          Task { await importer.run() }
        } label: {
          Label("Copy tasks to backend", systemImage: "arrow.up.doc")
        }
        .disabled(!importer.signedIn || importer.phase == .running)

        if importer.phase == .running {
          HStack {
            ProgressView().controlSize(.small)
            Text(importer.progress).foregroundStyle(.secondary)
          }
        } else if let line = importer.resultLine {
          Text(line)
        }
      } header: {
        Text("Copy")
      } footer: {
        Text("Copies every task, area, project, conversation and attachment on this Mac to the backend, then reads it back to check. Your iCloud data does not change. Running it again updates the copy.")
      }

      if !importer.issues.isEmpty {
        Section {
          ForEach(importer.issues.prefix(20), id: \.key) { issue in
            VStack(alignment: .leading, spacing: 2) {
              Text("\(issue.entity.rawValue) \(issue.id)")
                .font(.caption.monospaced())
              Text(issue.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          if importer.issues.count > 20 {
            Text("\(importer.issues.count - 20) more not shown.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("Details")
        }
      }
    }
    .formStyle(.grouped)
  }

  private func handleSignIn(_ result: Result<ASAuthorization, Error>) {
    switch result {
    case .failure(let error):
      if (error as? ASAuthorizationError)?.code == .canceled { return }
      signInError = error.localizedDescription
    case .success(let auth):
      guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let token = String(data: tokenData, encoding: .utf8),
            let nonce = rawNonce else {
        signInError = "Couldn't read the Apple identity token."
        return
      }
      signingIn = true
      signInError = nil
      Task { @MainActor in
        defer { signingIn = false; rawNonce = nil }
        do {
          try await importer.signIn(identityToken: token, rawNonce: nonce)
        } catch {
          signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
      }
    }
  }
}
#endif
