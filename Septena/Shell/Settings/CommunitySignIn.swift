import AuthenticationServices
import SwiftUI

/// Sign in with Apple — the genuineness proof for community features on devices
/// without App Attest (native macOS). Shown only when `CommunityClient.access()`
/// returns `.needsAppleSignIn`. One tap mints a Worker session; signing in or
/// out changes no app data, it only unlocks community writes on this device.
struct CommunitySignInSection: View {
  /// Called after a successful sign-in so the host pane can re-evaluate access.
  var onSignedIn: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    Section {
      if busy {
        HStack { ProgressView(); Text("Signing in…").foregroundStyle(.secondary) }
      } else {
        SignInWithAppleButton(.signIn) { request in
          // We only need the identity token; no name/email scope.
          request.requestedScopes = []
        } onCompletion: { result in
          handle(result)
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 44)
      }
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    } header: {
      Text("Sign in with Apple")
    } footer: {
      Text("This Mac can't use App Attest, so community features verify you with a one-time Sign in with Apple instead. It ties contributions to your Apple ID — nothing in your data changes, and you can sign out any time.")
    }
  }

  private func handle(_ result: Result<ASAuthorization, Error>) {
    switch result {
    case .failure(let err):
      if (err as? ASAuthorizationError)?.code == .canceled { return }
      error = err.localizedDescription
    case .success(let auth):
      guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let token = String(data: tokenData, encoding: .utf8) else {
        error = "Couldn't read the Apple identity token."
        return
      }
      busy = true
      error = nil
      Task { @MainActor in
        do {
          try await CommunityClient.shared.signInWithApple(identityToken: token)
          busy = false
          onSignedIn()
        } catch {
          busy = false
          self.error = communitySignInErrorText(error)
        }
      }
    }
  }
}

/// Signed-in state + a sign-out control. Renders nothing when there's no Apple
/// session (so it's safe to drop into any pane unconditionally — it only shows
/// on a Mac that has signed in).
struct CommunitySignOutSection: View {
  var onSignedOut: () -> Void

  var body: some View {
    if CommunityClient.shared.hasAppleSession() {
      Section {
        Label("Signed in with Apple", systemImage: "checkmark.seal")
          .foregroundStyle(.secondary)
        Button(role: .destructive) {
          CommunityClient.shared.signOutApple()
          onSignedOut()
        } label: {
          Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
        }
      } header: {
        Text("Community sign-in")
      } footer: {
        Text("Signing out only forgets this device's session — your contributions and all your data stay put.")
      }
    }
  }
}

func communitySignInErrorText(_ error: Error) -> String {
  if case CommunityClient.ClientError.cloudKitUserUnavailable = error {
    return "iCloud is unavailable. Sign in to iCloud and try again."
  }
  if case CommunityClient.ClientError.badResponse(let code) = error {
    switch code {
    case 401: return "Apple couldn't verify this sign-in. Try again."
    case 403: return "This Apple ID is already linked to a different account."
    case 429: return "Too many attempts. Try again in a moment."
    default:  return "Sign-in failed with HTTP \(code)."
    }
  }
  return error.localizedDescription
}
