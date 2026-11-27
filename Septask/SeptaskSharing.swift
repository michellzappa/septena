import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Shared projects (docs/PROJECT_SHARING_SPEC.md §8): the Share Project screen,
// Join a Shared Project and Assign To, the same on iPhone, iPad and Mac. All
// copy comes from `registry/surfaces.json` (`sharing`). Who shares a project
// comes from the synced project row (`ProjectShare`); invites and changes go
// to the server.

@MainActor
enum SeptaskSharing {
  private static var context: ModelContext { LocalStore.shared.container.mainContext }

  static func present(projectID: String) {
    show { close in ShareProjectView(projectID: projectID, onClose: close).modelContainer(LocalStore.shared.container) }
  }

  /// `link`: the invite the user opened; nil asks for it.
  static func presentJoin(link: String? = nil) {
    show { close in JoinShareView(link: link ?? "", onClose: close) }
  }

  /// Assign To ▸ (row menu slot `assignees`). One tick when every task has
  /// the same assignee.
  static func assigneeNodes(_ tasks: [SeptenaTask]) -> [RegistryMenuNode] {
    let current = Set(tasks.map(\.assignedTo))
    return SharedProjects.assignees(for: tasks, in: context).map { person in
      RegistryMenuEntry.slot(id: "assignee.\(person.id)", title: person.name,
                             isOn: current == [person.memberID]) {
        TaskUndo.setAssignee(ids: tasks.map(\.id), memberID: person.memberID,
                             context: context, mutator: SeptenaServices.shared.taskMutator)
      }
    }
  }

  /// One line for a failed call. A plan limit says what the server said.
  static func message(for error: Error) -> String {
    guard let error = error as? TaskBackendError else { return RegistrySharing.failed }
    switch error {
    case .limitReached(let limit): return limit.userMessage
    case .notSignedIn: return RegistrySharing.signInFirst
    case .http(_, let code) where code == "share_full": return RegistrySharing.full
    case .http(let status, _) where status == 404: return RegistrySharing.invalid
    default: return RegistrySharing.failed
    }
  }

  #if os(macOS)
  private static func show<V: View>(@ViewBuilder _ content: (@escaping () -> Void) -> V) {
    guard let parent = NSApp.keyWindow ?? SeptaskKitWindowController.existing?.window,
          parent.attachedSheet == nil else { return }
    var window: NSWindow?
    let host = NSHostingController(rootView: content {
      guard let sheet = window else { return }
      sheet.sheetParent?.endSheet(sheet)
      window = nil
    }.frame(width: 440, height: 480))
    let sheet = NSWindow(contentViewController: host)
    sheet.styleMask = [.titled]
    window = sheet
    parent.beginSheet(sheet)
  }
  #else
  private static func show<V: View>(@ViewBuilder _ content: (@escaping () -> Void) -> V) {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
      ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
      var top = scene.keyWindow?.rootViewController else { return }
    while let presented = top.presentedViewController { top = presented }
    weak var presenter = top
    let host = UIHostingController(rootView: content { presenter?.dismiss(animated: true) })
    host.modalPresentationStyle = .formSheet
    top.present(host, animated: true)
  }
  #endif
}

/// The name other members see. Starts as the profile name.
private struct ShareNameField: View {
  @Binding var name: String

  var body: some View {
    TextField(RegistrySharing.name, text: $name)
      .textContentType(.name)
  }
}

private struct ShareProjectView: View {
  let projectID: String
  let onClose: () -> Void

  @Query private var projects: [ProjectEntity]
  @AppStorage(SettingsKey.welcomeName) private var welcomeName: String = RegistrySettings.Defaults.welcomeName
  @State private var name = ""
  /// The answer of the call that started the share, until the project row
  /// brings it by sync.
  @State private var started: ProjectShare?
  @State private var invites: [BackendShareDetails.Invite] = []
  @State private var link: URL?
  @State private var working = false
  @State private var message: String?
  @State private var confirmsEnd = false

  init(projectID: String, onClose: @escaping () -> Void) {
    self.projectID = projectID
    self.onClose = onClose
    _projects = Query(filter: #Predicate<ProjectEntity> { $0.id == projectID })
  }

  private var share: ProjectShare? { projects.first?.share ?? started }

  var body: some View {
    NavigationStack {
      Form {
        if let share {
          members(share)
          if share.isOwner { inviting(share) }
          ending(share)
        } else {
          starting
        }
        if let message {
          Text(message).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(projects.first?.title ?? RegistrySharing.title)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: onClose)
        }
      }
    }
    .disabled(working)
    .onAppear { if name.isEmpty { name = welcomeName } }
    .task(id: share?.id) { await load() }
  }

  private var starting: some View {
    Section {
      ShareNameField(name: $name)
      Button(RegistrySharing.start) {
        run {
          let made = try await TaskBackendClient.shared.createShare(projectID: projectID, name: trimmedName)
          started = made
          await TaskSyncEngine.shared.syncNow()
        }
      }
      .disabled(trimmedName.isEmpty)
    } footer: {
      Text(RegistrySharing.intro)
    }
  }

  private func members(_ share: ProjectShare) -> some View {
    Section(RegistrySharing.members) {
      ForEach(share.members) { member in
        HStack {
          Text(member.name)
          if member.id == share.me {
            Text(RegistrySharing.you).foregroundStyle(.secondary)
          }
          Spacer()
          if member.isOwner {
            Text(RegistrySharing.owner).foregroundStyle(.secondary)
          } else if share.isOwner {
            Button(RegistrySharing.remove, role: .destructive) {
              run {
                try await TaskBackendClient.shared.endShareMembership(shareID: share.id, memberID: member.id)
                await TaskSyncEngine.shared.syncNow()
              }
            }
            .buttonStyle(.borderless)
          }
        }
      }
    }
  }

  private func inviting(_ share: ProjectShare) -> some View {
    Section {
      if let link {
        ShareLink(item: link) {
          Label(link.absoluteString, systemImage: RegistryIcons.sfSymbol(for: "action.share"))
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Button(RegistrySharing.invite) {
        run {
          link = try await TaskBackendClient.shared.inviteToShare(id: share.id)
          await load()
        }
      }
      ForEach(invites) { invite in
        HStack {
          VStack(alignment: .leading) {
            Text(RegistrySharing.invites)
            Text("\(RegistrySharing.expires) \(Date(timeIntervalSince1970: invite.expiresAt / 1000).formatted(date: .abbreviated, time: .omitted))")
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button(RegistrySharing.revoke, role: .destructive) {
            run {
              try await TaskBackendClient.shared.revokeShareInvite(shareID: share.id, inviteID: invite.id)
              link = nil
              await load()
            }
          }
          .buttonStyle(.borderless)
        }
      }
    } footer: {
      Text(RegistrySharing.inviteNote)
    }
  }

  private func ending(_ share: ProjectShare) -> some View {
    Section {
      Button(share.isOwner ? RegistrySharing.stop : RegistrySharing.leave, role: .destructive) { confirmsEnd = true }
        .confirmationDialog(share.isOwner ? RegistrySharing.stop : RegistrySharing.leave,
                            isPresented: $confirmsEnd, titleVisibility: .visible) {
          Button(share.isOwner ? RegistrySharing.stop : RegistrySharing.leave, role: .destructive) {
            run {
              if share.isOwner {
                try await TaskBackendClient.shared.stopSharing(id: share.id)
              } else {
                try await TaskBackendClient.shared.endShareMembership(shareID: share.id, memberID: share.me)
              }
              await TaskSyncEngine.shared.syncNow()
              onClose()
            }
          }
        } message: {
          Text(share.isOwner ? RegistrySharing.stopDetail : RegistrySharing.leaveDetail)
        }
    } footer: {
      Text(share.isOwner ? RegistrySharing.stopDetail : RegistrySharing.leaveDetail)
    }
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func load() async {
    guard let share, share.isOwner,
          let details = try? await TaskBackendClient.shared.shareDetails(id: share.id) else { return }
    invites = details.invites
  }

  private func run(_ work: @escaping () async throws -> Void) {
    working = true
    message = nil
    Task {
      do {
        try await work()
      } catch {
        message = SeptaskSharing.message(for: error)
      }
      working = false
    }
  }
}

private struct JoinShareView: View {
  @State var link: String
  let onClose: () -> Void

  @AppStorage(SettingsKey.welcomeName) private var welcomeName: String = RegistrySettings.Defaults.welcomeName
  @State private var name = ""
  @State private var preview: BackendSharePreview?
  @State private var working = false
  @State private var message: String?

  init(link: String, onClose: @escaping () -> Void) {
    _link = State(initialValue: link)
    self.onClose = onClose
  }

  private var token: String? { SharedProjects.inviteToken(in: link) }
  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var signedIn: Bool { TaskSyncEngine.shared.signedIn }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if let preview {
            LabeledContent(preview.title, value: "\(RegistrySharing.sharedBy) \(preview.from)")
            ShareNameField(name: $name)
          } else {
            TextField(RegistrySharing.joinLink, text: $link)
              .autocorrectionDisabled()
              #if os(iOS)
              .textInputAutocapitalization(.never)
              .keyboardType(.URL)
              #endif
          }
        } footer: {
          Text(signedIn ? RegistrySharing.joinDetail : RegistrySharing.signInFirst)
        }
        if let message {
          Text(message).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(RegistrySharing.joinTitle)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(RegistryPrompts.cancelTitle, action: onClose)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(RegistrySharing.join) { join() }
            .disabled(preview == nil || trimmedName.isEmpty || working)
        }
      }
    }
    .onAppear { if name.isEmpty { name = welcomeName } }
    .task(id: "\(token ?? "")|\(signedIn)") { await look() }
  }

  private func look() async {
    guard signedIn, let token else { return }
    do {
      preview = try await TaskBackendClient.shared.previewShare(token: token)
      message = nil
    } catch {
      if !Task.isCancelled { message = SeptaskSharing.message(for: error) }
    }
  }

  private func join() {
    guard let token else { return }
    working = true
    Task {
      do {
        _ = try await TaskBackendClient.shared.joinShare(token: token, name: trimmedName)
        await TaskSyncEngine.shared.syncNow()
        onClose()
      } catch {
        message = SeptaskSharing.message(for: error)
        working = false
      }
    }
  }
}
