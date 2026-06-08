import SwiftUI

// The card used for both the top-level coach grid and a coach's "exercises"
// strip. Same anatomy as the old Discovery card — an accent-washed icon chip
// over a title + subtitle — promoted out of DiscoveryShelf so the coach
// surfaces share one look. Fills its grid column; height grows with content.
//
// A plain view (NOT a button) so the caller can wrap it in either a
// `NavigationLink` (coach grid) or a `Button` (exercise) without nesting two
// tap targets — nesting one inside the other swallows the tap.

struct CoachTile: View {
  let systemImage: String
  let title: String
  let subtitle: String
  let accent: Color
  /// Optional footer affordance ("Begin" on an exercise; omitted on a coach
  /// tile, which navigates as a whole).
  var actionLabel: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Image(systemName: systemImage)
        .font(.title2.weight(.semibold))
        .foregroundStyle(accent)
        .frame(width: 38, height: 38)
        .background(accent.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)
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
}
