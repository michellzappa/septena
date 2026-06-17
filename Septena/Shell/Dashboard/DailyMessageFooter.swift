import SwiftUI

// The optional quote line pinned to the very bottom of the home dashboard.
// Off by default; renders nothing (zero layout cost) until enabled. The
// message is chosen deterministically per (day, time-of-day bucket) so it
// stays put if you glance twice and rotates as the day moves on.

struct DailyMessageFooter: View {
  @Environment(DayClock.self) private var clock
  @AppStorage(SettingsKey.dailyMessageEnabled) private var enabled = false
  @AppStorage(SettingsKey.dailyMessagePacks) private var packsRaw = "practice,stoic,zen"

  /// User + Readwise lines, refreshed on appear and whenever the store changes.
  @State private var stored: [DailyMessage] = []

  var body: some View {
    if enabled, let message = current {
      VStack(spacing: 4) {
        Text(message.text)
          .font(.callout)
          .italic()
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
        if !message.attribution.isEmpty {
          Text("— \(message.attribution)")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal)
      .padding(.top, Theme.sectionSpacing)
      .onAppear(perform: reload)
      .onReceive(NotificationCenter.default.publisher(for: .septenaQuotesChanged)) { _ in
        reload()
      }
    }
  }

  private var current: DailyMessage? {
    let packs = Set(packsRaw.split(separator: ",").compactMap { QuotePack(rawValue: String($0)) })
    let pool = DailyMessageSelector.pool(packs: packs, stored: stored)
    let slot = DayBucket.from(date: clock.now).order
    return DailyMessageSelector.pick(from: pool, day: clock.today, slot: slot)
  }

  private func reload() {
    stored = QuoteStore.shared.messages()
  }
}
