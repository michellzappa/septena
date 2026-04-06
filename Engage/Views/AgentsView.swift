import SwiftUI

// Agents list + per-agent detail. Not a Things feature — custom for Engage.

struct AgentsView: View {
  @EnvironmentObject var client: AtaskClient
  @EnvironmentObject var nav: NavigationState

  @State private var agents: [Agent] = []
  @State private var tasks: [EngageTask] = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ScreenTitle(icon: "person.2.fill", iconTint: .purple, title: "Agents")

        if agents.isEmpty {
          Text("No agents")
            .font(.thingsMeta)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 40)
        }

        ForEach(agents) { agent in
          Button { nav.selectedTab = .inbox } label: {
            HStack(spacing: 12) {
              ZStack {
                Circle()
                  .fill(agent.type == .ai ? Color.purple.opacity(0.2) : Color.blue.opacity(0.2))
                  .frame(width: 32, height: 32)
                Image(systemName: agent.type == .ai ? "cpu" : "person.fill")
                  .font(.system(size: 14, weight: .semibold))
                  .foregroundStyle(agent.type == .ai ? .purple : .blue)
              }
              VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                  .font(.thingsTaskTitle)
                  .foregroundStyle(.primary)
                Text(agent.email)
                  .font(.thingsMeta)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              let count = taskCount(for: agent.id)
              if count > 0 {
                Text("\(count)")
                  .font(.thingsMeta)
                  .foregroundStyle(.secondary)
              }
              Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.vertical, 12)
            .frame(minHeight: Theme.rowHeight)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          Hairline()
        }

        Spacer(minLength: 120)
      }
    }
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
  }

  private func taskCount(for agentId: String) -> Int {
    tasks.filter { $0.status == .open && $0.owner == agentId }.count
  }

  private func load() async {
    async let a = try? await client.agentsList()
    async let t = try? await client.tasksList()
    agents = (await a) ?? []
    tasks = (await t) ?? []
  }
}

// MARK: - Agent detail

struct AgentDetailView: View {
  let agent: Agent
  @EnvironmentObject var client: AtaskClient
  @State private var tasks: [EngageTask] = []
  @State private var memory: [AgentMemoryEntry] = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 12) {
          ZStack {
            Circle()
              .fill(agent.type == .ai ? Color.purple.opacity(0.2) : Color.blue.opacity(0.2))
              .frame(width: 44, height: 44)
            Image(systemName: agent.type == .ai ? "cpu" : "person.fill")
              .font(.system(size: 20, weight: .semibold))
              .foregroundStyle(agent.type == .ai ? .purple : .blue)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text(agent.name).font(.thingsScreenTitle)
            Text(agent.email).font(.thingsMeta).foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 8)
        .padding(.bottom, 20)

        sectionLabel("Open tasks (\(openTasks.count))")
        if openTasks.isEmpty {
          Text("None")
            .font(.thingsMeta)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.hPadding)
            .padding(.bottom, 16)
        } else {
          ForEach(openTasks) { task in
            ThingsTaskRow(task: task)
            Hairline()
          }
        }

        if !memory.isEmpty {
          sectionLabel("Memory (\(memory.count))")
          ForEach(memory) { entry in
            VStack(alignment: .leading, spacing: 4) {
              Text(entry.content)
                .font(.thingsMeta)
                .foregroundStyle(.primary)
                .lineLimit(3)
              if entry.pinned {
                Text("pinned")
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundStyle(.orange)
              }
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.vertical, 10)
            Hairline()
          }
        }

        Spacer(minLength: 120)
      }
    }
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
  }

  @ViewBuilder
  private func sectionLabel(_ text: String) -> some View {
    Text(text)
      .font(.thingsSectionHeader)
      .foregroundStyle(.secondary)
      .padding(.horizontal, Theme.hPadding)
      .padding(.top, 8)
      .padding(.bottom, 8)
  }

  private var openTasks: [EngageTask] {
    tasks.filter { $0.status == .open && $0.owner == agent.id }
  }

  private func load() async {
    async let t = try? await client.tasksList()
    async let m = try? await client.agentMemory(agentId: agent.id)
    tasks = (await t) ?? []
    memory = (await m) ?? []
  }
}
