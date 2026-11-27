import SwiftUI

/// The account's agents, as the server reports them (`GET /v1/access`,
/// `connections` + `agents`). One agent is one MCP connection: Claude, or
/// Claude Code on one machine. Devices (app installs) are a separate list in
/// Settings ▸ Account ▸ Devices. Settings reads the count for the AI & Agents
/// row; the Agents page reads the list.
@MainActor
@Observable
final class AgentRoster {
  static let shared = AgentRoster()

  /// nil until the first answer from the server.
  private(set) var access: BackendAccess?
  private(set) var loading = false
  private(set) var lastError: String?

  private init() {}

  var agents: [BackendAccess.Connection] { access?.connections ?? [] }

  /// "3 agents" for the Settings row; nil until the server answered.
  var statusLine: String? {
    guard let access else { return nil }
    return RegistryPrompts.agentsPhrase(count: access.agentCount)
  }

  func refresh() async {
    guard TaskSyncEngine.shared.signedIn else {
      access = nil
      lastError = nil
      return
    }
    loading = true
    defer { loading = false }
    do {
      access = try await TaskBackendClient.shared.access()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  func rename(_ agent: BackendAccess.Connection, to name: String) async {
    do {
      try await TaskBackendClient.shared.renameAgent(connectionID: agent.id, name: name)
    } catch {
      lastError = error.localizedDescription
    }
    await refresh()
  }

  /// Creates an agent key (#86). Returns the key to show once, or nil.
  func createKey(name: String) async -> String? {
    defer { Task { await refresh() } }
    do {
      let created = try await TaskBackendClient.shared.createAgentKey(name: name)
      lastError = nil
      return created.key
    } catch {
      lastError = error.localizedDescription
      return nil
    }
  }

  func disconnect(_ agent: BackendAccess.Connection) async {
    do {
      try await TaskBackendClient.shared.disconnect(connectionID: agent.id)
    } catch {
      lastError = error.localizedDescription
    }
    await refresh()
  }
}

/// Settings ▸ AI & Agents ▸ Agents (`registry/settings.json` page `agents`,
/// surface `access_agents`): a page on iPhone and iPad.
struct SeptaskAgentsPane: View {
  var body: some View {
    Form {
      SeptaskAgentsSections()
    }
    .formStyle(.grouped)
    .navigationTitle(RegistrySettings.pageById[RegistrySettings.PageID.agents]?.title ?? "")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

/// The agent list, with rename and disconnect, and New Agent Key for an
/// agent that cannot sign in (#86). The Mac AI & Agents tab shows
/// it inline; `SeptaskAgentsPane` wraps it as a page.
struct SeptaskAgentsSections: View {
  private var roster: AgentRoster { .shared }
  private static let section = RegistrySettings.section("agents", page: RegistrySettings.PageID.agents)
  private static let renamePrompt = RegistryPrompts.text[.renameAgent]
  private static let newKeyPrompt = RegistryPrompts.text[.newAgentKey]
  private static let keyCreatedPrompt = RegistryPrompts.fixed[.agentKeyCreated]

  @State private var renaming: BackendAccess.Connection?
  @State private var draftName = ""
  @State private var pendingDisconnect: BackendAccess.Connection?
  @State private var naming = false
  @State private var keyName = ""
  /// The new key, shown once.
  @State private var createdKey: String?
  /// The plan sheet, opened from the full-list line, with the moment it
  /// opened for.
  @State private var showingPlans = false
  @State private var plansMoment: String?

  var body: some View {
    Section {
      summaryRow
        .sheet(isPresented: $showingPlans) { SeptaskPlusSheet(upsellID: plansMoment) }
      ForEach(roster.agents) { agent in
        agentRow(agent)
      }
      agentsFullRow
      newKeyRow
      if let error = roster.lastError {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    } footer: {
      if let footer = Self.section?.footer { Text(footer) }
    }
  }

  /// Every agent slot of the plan is in use: one line that says so and
  /// what the next plan connects, with the plan sheet one tap away. Free
  /// opens on Plus, Plus and the trial on Pro (`upsells[].plan`). The server
  /// only logs past the limit today (#445); the line is the honest state.
  private var agentsFullMoment: RegistryPlanNote? {
    guard let access = roster.access, let limit = access.agents?.limit,
          access.agentCount >= limit, !PlanStatus.shared.isPro else { return nil }
    return RegistryPlans.upsell(PlanStatus.shared.isPlus ? "agents_full_plus" : "agents_full")
  }

  @ViewBuilder
  private var agentsFullRow: some View {
    if let moment = agentsFullMoment {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top, spacing: 12) {
          PlanMark(tier: moment.plan == "pro" ? .pro : .plus, size: 30)
          VStack(alignment: .leading, spacing: 2) {
            Text(moment.title).font(.body.weight(.semibold))
            Text(moment.detail).font(.subheadline).foregroundStyle(.secondary)
          }
          .fixedSize(horizontal: false, vertical: true)
        }
        Button(moment.plan == "pro" ? RegistryPlans.Paywall.seePro : RegistryPlans.Paywall.seePlus) {
          plansMoment = moment.id
          showingPlans = true
        }
      }
      .padding(.vertical, 2)
    }
  }

  /// The count row. It always exists, so the load, the rename alert and the
  /// disconnect dialog hang off it: a modifier on a `Section` with no rows
  /// never runs (the `Group` trap in AGENTS.md).
  private var summaryRow: some View {
    LabeledContent {
      if let access = roster.access {
        Text(RegistryPrompts.agentsPhrase(count: access.agentCount))
      } else if roster.loading {
        ProgressView().controlSize(.small)
      }
    } label: {
      Text(Self.section?.header ?? "")
    }
    .task(id: TaskSyncEngine.shared.signedIn) { await roster.refresh() }
    .alert(
      Self.renamePrompt?.title ?? "",
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
      presenting: renaming
    ) { agent in
      TextField(Self.renamePrompt?.placeholder ?? "", text: $draftName)
      Button(Self.renamePrompt?.confirmTitle ?? "") {
        let name = draftName
        renaming = nil
        Task { await roster.rename(agent, to: name) }
      }
      Button(RegistryPrompts.cancelTitle, role: .cancel) { renaming = nil }
    }
    .confirmationDialog(
      pendingDisconnect.map { RegistryPrompts.disconnectAgent(name: $0.displayName).title } ?? "",
      isPresented: Binding(get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } }),
      titleVisibility: .visible,
      presenting: pendingDisconnect
    ) { agent in
      let copy = RegistryPrompts.disconnectAgent(name: agent.displayName)
      Button(copy.confirmTitle ?? copy.title, role: .destructive) {
        pendingDisconnect = nil
        Task { await roster.disconnect(agent) }
      }
      Button(RegistryPrompts.cancelTitle, role: .cancel) {}
    } message: { agent in
      Text(RegistryPrompts.disconnectAgent(name: agent.displayName).message)
    }
  }

  /// New Agent Key: name it, then the key shows once with Copy Key.
  private var newKeyRow: some View {
    Button(Self.newKeyPrompt?.title ?? "") {
      keyName = ""
      naming = true
    }
    .alert(Self.newKeyPrompt?.title ?? "", isPresented: $naming) {
      TextField(Self.newKeyPrompt?.placeholder ?? "", text: $keyName)
      Button(Self.newKeyPrompt?.confirmTitle ?? "") {
        let name = keyName
        Task { createdKey = await roster.createKey(name: name) }
      }
      .disabled(keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button(RegistryPrompts.cancelTitle, role: .cancel) {}
    }
    .alert(
      Self.keyCreatedPrompt?.title ?? "",
      isPresented: Binding(get: { createdKey != nil }, set: { if !$0 { createdKey = nil } }),
      presenting: createdKey
    ) { key in
      Button(Self.keyCreatedPrompt?.confirmTitle ?? "") {
        SeptenaPasteboard.copy(key)
        createdKey = nil
      }
    } message: { key in
      Text("\(Self.keyCreatedPrompt?.message ?? "")\n\n\(key)")
    }
  }

  private func agentRow(_ agent: BackendAccess.Connection) -> some View {
    let disconnectTitle = RegistryPrompts.disconnectAgent(name: agent.displayName).confirmTitle ?? ""
    return LabeledContent {
      Button(disconnectTitle, role: .destructive) { pendingDisconnect = agent }
        .buttonStyle(.borderless)
    } label: {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(agent.displayName)
          Text(Self.detailLine(agent))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: RegistryIcons.sfSymbols["settings.agents"] ?? "person.2")
      }
    }
    .contextMenu {
      Button(Self.renamePrompt?.confirmTitle ?? "") { startRename(agent) }
      Button(disconnectTitle, role: .destructive) { pendingDisconnect = agent }
    }
    .swipeActions(edge: .trailing) {
      Button(disconnectTitle, role: .destructive) { pendingDisconnect = agent }
      Button(Self.renamePrompt?.confirmTitle ?? "") { startRename(agent) }
    }
  }

  private func startRename(_ agent: BackendAccess.Connection) {
    draftName = agent.displayName
    renaming = agent
  }

  /// "Claude Code · Last used 2 hours ago": the client's own name when the
  /// user renamed the agent, then when it was last used.
  private static func detailLine(_ agent: BackendAccess.Connection) -> String {
    let used = Date(timeIntervalSince1970: agent.lastUsed / 1000).formatted(.relative(presentation: .named))
    let usedLine = String(localized: "Last used \(used)")
    return agent.displayName == agent.clientName ? usedLine : "\(agent.clientName) · \(usedLine)"
  }
}
