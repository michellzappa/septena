import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Task references (docs/TASK_REFERENCES_SPEC.md §8): the gestures both shells
// share, and the SwiftUI References block and Add Reference sheet. The AppKit
// shell draws the same rows in `Septask/SeptaskKitReferences.swift`.

// MARK: - Gestures

/// Add, open, copy and remove. Undo registers here, at the gesture.
@MainActor
enum TaskRefActions {
  private static var mutator: TaskMutator { SeptenaServices.shared.taskMutator }
  private static var context: ModelContext { LocalStore.shared.container.mainContext }

  /// Add Reference shows only in a build whose core reads a key.
  static var canAdd: Bool {
    TaskRefCore.isAvailable && RegistryActions.isAvailableOnPlatform(.taskAddReference)
  }

  /// The links of a task's text that the References block suggests.
  static func suggestions(taskID: String, title: String, notes: String?) -> [TaskRefRows.Offer] {
    guard canAdd else { return [] }
    return TaskRefRows.suggestions(title: title, notes: notes,
                                   existing: LocalCache.taskRefs(forTaskID: taskID, in: context))
  }

  static func add(_ input: String, to taskID: String) -> TaskRefAddResult {
    let result = mutator.addTaskRef(taskID: taskID, input: input)
    if case .added(let ref) = result {
      TaskUndo.recordTaskRefAdd(ref, mutator: mutator)
      Haptics.commit()
    }
    return result
  }

  /// The line under the field. Nil when the result needs none.
  static func message(for result: TaskRefAddResult) -> String? {
    switch result {
    case .added, .existing: return nil
    case .invalid: return RegistryTaskReferences.invalidMessage
    case .limitReached:
      return RegistryTaskReferences.limitReached(count: RegistryEntityLimits.maxRefsPerTask)
    case .unavailable, .failed: return RegistryTaskReferences.failedMessage
    }
  }

  /// One gesture, so every reference of the row comes back with one undo.
  static func remove(_ row: TaskRefRow) {
    for ref in row.refs where mutator.removeTaskRef(id: ref.id) {
      TaskUndo.recordTaskRefRemove(ref, mutator: mutator)
    }
    Haptics.warning()
  }

  /// `navigation` is the window's own in the SwiftUI shell, nil in AppKit.
  static func open(_ row: TaskRefRow, navigation: NavigationState?) {
    switch row.target {
    case .url(let url): open(url)
    case .task(let id): openTask(id, navigation: navigation)
    case nil: break
    }
  }

  static func openTask(_ id: String, navigation: NavigationState?) {
    if let navigation {
      SeptaskDeepLinkRouter.openTask(id, opensPage: true, navigation: navigation, context: context)
    } else {
      #if os(macOS)
      SeptaskDeepLinkRouter.openTaskMac(id, opensPage: true)
      #endif
    }
  }

  /// The other open tasks that point at the same things (§6.4).
  static func alsoIn(taskID: String, title: String, notes: String?) -> [TaskRefLookup.Other] {
    TaskRefLookup.alsoIn(taskID: taskID, title: title, notes: notes, in: context)
  }

  private static func open(_ url: URL) {
    guard TaskRefResolver.canOpen(url) else { return }
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
  }

  static func copyLink(_ row: TaskRefRow) {
    guard let link = row.link else { return }
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(link.absoluteString, forType: .string)
    #else
    UIPasteboard.general.string = link.absoluteString
    #endif
  }

  /// The row's context menu (registry `task.reference`), for both shells.
  static func bind(_ id: RegistryActionID, row: TaskRefRow, navigation: NavigationState?) -> RegistryActionBinding? {
    switch id {
    case .taskReferenceOpen:
      guard row.target != nil else { return nil }
      return .init { open(row, navigation: navigation) }
    case .taskReferenceCopyLink:
      guard row.link != nil else { return nil }
      return .init { copyLink(row) }
    case .taskReferenceRemove:
      return .init { remove(row) }
    default:
      return nil
    }
  }
}

// MARK: - Row

/// Kind icon, title, subtitle.
private struct TaskReferenceRowLabel: View {
  let title: String
  let subtitle: String?
  let sfSymbol: String

  init(row: TaskRefRow) {
    title = row.title
    subtitle = row.subtitle
    sfSymbol = row.sfSymbol
  }

  var body: some View {
    HStack(spacing: Theme.iconTextGap) {
      Image(systemName: sfSymbol)
        .font(.septenaSidebarRow)
        .foregroundStyle(Theme.inkSecondary)
        .frame(width: 22)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.septenaSidebarRow)
          .foregroundStyle(Theme.inkPrimary)
          .lineLimit(2)
        if let subtitle {
          Text(subtitle)
            .font(.septenaCaption)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

// MARK: - References block

/// The task page's References block (`taskPage.references`). The host draws
/// the heading. The inline editor passes no `onAdd` and shows the panel only
/// for a task that has references, so it shows the rows alone.
struct TaskReferencesPanel: View {
  let taskID: String
  var onAdd: (() -> Void)?

  @Environment(NavigationState.self) private var navigation: NavigationState?
  @State private var rows: [TaskRefRow] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(rows) { row in
        Button { TaskRefActions.open(row, navigation: navigation) } label: {
          TaskReferenceRowLabel(row: row)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .contextMenu {
          RegistryMenuContent(nodes: RegistryMenuResolver.resolve(
            RegistryActions.menu(.taskReference),
            bind: { TaskRefActions.bind($0, row: row, navigation: navigation) }))
        }
        if addAction != nil || row.id != rows.last?.id {
          Divider().padding(.horizontal, 12)
        }
      }
      if let addAction {
        Button(action: addAction) {
          HStack(spacing: Theme.iconTextGap) {
            Image(systemName: "plus")
              .font(.septenaSidebarRow)
              .foregroundStyle(Theme.inkSecondary)
              .frame(width: 22)
            Text(RegistryActions.title(.taskAddReference))
              .font(.septenaSidebarRow)
              .foregroundStyle(Theme.inkPrimary)
            Spacer(minLength: 8)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 11)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .background(Theme.secondaryGroupedBackground,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .onAppear(perform: reload)
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in reload() }
  }

  private var addAction: (() -> Void)? { TaskRefActions.canAdd ? onAdd : nil }

  private func reload() {
    rows = LocalCache.taskRefRows(forTaskID: taskID, in: LocalStore.shared.container.mainContext)
  }
}

// MARK: - Suggestions

/// Under the References block: the links of the task's text that are not
/// references yet (a tap makes the reference and leaves the text as it is),
/// then the other open tasks that point at the same things (a tap opens one).
struct TaskReferenceSuggestions: View {
  let offers: [TaskRefRows.Offer]
  let others: [TaskRefLookup.Other]
  let onTake: (TaskRefRows.Offer) -> Void

  @Environment(NavigationState.self) private var navigation: NavigationState?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(offers) { offer in
        chip(offer.title, icon: "plus", stroke: StrokeStyle(lineWidth: 1, dash: [3, 3])) { onTake(offer) }
          .accessibilityLabel(RegistryTaskReferences.suggestion(name: offer.title))
      }
      ForEach(others) { other in
        chip(RegistryTaskReferences.alsoIn(name: other.title),
             icon: RegistryTaskReferences.kind("task").sfSymbol, stroke: StrokeStyle(lineWidth: 1)) {
          TaskRefActions.openTask(other.id, navigation: navigation)
        }
      }
    }
  }

  private func chip(_ title: String, icon: String, stroke: StrokeStyle,
                    action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: icon)
        Text(title)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(.septenaCaption)
      .foregroundStyle(Theme.inkSecondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .overlay(Capsule().strokeBorder(Theme.inkSecondary.opacity(0.35), style: stroke))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Add Reference

/// Paste a link, or take one that is in the task's title or notes already.
struct AddReferenceSheet: View {
  let taskID: String

  @Environment(\.dismiss) private var dismiss
  @FocusState private var fieldFocused: Bool
  @State private var text = ""
  @State private var message: String?
  @State private var offers: [TaskRefRows.Offer] = []
  @State private var rows: [TaskRefRow] = []
  /// The row of a key that the task has already.
  @State private var highlightedID: String?

  private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        List {
          Section {
            TextField(RegistryTaskReferences.addPlaceholder, text: $text)
              .focused($fieldFocused)
              .autocorrectionDisabled()
              #if os(iOS)
              .textInputAutocapitalization(.never)
              .keyboardType(.URL)
              #endif
              .submitLabel(.done)
              .onSubmit(submit)
              .onChange(of: text) { _, _ in
                message = nil
                highlightedID = nil
              }
            if let message {
              Text(message)
                .font(.septenaCaption)
                .foregroundStyle(Theme.overdueRed)
            }
          }
          if !offers.isEmpty {
            Section(RegistryTaskReferences.offersTitle) {
              ForEach(offers) { offer in
                Button { take(offer) } label: {
                  Label(offer.title, systemImage: offer.sfSymbol)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
              }
            }
          }
          if !rows.isEmpty {
            Section(RegistrySurfaces.taskPageBlock(.references).label ?? "") {
              ForEach(rows) { row in
                TaskReferenceRowLabel(row: row)
                  .id(row.id)
                  .listRowBackground(row.id == highlightedID ? Theme.listSelectionFill : nil)
              }
            }
          }
        }
        .onChange(of: highlightedID) { _, id in
          guard let id else { return }
          a11yAnimate { proxy.scrollTo(id) }
        }
      }
      .navigationTitle(RegistryActions.title(.taskAddReference, .short))
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          DrawerCloseButton { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(RegistryTaskReferences.addConfirmTitle, action: submit)
            .disabled(trimmed.isEmpty)
        }
      }
    }
    .macSheetFrame(width: 420, height: 420)
    .onAppear {
      reload()
      fieldFocused = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in reload() }
  }

  private func submit() {
    guard !trimmed.isEmpty else { return }
    if add(trimmed) { dismiss() }
  }

  private func take(_ offer: TaskRefRows.Offer) {
    if add(offer.input) { reload() }
  }

  /// True when the reference is new.
  private func add(_ input: String) -> Bool {
    let result = TaskRefActions.add(input, to: taskID)
    message = TaskRefActions.message(for: result)
    switch result {
    case .added:
      return true
    case .existing(let ref):
      highlightedID = rows.first { $0.contains(ref) }?.id
      return false
    default:
      return false
    }
  }

  private func reload() {
    let context = LocalStore.shared.container.mainContext
    rows = LocalCache.taskRefRows(forTaskID: taskID, in: context)
    let task = LocalCache.task(id: taskID, in: context)
    offers = TaskRefRows.offers(title: task?.title ?? "", notes: task?.notes,
                                existing: rows.flatMap(\.refs))
  }
}
