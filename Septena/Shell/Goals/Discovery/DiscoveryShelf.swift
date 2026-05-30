import SwiftUI

struct DiscoveryShelf: View {
  let onOpen: (AnyDiscoveryMiniApp) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Discover")
          .font(.headline)
        Text("Guided local-AI reflections that turn into real goals.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(DiscoveryRegistry.all) { app in
            DiscoveryCard(app: app) {
              onOpen(AnyDiscoveryMiniApp(descriptor: app))
            }
          }
        }
        .padding(.vertical, 2)
      }
    }
  }
}

private struct DiscoveryCard: View {
  let app: DiscoveryMiniAppDescriptor
  let onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
      VStack(alignment: .leading, spacing: 14) {
        Image(systemName: app.systemImage)
          .font(.title2.weight(.semibold))
          .foregroundStyle(app.accent)
          .frame(width: 38, height: 38)
          .background(app.accent.opacity(0.14))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        VStack(alignment: .leading, spacing: 5) {
          Text(app.title)
            .font(.headline)
            .foregroundStyle(.primary)
          Text(app.blurb)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }

        Spacer(minLength: 0)

        Label("Begin", systemImage: "arrow.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(app.accent)
      }
      .padding(16)
      .frame(width: 235, height: 180, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
          .fill(Theme.secondaryGroupedBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
          .strokeBorder(app.accent.opacity(0.28), lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}
