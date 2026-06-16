import SwiftUI

// The card used for both the top-level coach grid and a coach's "exercises"
// strip. Same anatomy as the old Discovery card — an accent-washed icon chip
// over a title — promoted out of DiscoveryShelf so the coach surfaces share
// one look. Below the title it shows EITHER section "area" pills with their
// entry counts over the coach window (coach cards) OR a plain subtitle (exercises).
//
// A plain view (NOT a button) so the caller wraps it in a NavigationLink
// (coach grid) or a Button (exercise) without nesting two tap targets.

/// One area the coach covers + how many entries landed there in the trailing
/// week. Built from `CoachContextBuilder.availability`.
struct CoachAreaPill: Identifiable {
  let id: String          // section key
  let label: String
  let systemImage: String
  let count: Int
  let accent: Color
}

struct CoachTile: View {
  let systemImage: String
  let title: String
  /// Shown when there are no area pills (exercises, or a coach with no data
  /// this week).
  var subtitle: String? = nil
  /// Area pills (coach cards). Rendered instead of the subtitle when present.
  var pills: [CoachAreaPill] = []
  let accent: Color
  /// Optional footer affordance ("Begin" on an exercise).
  var actionLabel: String? = nil

  /// Keep tiles compact / roughly even — overflow collapses to "+N".
  private let maxPills = 4

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: systemImage)
        .font(.title2.weight(.semibold))
        .foregroundStyle(accent)
        .frame(width: 38, height: 38)
        .background(accent.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      Text(title)
        .font(.headline)
        .foregroundStyle(.primary)

      if !pills.isEmpty {
        pillCloud
      } else if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .multilineTextAlignment(.leading)
      }

      Spacer(minLength: 0)

      if let actionLabel {
        Label(actionLabel, systemImage: "arrow.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(accent)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.secondaryGroupedBackground)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .strokeBorder(accent.opacity(0.28), lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
  }

  private var pillCloud: some View {
    let columns = [GridItem(.adaptive(minimum: 78), spacing: 6, alignment: .leading)]
    return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
      ForEach(pills.prefix(maxPills)) { pill($0) }
      if pills.count > maxPills {
        overflow(pills.count - maxPills)
      }
    }
  }

  private func pill(_ p: CoachAreaPill) -> some View {
    HStack(spacing: 4) {
      Image(systemName: p.systemImage).font(.caption2)
      Text(p.label).font(.caption2.weight(.medium)).lineLimit(1)
      Text("\(p.count)")
        .font(.caption2.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(p.accent.opacity(0.25), in: Capsule())
    }
    .padding(.horizontal, 7).padding(.vertical, 3)
    .foregroundStyle(p.accent)
    .background(p.accent.opacity(0.14), in: Capsule())
  }

  private func overflow(_ n: Int) -> some View {
    Text("+\(n)")
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 7).padding(.vertical, 3)
      .foregroundStyle(.secondary)
      .background(Color.secondary.opacity(0.14), in: Capsule())
  }
}
