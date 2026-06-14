import SwiftUI

// The triage band — the *unratified* layer that renders directly above the
// Today list (see docs/TRIAGE_BAND_SPEC.md). One surface, two planes: the
// inbox isn't a separate place, it's the "to sort" pile sitting on top of the
// day. Ratifying a row drops it across the divider into the Today list below,
// in view — so triage *is* planning. Collapsible, absent when empty, never
// blocks scrolling to the day.
//
// Two populations live here, both captured-but-not-committed:
//   • agent proposals (source == mcp, still glowing) — accept keeps their
//     proposed placement;
//   • loose human captures (no disposition) — accept defaults to Today.
// The membership predicate is `SeptenaTask.isInTriageBand`; the divider is
// ratification, not date.

/// The triage verb-set — the whole game (docs/TRIAGE_BAND_SPEC.md §4). Tapping
/// the primary chip applies one of these; the override menu offers the rest.
enum TriageDisposition: Equatable {
  case today          // → Today (pin)
  case tomorrow       // → scheduled +1 day
  case someday        // → Someday
  case drop           // → cancelled
  case acceptAgent    // ratify an agent proposal, keeping its placement
  case project(String)// → move to a project
}

struct TriageBandView: View {
  let tasks: [SeptenaTask]
  let accent: Color
  let projects: [Project]
  let areas: [Area]
  @Binding var collapsed: Bool
  /// Tap a row title → open the editor for full control (arbitrary scheduling,
  /// notes, etc.). The chip + menu cover the fast path; the editor is the override.
  let onOpen: (SeptenaTask) -> Void
  /// Apply a disposition to one row.
  let onDispose: (SeptenaTask, TriageDisposition) -> Void
  /// Accept every agent proposal in one gesture (the steady-state morning move).
  let onAcceptAll: () -> Void

  private var proposalCount: Int { tasks.filter { $0.source == TaskSource.mcp }.count }

  /// Soft cap so a fat band never becomes a wall above the day — show the first
  /// few, with a tap to reveal the rest in place (docs/TRIAGE_BAND_SPEC.md §11).
  private let cap = 5
  @State private var showAll = false
  private var visible: [SeptenaTask] { showAll ? tasks : Array(tasks.prefix(cap)) }

  var body: some View {
    DrawerSection(padding: .standard) {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        header
        if !collapsed {
          Divider().opacity(0.4)
          VStack(spacing: Theme.Spacing.sm) {
            ForEach(visible) { task in
              TriageRow(task: task, accent: accent, projects: projects, areas: areas,
                        onOpen: { onOpen(task) },
                        onDispose: { onDispose(task, $0) })
            }
            if tasks.count > visible.count {
              Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAll = true }
              } label: {
                Text("+\(tasks.count - visible.count) more")
                  .font(.caption.weight(.medium))
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.sm) {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: collapsed ? "chevron.right" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text("To sort")
            .font(.subheadline.weight(.semibold))
          Text("\(tasks.count)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(accent.opacity(0.16)))
            .foregroundStyle(accent)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Spacer(minLength: 0)

      // "Accept all" appears only when there are agent proposals to accept —
      // it ratifies those, keeping their placement, and leaves loose human
      // captures untouched (they carry no proposal).
      if proposalCount > 0 {
        Button(action: onAcceptAll) {
          Text(proposalCount == tasks.count ? "Accept all" : "Accept \(proposalCount)")
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
      }
    }
    .accessibilityElement(children: .contain)
  }
}

// MARK: - Row

private struct TriageRow: View {
  let task: SeptenaTask
  let accent: Color
  let projects: [Project]
  let areas: [Area]
  let onOpen: () -> Void
  let onDispose: (TriageDisposition) -> Void

  private var isAgent: Bool { task.source == TaskSource.mcp }
  private var hasPlacement: Bool {
    task.today || task.scheduled != nil || task.deadline != nil
      || task.project != nil || task.area != nil
  }
  /// An agent proposal that already carries a placement is ratified by simply
  /// acknowledging it (its fields decide where it lands). Everything else —
  /// loose captures, and placement-less agent rows — defaults to Today.
  private var primary: TriageDisposition { (isAgent && hasPlacement) ? .acceptAgent : .today }

  var body: some View {
    HStack(spacing: Theme.Spacing.sm) {
      if task.showsAgentCue() { AgentCueMarker(tint: accent) }

      Button(action: onOpen) {
        VStack(alignment: .leading, spacing: 1) {
          Text(task.title)
            .font(.body)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
          if let sub = subtitle {
            Text(sub).font(.caption).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Primary chip — one tap = accept.
      Button { onDispose(primary) } label: {
        Text("→ \(chipLabel)")
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .padding(.horizontal, 9).padding(.vertical, 4)
          .background(Capsule().fill(accent.opacity(0.16)))
          .foregroundStyle(accent)
      }
      .buttonStyle(.plain)

      // Override menu — the full verb-set for the rare "not that" case.
      Menu {
        Button { onDispose(.today) } label: { Label("Today", systemImage: "sun.max") }
        Button { onDispose(.tomorrow) } label: { Label("Tomorrow", systemImage: "sunrise") }
        if !projects.isEmpty {
          Menu {
            ForEach(projects) { p in
              Button(p.title) { onDispose(.project(p.id)) }
            }
          } label: { Label("Move to project", systemImage: "folder") }
        }
        Button { onDispose(.someday) } label: { Label("Someday", systemImage: "tray.and.arrow.down") }
        Divider()
        Button(role: .destructive) { onDispose(.drop) } label: { Label("Drop", systemImage: "trash") }
      } label: {
        Image(systemName: "ellipsis")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.vertical, 4).padding(.leading, 2)
          .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
    }
  }

  /// Secondary line — origin for agent rows, nothing for plain captures.
  private var subtitle: String? {
    guard isAgent else { return nil }
    return "From \(task.sourceClient ?? "Claude")"
  }

  /// What the primary chip promises. For an agent proposal we surface where its
  /// existing fields will land it; loose captures default to Today.
  private var chipLabel: String {
    guard case .acceptAgent = primary else { return "Today" }
    if task.today { return "Today" }
    if let s = task.scheduled {
      return s <= SeptenaDate.today ? "Today" : Self.shortDate(s)
    }
    if let d = task.deadline {
      return d <= SeptenaDate.today ? "Today" : "Due \(Self.shortDate(d))"
    }
    if let pid = task.project, let p = projects.first(where: { $0.id == pid }) { return p.title }
    if let aid = task.area, let a = areas.first(where: { $0.id == aid }) { return a.title }
    return "Accept"
  }

  private static func shortDate(_ ymd: String) -> String {
    guard let d = inFmt.date(from: ymd) else { return ymd }
    return outFmt.string(from: d)
  }
  private static let inFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX"); return f
  }()
  private static let outFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "MMM d"; return f
  }()
}
