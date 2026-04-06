import SwiftUI

// MARK: - Checkbox

struct ThingsCheckbox: View {
  let isDone: Bool
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      ZStack {
        Circle()
          .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
          .frame(width: 20, height: 20)
        if isDone {
          Circle()
            .fill(Theme.magicPlusBlue)
            .frame(width: 20, height: 20)
          Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
        }
      }
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Quick Find bar

struct QuickFindBar: View {
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13))
        .foregroundStyle(.tertiary)
      Text("Quick Find")
        .font(.system(size: 15))
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 36)
    .background(Theme.chipBackground)
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }
}

// MARK: - Sidebar row (smart lists)

struct SmartListRow: View {
  let icon: String
  let tint: Color
  let title: String
  var overdueBadge: Int? = nil
  var count: Int? = nil

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 22))
        .foregroundStyle(tint)
        .frame(width: 24, alignment: .center)
      Text(title)
        .font(.thingsSidebarRow)
        .foregroundStyle(.primary)
      Spacer()
      if let b = overdueBadge, b > 0 {
        Text("\(b)")
          .font(.thingsBadge)
          .foregroundStyle(.white)
          .frame(minWidth: 20, minHeight: 20)
          .padding(.horizontal, 6)
          .background(Theme.overdueRed)
          .clipShape(Capsule())
      }
      if let c = count, c > 0 {
        Text("\(c)")
          .font(.thingsMeta)
          .foregroundStyle(.secondary)
      }
    }
    .frame(height: Theme.sidebarRowHeight)
    .contentShape(Rectangle())
  }
}

// MARK: - Area row (with disclosure)

struct SidebarAreaRow: View {
  let name: String
  let isExpanded: Bool
  let onToggle: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "hexagon")
        .font(.system(size: 22, weight: .regular))
        .foregroundStyle(.secondary)
        .frame(width: 24, alignment: .center)
      Text(name)
        .font(.thingsSidebarRow)
        .foregroundStyle(.primary)
      Spacer()
      Button(action: onToggle) {
        Image(systemName: "chevron.down")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 0 : -90))
      }
      .buttonStyle(.plain)
    }
    .frame(height: Theme.sidebarRowHeight)
    .contentShape(Rectangle())
  }
}

// MARK: - Project row (nested under area)

struct SidebarProjectRow: View {
  let name: String
  var progress: Double = 0  // 0..1 — fraction of tasks completed

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        Circle()
          .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
          .frame(width: 16, height: 16)
        if progress > 0 {
          Circle()
            .trim(from: 0, to: progress)
            .stroke(Color.secondary, lineWidth: 8)
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(-90))
            .clipShape(Circle().inset(by: 1.5))
        }
      }
      .frame(width: 24, alignment: .center)
      Text(name)
        .font(.thingsSidebarRow)
        .foregroundStyle(.primary)
      Spacer()
    }
    .frame(height: Theme.sidebarRowHeight)
    .contentShape(Rectangle())
  }
}

// MARK: - Screen title

struct ScreenTitle: View {
  let icon: String
  let iconTint: Color
  let title: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 28))
        .foregroundStyle(iconTint)
      Text(title)
        .font(.thingsScreenTitle)
        .foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Theme.hPadding)
    .padding(.top, 8)
    .padding(.bottom, 16)
  }
}

// MARK: - Magic Plus floating button

struct MagicPlusButton: View {
  let action: () -> Void
  @State private var pressed = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 56, height: 56)
        .background(Theme.magicPlusBlue)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
    }
    .buttonStyle(.plain)
    .scaleEffect(pressed ? 0.9 : 1)
    .animation(.easeOut(duration: 0.15), value: pressed)
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in pressed = true }
        .onEnded { _ in pressed = false }
    )
  }
}

// MARK: - Things-styled task row

struct ThingsTaskRow: View {
  let task: EngageTask
  var onToggle: (() -> Void)? = nil
  var selecting: Bool = false
  var isSelected: Bool = false

  var body: some View {
    HStack(spacing: 12) {
      ThingsCheckbox(isDone: task.status == .completed) {
        onToggle?()
      }
      .allowsHitTesting(!selecting)
      .opacity(selecting ? 0.6 : 1)

      Text(task.title)
        .font(.thingsTaskTitle)
        .foregroundStyle(task.status == .completed ? .secondary : .primary)
        .strikethrough(task.status == .completed)
        .opacity(task.status == .completed ? 0.5 : 1)
        .lineLimit(2)

      Spacer(minLength: 8)

      if selecting {
        RadioCircle(isSelected: isSelected)
      } else {
        trailingMeta
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, 12)
    .frame(minHeight: Theme.rowHeight)
    .contentShape(Rectangle())
    .background(isSelected ? Theme.rowSelected : Color.clear)
  }

  @ViewBuilder
  private var trailingMeta: some View {
    HStack(spacing: 6) {
      if task.repeatRule != nil {
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      if let deadline = task.deadline {
        deadlineLabel(for: deadline)
      }
    }
  }

  @ViewBuilder
  private func deadlineLabel(for date: Date) -> some View {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let target = cal.startOfDay(for: date)
    let days = cal.dateComponents([.day], from: today, to: target).day ?? 0

    HStack(spacing: 3) {
      Image(systemName: "flag.fill")
        .font(.system(size: 11))
      Text(dueText(days: days))
        .font(.thingsMeta)
    }
    .foregroundStyle(days == 0 ? Theme.overdueRed : .secondary)
  }

  private func dueText(days: Int) -> String {
    if days < 0 { return "\(-days)d over" }
    if days == 0 { return "today" }
    if days == 1 { return "1d left" }
    return "\(days)d left"
  }
}

// MARK: - Section header (inside lists)

struct ListSectionHeader: View {
  let icon: String
  let iconTint: Color
  let title: String
  var onTap: (() -> Void)? = nil

  var body: some View {
    Button(action: { onTap?() }) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .font(.system(size: 18))
          .foregroundStyle(iconTint)
        Text(title)
          .font(.thingsSectionHeader)
          .foregroundStyle(.primary)
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.top, Theme.sectionSpacing)
      .padding(.bottom, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(onTap == nil)
  }
}

// MARK: - Inline new task row

struct InlineNewTaskRow: View {
  @Binding var title: String
  @Binding var notes: String
  var defaultWhen: String = "Today"
  var defaultWhenIcon: String = "star.fill"
  var defaultWhenTint: Color = Theme.todayYellow
  var onCommit: () -> Void
  var onCancel: () -> Void
  @FocusState private var focused: Field?

  enum Field { case title, notes }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        ZStack {
          Circle()
            .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
            .frame(width: 20, height: 20)
        }
        .padding(.top, 2)

        VStack(alignment: .leading, spacing: 6) {
          TextField("New To-Do", text: $title)
            .font(.thingsTaskTitle)
            .focused($focused, equals: .title)
            .submitLabel(.next)
            .onSubmit {
              if title.trimmingCharacters(in: .whitespaces).isEmpty {
                onCancel()
              } else {
                onCommit()
              }
            }
          TextField("Notes", text: $notes, axis: .vertical)
            .font(.thingsMeta)
            .foregroundStyle(.secondary)
            .focused($focused, equals: .notes)
            .lineLimit(1...4)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.vertical, 14)

      HStack(spacing: 20) {
        HStack(spacing: 6) {
          Image(systemName: defaultWhenIcon)
            .font(.system(size: 14))
            .foregroundStyle(defaultWhenTint)
          Text(defaultWhen)
            .font(.thingsTaskTitle)
            .foregroundStyle(.primary)
        }
        Spacer()
        Image(systemName: "tag")
          .font(.system(size: 16))
          .foregroundStyle(.secondary)
        Image(systemName: "list.bullet")
          .font(.system(size: 16))
          .foregroundStyle(.secondary)
        Image(systemName: "flag")
          .font(.system(size: 16))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.bottom, 14)
    }
    .background(Color(.systemBackground))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Theme.divider, lineWidth: 0.5)
    )
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
    .onAppear { focused = .title }
  }
}

// MARK: - Inline edit task row (existing task)

struct InlineEditTaskRow: View {
  @EnvironmentObject var client: AtaskClient
  let task: EngageTask
  @Binding var title: String
  @Binding var notes: String
  let isDone: Bool
  var onToggleDone: () -> Void
  var onCommit: () -> Void
  var onCancel: () -> Void
  var onSchedule: (() -> Void)? = nil
  var onDeadline: (() -> Void)? = nil
  var onAccept: (() -> Void)? = nil
  var onDismiss: (() -> Void)? = nil
  var onReload: (() -> Void)? = nil
  @FocusState private var focused: Field?
  @State private var showAgentSheet = false
  @State private var showCommentsSheet = false
  @State private var commentCount: Int = 0

  enum Field { case title, notes }

  private var hasAgentNote: Bool { false }  // agentNote not yet in upstream

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
        Button(action: onToggleDone) {
          ZStack {
            Circle()
              .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
              .frame(width: 20, height: 20)
            if isDone {
              Circle().fill(Theme.magicPlusBlue).frame(width: 20, height: 20)
              Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
            }
          }
        }
        .buttonStyle(.plain)
        .padding(.top, 2)

        VStack(alignment: .leading, spacing: 6) {
          TextField("Title", text: $title)
            .font(.thingsTaskTitle)
            .focused($focused, equals: .title)
            .submitLabel(.next)
            .onSubmit { focused = .notes }
          TextField("Notes", text: $notes, axis: .vertical)
            .font(.thingsMeta)
            .foregroundStyle(.secondary)
            .focused($focused, equals: .notes)
            .lineLimit(1...6)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.vertical, 14)

      HStack(spacing: 20) {
        Spacer()
        Button(action: { onSchedule?() }) {
          Image(systemName: "calendar")
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        Button(action: { onDeadline?() }) {
          Image(systemName: "flag")
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        Button(action: { showAgentSheet = true }) {
          Image(systemName: "brain")
            .font(.system(size: 16))
            .foregroundStyle(hasAgentNote ? Color.blue : Color.secondary)
        }
        .buttonStyle(.plain)
        Button(action: { showCommentsSheet = true }) {
          ZStack(alignment: .topTrailing) {
            Image(systemName: "bubble.left")
              .font(.system(size: 16))
              .foregroundStyle(.secondary)
            if commentCount > 0 {
              Text("\(commentCount)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.blue, in: Capsule())
                .offset(x: 8, y: -6)
            }
          }
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.bottom, 14)
    }
    .background(Color(.systemBackground))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Theme.divider, lineWidth: 0.5)
    )
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
    .onAppear {
      focused = .title
      Task { await loadCommentCount() }
    }
    .sheet(isPresented: $showAgentSheet, onDismiss: { onReload?() }) {
      AgentSheet(task: task)
        .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showCommentsSheet, onDismiss: {
      Task { await loadCommentCount() }
    }) {
      CommentsSheet(taskId: task.id, canResolve: true)
        .presentationDetents([.medium, .large])
    }
  }

  private func loadCommentCount() async {
    commentCount = (try? await client.taskComments(taskId: task.id).count) ?? 0
  }

  @ViewBuilder
  private var reviewBanner: some View { EmptyView() } // review not yet in upstream atask

// MARK: - Agent sheet (assign + thinking)

struct AgentSheet: View {
  let task: EngageTask
  @EnvironmentObject var client: AtaskClient
  @Environment(\.dismiss) private var dismiss
  @State private var agents: [Agent] = []
  @State private var assigning = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      List {
        SwiftUI.Section("Assigned to") {
          HStack(spacing: 10) {
            Image(systemName: currentIsAgent ? "cpu" : "person.fill")
              .foregroundStyle(currentIsAgent ? .purple : .blue)
            Text(currentOwnerLabel).font(.callout)
            Spacer()
          }
        }

        // agentNote / confidence / agentContext not yet available in upstream atask

        SwiftUI.Section("Reassign to") {
          ForEach(agents) { agent in
            Button { assign(to: agent) } label: {
              HStack(spacing: 10) {
                Image(systemName: agent.type == .ai ? "cpu" : "person.fill")
                  .foregroundStyle(agent.type == .ai ? .purple : .blue)
                VStack(alignment: .leading, spacing: 2) {
                  Text(agent.name).foregroundStyle(.primary)
                  Text(agent.email).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if false {
                  Image(systemName: "checkmark").foregroundStyle(.blue)
                }
              }
            }
            .disabled(assigning || false)
          }
          if agents.isEmpty {
            Text("No agents available").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Agent")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task { await loadAgents() }
      .alert("Error", isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )) {
        Button("OK", role: .cancel) { errorMessage = nil }
      } message: { Text(errorMessage ?? "") }
    }
  }

  private var currentIsAgent: Bool {
    false
  }

  private var currentOwnerLabel: String {
    "—"
  }

  private func loadAgents() async {
    agents = (try? await client.agentsList()) ?? []
  }

  private func assign(to agent: Agent) {
    assigning = true
    Task {
      do {
        try await client.taskAssign(id: task.id, owner: agent.id, agentAcknowledged: false, actor: "human")
        assigning = false
        dismiss()
      } catch {
        assigning = false
        errorMessage = "Assign failed: \(error.localizedDescription)"
      }
    }
  }

  // confidence not yet available in upstream
  private var confidenceColor: Color { .clear }
  private var confidenceLabel: String { "" }
}

// MARK: - Comments sheet

struct CommentsSheet: View {
  let taskId: String
  let canResolve: Bool
  @EnvironmentObject var client: AtaskClient
  @Environment(\.dismiss) private var dismiss
  @State private var comments: [Comment] = []
  @State private var newComment = ""

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if comments.isEmpty {
              Text("No comments yet")
                .font(.thingsMeta).foregroundStyle(.secondary)
                .padding()
            }
            ForEach(comments) { comment in
              CommentRow(comment: comment, canResolve: canResolve) { resolved in
                Task {
                  try? await client.resolveComment(id: comment.id, resolved: resolved)
                  await load()
                }
              }
              Divider().padding(.leading, 16)
            }
          }
        }
        Divider()
        HStack {
          TextField("Add a comment…", text: $newComment, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...3)
          Button("Send") { send() }
            .disabled(newComment.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
      }
      .navigationTitle("Comments")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
      .task { await load() }
    }
  }

  private func load() async {
    comments = (try? await client.taskComments(taskId: taskId)) ?? []
  }

  private func send() {
    let body = newComment.trimmingCharacters(in: .whitespaces)
    guard !body.isEmpty else { return }
    newComment = ""
    Task {
      try? await client.taskAddComment(taskId: taskId, actor: "human", body: body)
      await load()
    }
  }
}

struct CommentRow: View {
  let comment: Comment
  let canResolve: Bool
  let onResolve: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: comment.actorId == "human" ? "person.fill" : "brain")
          .font(.caption)
          .foregroundStyle(comment.actorId == "human" ? Color.secondary : Color.blue)
        Text(comment.actorId == "human" ? "You" : comment.actorId)
          .font(.caption).fontWeight(.medium)
        Spacer()
        if comment.resolved {
          Image(systemName: "checkmark.circle.fill")
            .font(.caption2).foregroundStyle(.green)
        }
      }
      Text(comment.body)
        .font(.body)
        .strikethrough(comment.resolved)
        .opacity(comment.resolved ? 0.5 : 1.0)
      if canResolve {
        Button(comment.resolved ? "Unresolve" : "Resolve") {
          onResolve(!comment.resolved)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .opacity(comment.resolved ? 0.7 : 1.0)
  }
}

// MARK: - Radio selection circle

struct RadioCircle: View {
  let isSelected: Bool
  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
        .frame(width: 22, height: 22)
      if isSelected {
        Circle().fill(Theme.magicPlusBlue).frame(width: 22, height: 22)
        Circle().fill(Color.white).frame(width: 8, height: 8)
      }
    }
  }
}

// MARK: - Multi-select bottom bar

struct MultiSelectBar: View {
  let count: Int
  let onWhen: () -> Void
  let onMove: () -> Void
  let onDelete: () -> Void
  let onMore: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      barItem(icon: "calendar", label: "When", action: onWhen)
      barItem(icon: "arrow.right", label: "Move", action: onMove)
      barItem(icon: "trash", label: "Delete", action: onDelete, destructive: true)
      barItem(icon: "ellipsis", label: nil, action: onMore)
    }
    .padding(.horizontal, 8)
    .frame(height: 56)
    .background(
      Capsule().fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.95))
    )
    .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)
    .opacity(count > 0 ? 1 : 0.5)
    .allowsHitTesting(count > 0)
  }

  private func barItem(icon: String, label: String?, action: @escaping () -> Void, destructive: Bool = false) -> some View {
    Button(action: action) {
      VStack(spacing: 2) {
        Image(systemName: icon).font(.system(size: 16, weight: .regular))
        if let label { Text(label).font(.system(size: 11)) }
      }
      .foregroundStyle(destructive ? Color(red: 1, green: 0.42, blue: 0.38) : .white)
      .frame(minWidth: 64, maxWidth: .infinity)
      .padding(.vertical, 6)
    }
    .buttonStyle(.plain)
  }
}

// swipeLeftToSelect removed — functionality replaced inline



// MARK: - When picker sheet (schedule)

struct WhenPickerSheet: View {
  let onPick: (Date?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var customDate = Date()
  @State private var showingCustom = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if showingCustom {
          DatePicker("Due date", selection: $customDate, displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .padding(.horizontal, Theme.hPadding)
          Spacer()
          Button {
            onPick(Calendar.current.startOfDay(for: customDate))
            dismiss()
          } label: {
            Text("Set Date")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(Theme.magicPlusBlue)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)
          .padding(.horizontal, Theme.hPadding)
          .padding(.bottom, 20)
        } else {
          option(icon: "star.fill", tint: Theme.todayYellow, title: "Today") {
            onPick(Calendar.current.startOfDay(for: Date())); dismiss()
          }
          Hairline()
          option(icon: "moon.stars.fill", tint: Theme.todayYellow, title: "This Evening") {
            onPick(Calendar.current.startOfDay(for: Date())); dismiss()
          }
          Hairline()
          option(icon: "sunrise.fill", tint: Theme.upcomingRed, title: "Tomorrow") {
            let d = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
            onPick(d); dismiss()
          }
          Hairline()
          option(icon: "calendar", tint: Theme.upcomingRed, title: "Custom…") {
            showingCustom = true
          }
          Hairline()
          option(icon: "archivebox.fill", tint: Theme.somedayTan, title: "Someday") {
            onPick(nil); dismiss()
          }
          Hairline()
          option(icon: "xmark.circle", tint: .secondary, title: "Clear Date") {
            onPick(nil); dismiss()
          }
          Spacer()
        }
      }
      .navigationTitle("When")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  @ViewBuilder
  private func option(icon: String, tint: Color, title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: icon)
          .font(.system(size: 18))
          .foregroundStyle(tint)
          .frame(width: 24)
        Text(title)
          .font(.thingsSidebarRow)
          .foregroundStyle(.primary)
        Spacer()
      }
      .padding(.horizontal, Theme.hPadding)
      .frame(height: Theme.sidebarRowHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Move picker sheet

struct MovePickerSheet: View {
  let areas: [Area]
  let projects: [Project]
  let onPick: (_ areaId: String?, _ projectId: String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          optionRow(icon: "tray.fill", tint: Theme.inboxBlue, title: "Inbox (no area/project)") {
            onPick(nil, nil); dismiss()
          }
          Hairline()

          if !filteredTopProjects.isEmpty {
            sectionHeader("Projects")
            ForEach(filteredTopProjects) { p in
              optionRow(icon: "circle", tint: .secondary, title: p.title) {
                onPick(nil, p.id); dismiss()
              }
              Hairline()
            }
          }

          ForEach(filteredAreas) { area in
            sectionHeader(String(area.title.uppercased()))
            optionRow(icon: "square.stack.3d.up.fill", tint: .orange, title: "(area only)") {
              onPick(area.id, nil); dismiss()
            }
            Hairline()
            ForEach(projectsIn(area.id)) { p in
              optionRow(icon: "circle", tint: .secondary, title: p.title, indent: true) {
                onPick(area.id, p.id); dismiss()
              }
              Hairline()
            }
          }
        }
      }
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
      .navigationTitle("Move To")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private var filteredAreas: [Area] {
    let q = query.lowercased()
    return areas.sorted { $0.index < $1.index }.filter {
      q.isEmpty || $0.title.lowercased().contains(q) || projectsIn($0.id).contains(where: { $0.title.lowercased().contains(q) })
    }
  }

  private var filteredTopProjects: [Project] {
    let q = query.lowercased()
    return projects
      .filter { $0.areaId == nil && $0.status == .pending }
      .filter { q.isEmpty || $0.title.lowercased().contains(q) }
      .sorted { $0.index < $1.index }
  }

  private func projectsIn(_ areaId: String) -> [Project] {
    let q = query.lowercased()
    return projects
      .filter { $0.areaId == areaId && $0.status == .pending }
      .filter { q.isEmpty || $0.title.lowercased().contains(q) }
      .sorted { $0.index < $1.index }
  }

  @ViewBuilder
  private func sectionHeader(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12, weight: .bold))
      .tracking(0.8)
      .foregroundStyle(.secondary)
      .padding(.horizontal, Theme.hPadding)
      .padding(.top, 16)
      .padding(.bottom, 6)
  }

  @ViewBuilder
  private func optionRow(icon: String, tint: Color, title: String, indent: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: icon)
          .font(.system(size: 16))
          .foregroundStyle(tint)
          .frame(width: 24)
        Text(title)
          .font(.thingsSidebarRow)
          .foregroundStyle(.primary)
        Spacer()
      }
      .padding(.leading, indent ? Theme.hPadding + 20 : Theme.hPadding)
      .padding(.trailing, Theme.hPadding)
      .frame(height: Theme.rowHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Hairline divider

struct Hairline: View {
  var leadingInset: CGFloat = Theme.hPadding
  var body: some View {
    Rectangle()
      .fill(Theme.divider)
      .frame(height: 0.5)
      .padding(.leading, leadingInset)
  }
}
