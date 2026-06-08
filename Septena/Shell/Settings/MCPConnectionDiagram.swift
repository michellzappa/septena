import SwiftUI

/// Educational diagram for the MCP "Connection & conventions" page. Explains
/// that everything lives in one private place (your iCloud) and an AI reaches
/// it one of two ways — the hosted gateway (Claude anywhere) or a local
/// connection on your Mac (Claude Code). Both reach the same data.
///
/// Drawn with plain stacks + a small connector `Shape` (not Canvas) so it stays
/// legible and accessible, and reads correctly on iPhone width inside a Form.
struct MCPConnectionDiagram: View {
  private let radius: CGFloat = 12

  var body: some View {
    VStack(spacing: 8) {
      // The data — one private place.
      node(icon: "icloud", title: "Your iCloud",
           subtitle: "A private database only you can read", emphasized: true)

      // Stem → MCP pill → branch into the two doors.
      Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1.5, height: 8)
      Text("MCP")
        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Capsule().fill(.secondary.opacity(0.12)))
      BranchConnector()
        .stroke(.secondary.opacity(0.4), style: .init(lineWidth: 1.5, lineJoin: .round))
        .frame(height: 18)

      // Two doors.
      HStack(alignment: .top, spacing: 10) {
        node(icon: "antenna.radiowaves.left.and.right", title: "Hosted gateway",
             subtitle: "mcp.septena.app · sign in", foot: "Claude, anywhere")
        node(icon: "desktopcomputer", title: "On your Mac",
             subtitle: "Local · private network", foot: "Claude Code")
      }

      Text("Either way, an AI reads and writes the same private data — and everything it touches is marked.")
        .font(.caption2).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 2)
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Everything you log lives in your private iCloud database. An AI connects one of two ways: "
      + "the hosted gateway at mcp.septena.app for Claude anywhere, or a local connection on your Mac "
      + "for Claude Code. Both reach the same private data, and everything an agent touches is marked.")
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

/// An inverted-Y: a center stem that splits to two legs at 25% / 75% width,
/// aligning over the two side-by-side door cards below it.
private struct BranchConnector: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    let leftX = rect.width * 0.25, rightX = rect.width * 0.75
    let topY = rect.minY, midY = rect.midY, botY = rect.maxY
    p.move(to: .init(x: rect.midX, y: topY)); p.addLine(to: .init(x: rect.midX, y: midY))
    p.move(to: .init(x: leftX, y: midY)); p.addLine(to: .init(x: rightX, y: midY))
    p.move(to: .init(x: leftX, y: midY)); p.addLine(to: .init(x: leftX, y: botY))
    p.move(to: .init(x: rightX, y: midY)); p.addLine(to: .init(x: rightX, y: botY))
    return p
  }
}
