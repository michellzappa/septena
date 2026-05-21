import SwiftUI

struct OfflineBanner: View {
  @Environment(SeptenaClient.self) private var client

  var body: some View {
    Group {
      if client.isOffline {
        HStack(spacing: 8) {
          Image(systemName: "wifi.slash")
          Text("Offline — showing cached data")
            .font(.septenaMetaStrong)
          Spacer(minLength: 8)
          Text("changes won't save")
            .font(.septenaMeta)
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(Theme.overdueRed)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .fill(Theme.overdueRed.opacity(0.15))
        )
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .a11yAnimation(.easeInOut(duration: 0.2), value: client.isOffline)
  }
}
