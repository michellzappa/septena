import SwiftUI

/// The member-facing community identity: the username, display name, and bio
/// that appear on feature requests and comments once those surfaces ship, plus
/// the public/private toggle. Backed by the community Worker's `GET /api/me` and
/// `PATCH /api/me/profile`; auth rides App Attest + the iCloud user record, so
/// the whole pane is gated on App Attest like in-app support.
struct CommunityProfilePane: View {
  @State private var username = ""
  @State private var displayName = ""
  @State private var bio = ""
  @State private var isPublic = false

  /// Last value loaded (or saved) from the server, used for change detection so
  /// the Save button only lights up when there's something to write.
  @State private var saved: CommunityProfile?
  @State private var role = "user"
  @State private var isBanned = false
  @State private var userHash: String?

  @State private var loading = false
  @State private var saving = false
  @State private var errorMessage: String?
  @State private var savedConfirmation = false

  private var canUseCommunity: Bool {
    CommunityClient.shared.appAttestSupported
  }

  private var normalizedUsername: String {
    username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var usernameValid: Bool {
    let u = normalizedUsername
    return u.isEmpty || u.range(of: "^[a-z0-9_]{2,24}$", options: .regularExpression) != nil
  }

  private var bioValid: Bool {
    bio.trimmingCharacters(in: .whitespacesAndNewlines).count <= 280
  }

  private var displayNameValid: Bool {
    displayName.trimmingCharacters(in: .whitespacesAndNewlines).count <= 80
  }

  /// The edited profile, normalized the same way the Worker will store it
  /// (empty fields become `nil`, username lower-cased).
  private var edited: CommunityProfile {
    func nilIfBlank(_ s: String) -> String? {
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }
    return CommunityProfile(
      username: normalizedUsername.isEmpty ? nil : normalizedUsername,
      displayName: nilIfBlank(displayName),
      bio: nilIfBlank(bio),
      isPublic: isPublic
    )
  }

  private var hasChanges: Bool {
    guard let saved else { return false }
    let e = edited
    return e.username != saved.username
      || e.displayName != saved.displayName
      || e.bio != saved.bio
      || e.isPublic != saved.isPublic
  }

  private var canSave: Bool {
    hasChanges && usernameValid && bioValid && displayNameValid && !saving
  }

  var body: some View {
    Form {
      if !canUseCommunity {
        fallbackSection
      } else {
        if isBanned {
          Section {
            Label("Your community access is suspended.", systemImage: "exclamationmark.octagon")
              .foregroundStyle(.red)
          }
        }

        Section {
          TextField("username", text: $username)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.asciiCapable)
            #endif
            .autocorrectionDisabled()
            .font(.body.monospaced())
          if !usernameValid {
            Text("2–24 characters: lowercase letters, numbers, or underscores.")
              .font(.caption)
              .foregroundStyle(.red)
          }
        } header: {
          Text("Username")
        } footer: {
          Text("Your unique handle on feature requests and comments. Leave blank to stay unnamed.")
        }

        Section {
          TextField("Display name", text: $displayName)
            #if os(iOS)
            .textInputAutocapitalization(.words)
            #endif
        } footer: {
          Text("Shown next to your contributions. Up to 80 characters.")
        }

        Section {
          TextEditor(text: $bio)
            .frame(minHeight: 96)
          HStack {
            Spacer()
            Text("\(bio.trimmingCharacters(in: .whitespacesAndNewlines).count)/280")
              .font(.caption2)
              .foregroundStyle(bioValid ? Color.secondary : Color.red)
          }
        } header: {
          Text("Bio")
        }

        Section {
          Toggle("Public profile", isOn: $isPublic)
        } footer: {
          Text("When on, other members can see your username, display name, and bio. When off, your contributions appear without a public profile.")
        }

        if role != "user" {
          Section {
            Label(roleTitle, systemImage: roleSymbol)
              .foregroundStyle(.secondary)
          } header: {
            Text("Role")
          }
        }

        if let userHash {
          Section {
            Text(userHash)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          } header: {
            Text("Account ID")
          } footer: {
            Text("Your anonymous community identity. Useful when granting maintainer access from the server.")
          }
        }

        if let errorMessage {
          Section {
            Text(errorMessage)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .task {
      if canUseCommunity, saved == nil { await load() }
    }
    .refreshable {
      if canUseCommunity { await load() }
    }
    .toolbar {
      if canUseCommunity {
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await save() }
          } label: {
            if saving {
              ProgressView()
            } else {
              Text("Save")
            }
          }
          .disabled(!canSave)
        }
      }
    }
    .overlay(alignment: .bottom) {
      if savedConfirmation {
        Label("Saved", systemImage: "checkmark.circle.fill")
          .font(.callout.weight(.medium))
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(.thinMaterial, in: Capsule())
          .padding(.bottom, 16)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: savedConfirmation)
  }

  private var fallbackSection: some View {
    Section {
      Label("Community profiles require App Attest and iCloud.", systemImage: "person.crop.circle.badge.exclamationmark")
        .foregroundStyle(.secondary)
      Text("This keeps profiles tied to the genuine app and your Apple ID without shipping a secret. Sign in to iCloud on a supported device to set one up.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var roleTitle: String {
    switch role {
    case "maintainer": return "Maintainer"
    case "moderator": return "Moderator"
    default: return "Member"
    }
  }

  private var roleSymbol: String {
    switch role {
    case "maintainer": return "checkmark.seal.fill"
    case "moderator": return "shield"
    default: return "person.crop.circle"
    }
  }

  @MainActor
  private func load() async {
    loading = true
    defer { loading = false }
    do {
      let me = try await CommunityClient.shared.me()
      apply(me)
      errorMessage = nil
    } catch {
      errorMessage = communityProfileErrorText(error)
    }
  }

  @MainActor
  private func save() async {
    guard canSave else { return }
    saving = true
    defer { saving = false }
    do {
      let me = try await CommunityClient.shared.updateProfile(edited)
      apply(me)
      errorMessage = nil
      savedConfirmation = true
      try? await Task.sleep(for: .seconds(1.6))
      savedConfirmation = false
    } catch {
      errorMessage = communityProfileErrorText(error)
    }
  }

  @MainActor
  private func apply(_ me: CommunityMe) {
    role = me.user.role
    isBanned = me.user.isBanned
    userHash = me.user.userHash
    let p = me.profile
    username = p.username ?? ""
    displayName = p.displayName ?? ""
    bio = p.bio ?? ""
    isPublic = p.isPublic
    saved = p
  }
}

private func communityProfileErrorText(_ error: Error) -> String {
  if case CommunityClient.ClientError.cloudKitUserUnavailable = error {
    return "iCloud is unavailable. Sign in to iCloud and try again."
  }
  if case CommunityClient.ClientError.badResponse(let code) = error {
    switch code {
    case 403: return "Community profiles aren't available on this device yet."
    case 409: return "That username is already taken. Pick another."
    case 429: return "Too many requests. Try again in a moment."
    default:  return "Profile request failed with HTTP \(code)."
    }
  }
  return error.localizedDescription
}
