import SwiftUI

// Standard row layout for the Add Info palette. Leading tinted glyph, two-
// line label, optional trailing accessory (chevron for navigation, check
// for toggleable items, custom badge text).

enum AddInfoRowAccessory {
  case none
  case chevron
  case check(Bool)
  case badge(String)
}

struct AddInfoRow: View {
  let title: String
  var subtitle: String? = nil
  var systemImage: String? = nil
  /// Leading number pill (e.g. a Bristol type). Takes the leading slot in
  /// place of `systemImage` — a tinted capsule that reads as the option's
  /// identifier, not decoration.
  var leadingNumber: Int? = nil
  var tint: Color = .secondary
  var accessory: AddInfoRowAccessory = .none

  var body: some View {
    HStack(spacing: 12) {
      if let leadingNumber {
        Text("\(leadingNumber)")
          .font(.callout.weight(.semibold).monospacedDigit())
          .foregroundStyle(tint)
          .padding(.horizontal, 9)
          .padding(.vertical, 3)
          .background(tint.opacity(0.15), in: Capsule())
          .accessibilityLabel("Number \(leadingNumber)")
      } else if let systemImage {
        Image(systemName: systemImage)
          .font(.body.weight(.medium))
          .foregroundStyle(tint)
          .a11yScaledFrame(24)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.body)
          .foregroundStyle(Theme.inkPrimary)
          .lineLimit(1)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      switch accessory {
      case .none:
        EmptyView()
      case .chevron:
        Image(systemName: "chevron.right")
          .font(.footnote)
          .foregroundStyle(.tertiary)
      case .check(let on):
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(on ? tint : .secondary)
      case .badge(let text):
        Text(text)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
  }
}
