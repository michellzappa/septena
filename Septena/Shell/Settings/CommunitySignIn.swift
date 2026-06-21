import AuthenticationServices
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The Sign in with Apple button itself: runs the authorization, exchanges the
/// identity token for a Worker session, and owns the busy/error state. Drop into
/// any Section. macOS's substitute for App Attest — see `CommunityClient`.
struct AppleSignInButton: View {
  /// Called after a successful sign-in so the host can re-evaluate state.
  var onSignedIn: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var busy = false
  @State private var error: String?

  var body: some View {
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

/// Sign in with Apple — the genuineness proof for community features on devices
/// without App Attest (native macOS). Shown in a community pane only when
/// `CommunityClient.access()` returns `.needsAppleSignIn`. One tap mints a Worker
/// session; signing in or out changes no app data, it only unlocks community
/// writes on this device.
struct CommunitySignInSection: View {
  /// Called after a successful sign-in so the host pane can re-evaluate access.
  var onSignedIn: () -> Void

  var body: some View {
    Section {
      AppleSignInButton(onSignedIn: onSignedIn)
    } header: {
      Text("Sign in with Apple")
    } footer: {
      Text("This Mac can't use App Attest, so community features verify you with a one-time Sign in with Apple instead. It ties contributions to your Apple ID — nothing in your data changes, and you can sign out any time.")
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

/// The standing, fully-optional Apple sign-in control for Settings ▸ Profile ▸
/// iCloud. macOS only — iOS uses App Attest invisibly, so it renders nothing
/// there. Lives next to Sync because it's the same "your Apple ID" story; the
/// footer is explicit that it does nothing but unlock community features.
struct CommunityAppleAccountSection: View {
  @State private var signedIn = CommunityClient.shared.hasAppleSession()

  var body: some View {
    if !CommunityClient.shared.appAttestSupported {
      Section {
        if signedIn {
          Label("Signed in with Apple", systemImage: "checkmark.seal")
            .foregroundStyle(.secondary)
          Button(role: .destructive) {
            CommunityClient.shared.signOutApple()
            signedIn = false
          } label: {
            Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
          }
        } else {
          AppleSignInButton { signedIn = true }
        }
      } header: {
        Text("Sign in with Apple")
      } footer: {
        Text("Optional. This Mac can't use App Attest, so Sign in with Apple is how the community features — Roadmap, Testimonials, and in-app Support — confirm you're a real person. That's the only thing it does: it ties those contributions to your Apple ID and nothing else. It doesn't touch your data, your iCloud sync, or your account, and you can sign out any time.")
      }
      .onReceive(NotificationCenter.default.publisher(for: .septenaCommunityAuthChanged)) { _ in
        signedIn = CommunityClient.shared.hasAppleSession()
      }
    }
  }
}

/// Jumps to where the user signs into iCloud / their Apple Account. On macOS
/// this deep-links to System Settings ▸ Apple Account; on iOS the system has no
/// public link straight to iCloud sign-in, so it opens the app's Settings page.
struct OpenAppleAccountButton: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button {
      #if os(macOS)
      if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
        openURL(url)
      }
      #else
      if let url = URL(string: UIApplication.openSettingsURLString) {
        openURL(url)
      }
      #endif
    } label: {
      #if os(macOS)
      Label("Open iCloud settings", systemImage: "person.crop.circle.badge.plus")
      #else
      Label("Open Settings", systemImage: "gear")
      #endif
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
