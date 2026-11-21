import SwiftUI

/// Educational diagram for the MCP "Connection & conventions" page. Explains
/// that your data lives in one private place and an AI reaches it through the
/// cloud MCP connector.
///
/// Drawn with plain stacks (not Canvas) so it stays legible and accessible,
/// and reads correctly on iPhone width inside a Form.
struct MCPConnectionDiagram: View {
  private let radius: CGFloat = 12

  var body: some View {
    VStack(spacing: 8) {
      // The data — one private place.
      node(icon: "icloud", title: "Your iCloud",
           subtitle: "A private database only you can read", emphasized: true)

      // Stem → MCP pill → cloud connector.
      Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1.5, height: 8)
      Text("MCP")
        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Capsule().fill(.secondary.opacity(0.12)))
      Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1.5, height: 12)

      node(icon: "antenna.radiowaves.left.and.right", title: "Cloud connector",
           subtitle: "OAuth · revocable anytime", foot: "AI clients, anywhere")

      Text("An AI reads and writes your private data through the cloud connector — and everything it touches is marked.")
        .font(.caption2).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 2)
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Your data lives in a private database. AI clients connect through the cloud MCP connector "
      + "using OAuth, and everything an agent touches is marked.")
  }

  @ViewBuilder
  private func node(icon: String, title: String, subtitle: String,
                    foot: String? = nil, emphasized: Bool = false) -> some View {
    let tint: Color = emphasized ? .accentColor : .secondary
    VStack(spacing: 3) {
      Image(systemName: icon).font(.title3).foregroundStyle(tint)
      Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
      Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      if let foot {
        Text(foot).font(.caption2.weight(.medium)).foregroundStyle(tint)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10).padding(.horizontal, 8)
    .background(RoundedRectangle(cornerRadius: radius)
      .fill(emphasized ? Color.accentColor.opacity(0.10) : .secondary.opacity(0.10)))
    .overlay(RoundedRectangle(cornerRadius: radius)
      .strokeBorder(emphasized ? Color.accentColor.opacity(0.55) : .secondary.opacity(0.18), lineWidth: 1))
  }
}
