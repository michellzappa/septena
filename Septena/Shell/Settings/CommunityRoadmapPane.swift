import SwiftUI

/// Public feature-request board backed by the community Worker
/// (`/api/features`). Anyone on a genuine app + iCloud can suggest and upvote;
/// maintainers move status, add a note, and lock threads. Authorship is
/// anonymous — only vote/comment counts and the author's role are shown.
struct CommunityRoadmapPane: View {
  @State private var features: [CommunityFeature] = []
  @State private var role = "user"
  @State private var loading = false
  @State private var errorMessage: String?
  @State private var showingComposer = false

  private var canUse: Bool { CommunityClient.shared.appAttestSupported }
  private var isMaintainer: Bool { role == "maintainer" || role == "moderator" }

  var body: some View {
    List {
      if !canUse {
        fallbackSection
      } else {
        if isMaintainer {
          Section {
            Label("You're a maintainer — swipe a comment to moderate, set status in each request.",
                  systemImage: "checkmark.seal.fill")
              .font(.caption).foregroundStyle(.secondary)
          }
        }

        Section {
          Button {
            showingComposer = true
          } label: {
            Label("Suggest a feature", systemImage: "plus.bubble")
          }
        }

        if let errorMessage {
          Section {
            Text(errorMessage).font(.callout).foregroundStyle(.secondary)
          }
        }

        Section("Requests") {
          if loading && features.isEmpty {
            HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
          } else if features.isEmpty {
            ContentUnavailableView("No requests yet", systemImage: "lightbulb",
                                   description: Text("Be the first to suggest a feature."))
          } else {
            ForEach(features) { feature in
              NavigationLink {
                FeatureDetailView(id: feature.id, isMaintainer: isMaintainer) { updated in
                  apply(updated)
                }
              } label: {
                FeatureRow(feature: feature)
              }
              .swipeActions(edge: .leading) {
                Button {
                  Task { await vote(feature, voted: !feature.hasVoted) }
                } label: {
                  Label(feature.hasVoted ? "Remove vote" : "Vote",
                        systemImage: feature.hasVoted ? "arrowtriangle.down" : "arrowtriangle.up")
                }
                .tint(feature.hasVoted ? .gray : .accentColor)
              }
            }
          }
        }

        Section {
          Link(destination: URL(string: "https://septena.app/roadmap")!) {
            Label("View the roadmap on the web", systemImage: "safari")
          }
        } footer: {
          Text("A public, read-only version of this board — handy for sharing.")
        }
      }
    }
    .formStyle(.grouped)
    .task {
      if canUse { await loadRole(); await load() }
    }
    .refreshable {
      if canUse { await load() }
    }
    .sheet(isPresented: $showingComposer) {
      FeatureComposer { detail in
        features.insert(detail.feature, at: 0)
      }
    }
    .toolbar {
      if canUse {
        ToolbarItem(placement: .primaryAction) {
          Button { showingComposer = true } label: { Image(systemName: "plus") }
            .accessibilityLabel("Suggest a feature")
        }
      }
    }
  }

  private var fallbackSection: some View {
    Section {
      Label("The roadmap needs App Attest and iCloud.", systemImage: "lightbulb.slash")
        .foregroundStyle(.secondary)
      Text("This keeps the board tied to the genuine app and your Apple ID without shipping a secret.")
        .font(.footnote).foregroundStyle(.secondary)
    }
  }

  private func apply(_ updated: CommunityFeature) {
    if let i = features.firstIndex(where: { $0.id == updated.id }) {
      features[i] = updated
    }
  }

  @MainActor private func loadRole() async {
    role = (try? await CommunityClient.shared.me().user.role) ?? role
  }

  @MainActor private func load() async {
    loading = true
    defer { loading = false }
    do {
      features = try await CommunityClient.shared.features()
      errorMessage = nil
    } catch {
      errorMessage = communityRoadmapErrorText(error)
    }
  }

  @MainActor private func vote(_ feature: CommunityFeature, voted: Bool) async {
    do {
      let result = try await CommunityClient.shared.voteFeature(id: feature.id, voted: voted)
      apply(result.feature)
    } catch {
      errorMessage = communityRoadmapErrorText(error)
    }
  }
}

private struct FeatureRow: View {
  let feature: CommunityFeature

  var body: some View {
    HStack(spacing: 12) {
      VStack(spacing: 2) {
        Image(systemName: feature.hasVoted ? "arrowtriangle.up.fill" : "arrowtriangle.up")
          .font(.callout)
          .foregroundStyle(feature.hasVoted ? Color.accentColor : .secondary)
        Text("\(feature.voteCount)")
          .font(.caption.weight(.semibold).monospacedDigit())
          .foregroundStyle(feature.hasVoted ? Color.accentColor : .secondary)
      }
      .frame(width: 36)

      VStack(alignment: .leading, spacing: 4) {
        Text(feature.title).font(.body).lineLimit(2)
        HStack(spacing: 8) {
          FeatureStatusBadge(status: feature.status)
          if let by = feature.author?.label {
            Text(by).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          if feature.commentCount > 0 {
            Label("\(feature.commentCount)", systemImage: "bubble.left")
              .font(.caption).foregroundStyle(.secondary)
          }
          if feature.isLocked {
            Image(systemName: "lock").font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(.vertical, 2)
  }
}

private struct FeatureDetailView: View {
  let id: String
  var isMaintainer: Bool = false
  var onChange: (CommunityFeature) -> Void = { _ in }

  @State private var detail: CommunityFeatureDetail?
  @State private var comment = ""
  @State private var replyingTo: CommunityFeatureComment?
  @State private var loading = false
  @State private var busy = false
  @State private var errorMessage: String?

  /// Flat comment list flattened into one-level threads: each top-level comment
  /// followed by its replies (chronological). Mirrors the worker's one-deep model.
  private var threadedComments: [(comment: CommunityFeatureComment, isReply: Bool)] {
    let all = detail?.comments ?? []
    let tops = all.filter { ($0.parentId ?? "").isEmpty }
    let repliesByParent = Dictionary(grouping: all.filter { !($0.parentId ?? "").isEmpty }) { $0.parentId ?? "" }
    var out: [(CommunityFeatureComment, Bool)] = []
    for top in tops {
      out.append((top, false))
      for reply in (repliesByParent[top.id] ?? []).sorted(by: { $0.createdAt < $1.createdAt }) {
        out.append((reply, true))
      }
    }
    return out
  }

  var body: some View {
    List {
      if let f = detail?.feature {
        Section {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(f.title).font(.headline)
              Spacer()
              FeatureStatusBadge(status: f.status)
            }
            if let d = f.detail, !d.isEmpty {
              Text(d).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let by = f.author?.label {
              Label("Suggested by \(by)", systemImage: "person.crop.circle")
                .font(.caption).foregroundStyle(.secondary)
            }
            Button {
              Task { await vote(!f.hasVoted) }
            } label: {
              Label("\(f.voteCount) \(f.voteCount == 1 ? "vote" : "votes")",
                    systemImage: f.hasVoted ? "arrowtriangle.up.fill" : "arrowtriangle.up")
            }
            .buttonStyle(.bordered)
            .tint(f.hasVoted ? .accentColor : .gray)
            .disabled(busy)
          }
          .padding(.vertical, 4)
        }

        if let note = f.maintainerNote, !note.isEmpty {
          Section("Maintainer note") {
            Text(note).font(.callout)
          }
        }

        if isMaintainer {
          maintainerSection(for: f)
        }
      }

      if let errorMessage {
        Section { Text(errorMessage).font(.callout).foregroundStyle(.secondary) }
      }

      Section("Comments") {
        if loading && detail == nil {
          HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
        } else if threadedComments.isEmpty {
          Text("No comments yet.").font(.callout).foregroundStyle(.secondary)
        } else {
          ForEach(threadedComments, id: \.comment.id) { item in
            FeatureCommentRow(comment: item.comment, isReply: item.isReply)
              .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if canReply {
                  Button {
                    replyingTo = item.comment
                  } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                  .tint(.accentColor)
                }
                if isMaintainer {
                  Button(role: .destructive) {
                    Task { await moderate(item.comment, status: "deleted") }
                  } label: { Label("Delete", systemImage: "trash") }
                  Button {
                    Task { await moderate(item.comment, status: item.comment.status == "hidden" ? "visible" : "hidden") }
                  } label: {
                    Label(item.comment.status == "hidden" ? "Unhide" : "Hide",
                          systemImage: item.comment.status == "hidden" ? "eye" : "eye.slash")
                  }
                  .tint(.orange)
                  Button {
                    Task { await moderate(item.comment, isPinned: !item.comment.isPinned) }
                  } label: {
                    Label(item.comment.isPinned ? "Unpin" : "Pin", systemImage: "pin")
                  }
                  .tint(.yellow)
                }
              }
          }
        }
      }

      if isMaintainer || !(detail?.feature.isLocked ?? false) {
        Section {
          if let replyingTo {
            HStack {
              Label("Replying to \(replyTargetLabel(replyingTo))", systemImage: "arrowshape.turn.up.left")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
              Spacer()
              Button("Cancel") { self.replyingTo = nil }
                .font(.caption)
            }
          }
          TextEditor(text: $comment).frame(minHeight: 80)
          Button {
            Task { await postComment() }
          } label: {
            if busy { ProgressView() }
            else { Label(replyingTo == nil ? "Post" : "Post reply", systemImage: "paperplane") }
          }
          .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        } header: {
          Text(replyingTo == nil ? "Add comment" : "Reply")
        }
      } else {
        Section {
          Label("This thread is locked.", systemImage: "lock").foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Request")
    .task { await load() }
    .refreshable { await load() }
  }

  @ViewBuilder
  private func maintainerSection(for f: CommunityFeature) -> some View {
    Section {
      Picker("Status", selection: Binding(
        get: { f.status },
        set: { newValue in Task { await setStatus(newValue) } }
      )) {
        ForEach(featureStatusOrder, id: \.self) { s in
          Text(featureStatusLabel(s)).tag(s)
        }
      }
      Toggle("Lock thread", isOn: Binding(
        get: { f.isLocked },
        set: { newValue in Task { await setLocked(newValue) } }
      ))
    } header: {
      Text("Maintainer")
    } footer: {
      Text("Status shows on the board. Locking stops non-maintainers from commenting.")
    }
  }

  @MainActor private func load() async {
    loading = true
    defer { loading = false }
    do {
      detail = try await CommunityClient.shared.feature(id: id)
      errorMessage = nil
    } catch {
      errorMessage = communityRoadmapErrorText(error)
    }
  }

  @MainActor private func vote(_ voted: Bool) async {
    busy = true; defer { busy = false }
    await run { try await CommunityClient.shared.voteFeature(id: id, voted: voted) }
  }

  private var canReply: Bool {
    isMaintainer || !(detail?.feature.isLocked ?? false)
  }

  private func replyTargetLabel(_ c: CommunityFeatureComment) -> String {
    if c.authorRole == "maintainer" { return "Septena" }
    if c.authorRole == "moderator" { return "Moderator" }
    return c.author?.label ?? "a comment"
  }

  @MainActor private func postComment() async {
    let body = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return }
    let parent = replyingTo?.id
    busy = true; defer { busy = false }
    await run { try await CommunityClient.shared.commentFeature(id: id, body: body, parentId: parent) }
    if errorMessage == nil { comment = ""; replyingTo = nil }
  }

  @MainActor private func moderate(_ c: CommunityFeatureComment, status: String? = nil, isPinned: Bool? = nil) async {
    busy = true; defer { busy = false }
    await run { try await CommunityClient.shared.moderateComment(featureID: id, commentID: c.id, status: status, isPinned: isPinned) }
  }

  @MainActor private func setStatus(_ status: String) async {
    busy = true; defer { busy = false }
    await run { try await CommunityClient.shared.updateFeature(id: id, status: status) }
  }

  @MainActor private func setLocked(_ locked: Bool) async {
    busy = true; defer { busy = false }
    await run { try await CommunityClient.shared.updateFeature(id: id, isLocked: locked) }
  }

  @MainActor private func run(_ op: () async throws -> CommunityFeatureDetail) async {
    do {
      let result = try await op()
      detail = result
      onChange(result.feature)
      errorMessage = nil
    } catch {
      errorMessage = communityRoadmapErrorText(error)
    }
  }
}

private struct FeatureCommentRow: View {
  let comment: CommunityFeatureComment
  var isReply: Bool = false

  private var isHidden: Bool { comment.status == "hidden" }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        if isReply {
          Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
        }
        Label(commentAuthorLabel(role: comment.authorRole, author: comment.author),
              systemImage: commentAuthorIcon(comment.authorRole))
          .font(.caption.weight(.semibold))
        if comment.isPinned {
          Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
        }
        if isHidden {
          Text("Hidden")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.16), in: Capsule())
            .foregroundStyle(.orange)
        }
        Spacer()
        Text(comment.createdAt).font(.caption2).foregroundStyle(.tertiary)
      }
      Text(comment.body).font(.callout).textSelection(.enabled)
        .foregroundStyle(isHidden ? .secondary : .primary)
    }
    .padding(.vertical, 4)
    .padding(.leading, isReply ? 20 : 0)
  }
}

private struct FeatureComposer: View {
  let onCreated: (CommunityFeatureDetail) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var detail = ""
  @State private var sending = false
  @State private var errorMessage: String?

  private var canSend: Bool {
    title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && !sending
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Title", text: $title)
          TextEditor(text: $detail).frame(minHeight: 140)
        } footer: {
          Text("A short title and, optionally, the problem you're trying to solve.")
        }
        if let errorMessage {
          Section { Text(errorMessage).font(.callout).foregroundStyle(.secondary) }
        }
      }
      .navigationTitle("Suggest a feature")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await create() }
          } label: {
            if sending { ProgressView() } else { Text("Submit") }
          }
          .disabled(!canSend)
        }
      }
    }
  }

  @MainActor private func create() async {
    sending = true; defer { sending = false }
    do {
      let result = try await CommunityClient.shared.createFeature(
        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
        detail: detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
          : detail.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      onCreated(result)
      dismiss()
    } catch {
      errorMessage = communityRoadmapErrorText(error)
    }
  }
}

private struct FeatureStatusBadge: View {
  let status: String
  var body: some View {
    Text(featureStatusLabel(status))
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(featureStatusTint(status).opacity(0.14), in: Capsule())
      .foregroundStyle(featureStatusTint(status))
  }
}

private let featureStatusOrder = ["pending", "approved", "planned", "in_progress", "shipped", "rejected", "merged"]

private func featureStatusLabel(_ s: String) -> String {
  switch s {
  case "pending": return "Pending"
  case "approved": return "Approved"
  case "planned": return "Planned"
  case "in_progress": return "In progress"
  case "shipped": return "Shipped"
  case "rejected": return "Declined"
  case "merged": return "Merged"
  default: return s
  }
}

private func featureStatusTint(_ s: String) -> Color {
  switch s {
  case "shipped": return .green
  case "in_progress": return .orange
  case "approved", "planned": return .blue
  case "rejected", "merged": return .secondary
  default: return .gray
  }
}

private func commentAuthorLabel(role: String, author: CommunityAuthor?) -> String {
  switch role {
  case "maintainer": return "Septena"
  case "moderator": return "Moderator"
  default: return author?.label ?? "Member"
  }
}

private func commentAuthorIcon(_ role: String) -> String {
  switch role {
  case "maintainer": return "checkmark.seal.fill"
  case "moderator": return "shield"
  default: return "person.crop.circle"
  }
}

private func communityRoadmapErrorText(_ error: Error) -> String {
  if case CommunityClient.ClientError.cloudKitUserUnavailable = error {
    return "iCloud is unavailable. Sign in to iCloud and try again."
  }
  if case CommunityClient.ClientError.badResponse(let code) = error {
    switch code {
    case 403: return "The roadmap isn't available on this device yet."
    case 409: return "This thread is locked."
    case 429: return "Too many requests. Try again in a moment."
    default:  return "Request failed with HTTP \(code)."
    }
  }
  return error.localizedDescription
}
