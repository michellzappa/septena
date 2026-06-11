import SwiftUI

/// Compact stand-in shown where an AI-only surface (Discovery shelf, Coach
/// exercises) would otherwise vanish without explanation. States the reason
/// from `OnDeviceAI` and points at Settings ▸ AI, where the status row lives.
struct AppleIntelligenceUnavailableCard: View {
  private var detail: String {
    OnDeviceAI.unavailableReason ?? "On-device intelligence is unavailable right now."
  }

  private var hint: String? {
    switch OnDeviceAI.status {
    case .notEnabled, .modelNotReady, .unknown:
      return "Details in Settings ▸ AI."
    case .deviceNotEligible, .available:
      return nil
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "apple.intelligence")
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 3) {
        Text("Needs Apple Intelligence")
          .font(.subheadline.weight(.semibold))
        Text(hint.map { "\(detail) \($0)" } ?? detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.secondaryGroupedBackground)
    )
  }
}
