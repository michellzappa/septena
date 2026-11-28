import SwiftUI

// MARK: - Notes proposal card (ADR 0012, docs/PROJECT_NOTES_SPEC.md §6, #123)

/// Compact review card rendered directly above a project's or area's notes when
/// an agent has proposed a new brief via `tasks_notes_propose`.
struct NotesProposalCard: View {
  let proposal: NotesProposal
  let currentNotes: String
  let onAccept: () -> Void
  let onReject: () -> Void

  private var diffLines: [NotesDiffLine] {
    ContainerNotes.diffLines(from: currentNotes, to: proposal.body)
  }

  private var hasLog: Bool {
    ContainerNotes.hasLog(currentNotes)
  }

  private var timeLabel: String {
    TaskHistory.relative(proposal.date, now: DayClock.appNow)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "sparkles")
          .font(.septenaLabel)
          .foregroundStyle(Color.accentColor)
        Text(ContainerNotesCopy.proposalHeading(agent: proposal.displayAgent))
          .font(.septenaLabel.weight(.semibold))
          .foregroundStyle(Theme.inkPrimary)
        Spacer(minLength: 8)
        if !timeLabel.isEmpty {
          Text(timeLabel)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
        }
      }

      if let why = proposal.why?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty {
        Text(why)
          .font(.septenaNotes)
          .foregroundStyle(Theme.inkPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }

      diffBox

      if hasLog {
        Text(ContainerNotesCopy.logPreservedHint)
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
      }

      HStack(spacing: 8) {
        Button(ContainerNotesCopy.acceptButton, action: onAccept)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        Button(ContainerNotesCopy.rejectButton, action: onReject)
          .buttonStyle(.bordered)
          .controlSize(.small)
        Spacer()
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
        .fill(Theme.cardSurface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
    )
  }

  @ViewBuilder
  private var diffBox: some View {
    let lines = diffLines
    if lines.isEmpty {
      Text(ContainerNotesCopy.noChangesInBrief)
        .font(.septenaMeta)
        .foregroundStyle(Theme.inkSecondary)
        .padding(.vertical, 4)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(lines) { line in
            diffRow(line)
          }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 180)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Theme.mutedSurface)
      )
    }
  }

  @ViewBuilder
  private func diffRow(_ line: NotesDiffLine) -> some View {
    switch line.kind {
    case .added:
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("+")
          .font(.system(.caption, design: .monospaced).weight(.semibold))
          .foregroundStyle(.green)
        Text(line.text.isEmpty ? " " : line.text)
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(Color.green.opacity(0.11), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    case .removed:
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("−")
          .font(.system(.caption, design: .monospaced).weight(.semibold))
          .foregroundStyle(.red)
        Text(line.text.isEmpty ? " " : line.text)
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
          .strikethrough(true, color: .red.opacity(0.6))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    case .context:
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(" ")
          .font(.system(.caption, design: .monospaced))
        Text(line.text.isEmpty ? " " : line.text)
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 4)
    case .separator:
      Text(line.text)
        .font(.septenaMeta)
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
    }
  }
}

// MARK: - Notes history sheet with preview & restore (#123)

/// Lists every saved revision of a project's or area's notes, newest first,
/// with read-only preview and Restore (which writes a new revision through the
/// mutator without deleting any history).
struct NotesHistorySheet: View {
  let container: ContainerNotes.Container
  let containerID: String
  let containerTitle: String
  let currentNotes: String
  let onRestore: (String) -> Void
  var onClose: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  @State private var revisions: [BackendNoteRevision] = []
  @State private var latestRev: Int = 0
  @State private var selectedRev: Int?
  @State private var isLoading = true
  @State private var isLoadingMore = false
  @State private var canLoadMore = false
  @State private var failed = false

  private static let pageSize = 50

  private var selectedRevision: BackendNoteRevision? {
    guard let selectedRev else { return revisions.first }
    return revisions.first { $0.rev == selectedRev }
  }

  private func close() {
    if let onClose {
      onClose()
    } else {
      dismiss()
    }
  }

  var body: some View {
    #if os(macOS)
    macBody
    #else
    iosBody
    #endif
  }

  #if os(macOS)
  private var macBody: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(ContainerNotesCopy.historyMenuTitle)
            .font(.headline)
          if !containerTitle.isEmpty {
            Text(containerTitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button("Done") { close() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      Divider()

      if !TaskHistory.isAvailable {
        placeholderState(ContainerNotesCopy.signInForHistory)
      } else if isLoading {
        VStack(spacing: 8) {
          ProgressView()
          Text(ContainerNotesCopy.loadingHistory)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if failed {
        placeholderState(ContainerNotesCopy.failedHistory)
      } else if revisions.isEmpty {
        placeholderState(ContainerNotesCopy.emptyHistory)
      } else {
        HStack(spacing: 0) {
          List(selection: $selectedRev) {
            ForEach(revisions) { rev in
              revisionRow(rev)
                .tag(rev.rev)
            }
            if canLoadMore {
              loadMoreRow
            }
          }
          .listStyle(.sidebar)
          .frame(width: 230)

          Divider()

          if let rev = selectedRevision {
            revisionDetailPane(rev)
          } else {
            placeholderState(ContainerNotesCopy.selectRevisionPrompt)
          }
        }
      }
    }
    .frame(width: 660, height: 460)
    .task(id: containerID) { await loadInitial() }
  }
  #endif

  #if !os(macOS)
  private var iosBody: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if !TaskHistory.isAvailable {
          placeholderState(ContainerNotesCopy.signInForHistory)
        } else if isLoading {
          VStack(spacing: 8) {
            ProgressView()
            Text(ContainerNotesCopy.loadingHistory)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if failed {
          placeholderState(ContainerNotesCopy.failedHistory)
        } else if revisions.isEmpty {
          placeholderState(ContainerNotesCopy.emptyHistory)
        } else {
          List {
            ForEach(revisions) { rev in
              NavigationLink {
                revisionDetailPane(rev)
                  .navigationTitle(ContainerNotesCopy.revisionTitle(rev.rev))
                  .navigationBarTitleDisplayMode(.inline)
              } label: {
                revisionRow(rev)
              }
            }
            if canLoadMore {
              loadMoreRow
            }
          }
          .listStyle(.insetGrouped)
        }
      }
      .navigationTitle(ContainerNotesCopy.historyMenuTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { close() }
            .keyboardShortcut(.cancelAction)
        }
      }
    }
    .task(id: containerID) { await loadInitial() }
  }
  #endif

  private func placeholderState(_ message: String) -> some View {
    Text(message)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func revisionRow(_ rev: BackendNoteRevision) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(rev.who)
          .font(.subheadline.weight(rev.byAgent ? .semibold : .medium))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 4)
        if rev.rev == latestRev {
          Text(ContainerNotesCopy.currentBadge)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.accentColor)
        } else {
          Text(ContainerNotesCopy.versionLabel(rev.rev))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      if let date = rev.date {
        Text(TaskHistory.relative(date, now: DayClock.appNow))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let reason = rev.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 2)
  }

  private func revisionDetailPane(_ rev: BackendNoteRevision) -> some View {
    let bodyText = rev.body ?? ""
    let matchesCurrent = bodyText == currentNotes
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(rev.who)
              .font(.subheadline.weight(rev.byAgent ? .semibold : .medium))
            Text(ContainerNotesCopy.versionLabel(rev.rev))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let date = rev.date {
            Text(date.formatted(date: .abbreviated, time: .shortened))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let reason = rev.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            Text(reason)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button(ContainerNotesCopy.restoreButton) {
          onRestore(bodyText)
          close()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(matchesCurrent)
      }
      .padding(14)

      Divider()

      ScrollView {
        if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(ContainerNotesCopy.emptyRevisionBody)
            .font(.septenaNotes)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        } else {
          Text(bodyText)
            .font(.septenaNotes)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var loadMoreRow: some View {
    HStack {
      Spacer()
      if isLoadingMore {
        ProgressView().controlSize(.small)
      } else {
        Button(ContainerNotesCopy.loadOlderButton) {
          Task { await loadOlder() }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(Color.accentColor)
      }
      Spacer()
    }
    .padding(.vertical, 6)
  }

  private func loadInitial() async {
    guard TaskHistory.isAvailable else {
      isLoading = false
      return
    }
    isLoading = true
    failed = false
    do {
      let page = try await TaskBackendClient.shared.noteHistory(
        container: container,
        id: containerID,
        before: nil,
        limit: Self.pageSize,
        includeBody: true
      )
      revisions = page.revisions
      latestRev = page.noteRev
      canLoadMore = page.revisions.count >= Self.pageSize
      if selectedRev == nil {
        selectedRev = page.revisions.first?.rev
      }
    } catch is CancellationError {
      return
    } catch {
      revisions = []
      failed = true
    }
    isLoading = false
  }

  private func loadOlder() async {
    guard !isLoadingMore, let oldest = revisions.last?.rev, oldest > 1 else {
      canLoadMore = false
      return
    }
    isLoadingMore = true
    defer { isLoadingMore = false }
    do {
      let page = try await TaskBackendClient.shared.noteHistory(
        container: container,
        id: containerID,
        before: oldest,
        limit: Self.pageSize,
        includeBody: true
      )
      let existing = Set(revisions.map(\.rev))
      let appended = page.revisions.filter { !existing.contains($0.rev) }
      revisions.append(contentsOf: appended)
      canLoadMore = page.revisions.count >= Self.pageSize
    } catch {
      canLoadMore = false
    }
  }
}
