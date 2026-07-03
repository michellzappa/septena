import SwiftUI

/// Septask's MCP Skills pane: the tasks brief only (the one skill this app's
/// data exposes), rendered in the full app's skill-page shape — summary,
/// tool list, conventions body, copy-to-clipboard. Septena's pane renders
/// every section via SectionRegistry; here the shared `TasksSkill` constant
/// is linked directly.
struct TasksSkillPane: View {
  @State private var copied = false
  private var skill: SectionSkill { TasksSkill.skill }

  var body: some View {
    Form {
      Section {
        Text(skill.summary)
      } footer: {
        Text(.init(SectionSkill.preamble))
      }

      Section("Tools") {
        ForEach(skill.tools, id: \.name) { tool in
          VStack(alignment: .leading, spacing: 2) {
            Text(tool.name).font(.callout.weight(.medium)).monospaced()
            Text(tool.blurb).font(.caption).foregroundStyle(.secondary)
            if let inputs = tool.inputs {
              Text(inputs).font(.caption2).foregroundStyle(.tertiary).monospaced()
            }
          }
          .padding(.vertical, 2)
        }
      }

      Section("Conventions") {
        Text(.init(skill.body))
          .font(.callout)
      }

      Section {
        Button {
          SkillCopy.copy(SectionSkill.preamble + "\n\n" + skill.body)
          withAnimation { copied = true }
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
          }
        } label: {
          Label(copied ? "Copied" : "Copy Skill", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
      } footer: {
        Text("Paste into a model's context to teach it the task tools without connecting MCP.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("MCP Skills")
  }
}
