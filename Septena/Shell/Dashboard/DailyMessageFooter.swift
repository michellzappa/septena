import SwiftUI

// The optional quote line pinned to the very bottom of the home dashboard.
// Off by default; renders nothing (zero layout cost) until enabled. The
// message is chosen deterministically per (day, time-of-day bucket) so it
// stays put if you glance twice and rotates as the day moves on. Tap it for
// another line now — a selection tick plus a soft blur-swap walks one step
// forward through the pool (so taps never repeat back-to-back).

struct DailyMessageFooter: View {
  @Environment(DayClock.self) private var clock
  @AppStorage(SettingsKey.dailyMessageEnabled) private var enabled = false
  @AppStorage(SettingsKey.dailyMessagePacks) private var packsRaw = "practice,stoic,zen"
  @AppStorage(SettingsKey.dailyMessageReadwiseEnabled) private var readwiseEnabled = true

  /// User + Readwise lines, refreshed on appear and whenever the store changes.
  @State private var stored: [DailyMessage] = []
  /// Manual taps past the deterministic (day, slot) anchor. Each tap walks one
  /// step further into the pool; reset implicitly as the day/slot anchor moves.
  @State private var bump = 0

  var body: some View {
    if enabled, let message = current {
      VStack(spacing: 4) {
        Text(message.text)
          .font(.callout)
          .italic()
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
        if !message.attribution.isEmpty {
          VStack(spacing: 1) {
            Text("— \(message.attributionLead)")
              .font(.caption)
              .foregroundStyle(.tertiary)
            if !message.attributionDetail.isEmpty {
              Text(message.attributionDetail)
                .font(.caption2)
                .italic()
                .foregroundStyle(.tertiary)
            }
          }
          .multilineTextAlignment(.center)
        }
      }
      .id(message.id)
      .transition(.blurReplace)
      .frame(maxWidth: .infinity)
      .padding(.horizontal)
      .padding(.top, Theme.sectionSpacing)
      .contentShape(Rectangle())
      .onTapGesture(perform: advance)
      .accessibilityAddTraits(.isButton)
      .accessibilityHint("Show another line")
      .onAppear(perform: reload)
      .onReceive(NotificationCenter.default.publisher(for: .septenaQuotesChanged)) { _ in
        reload()
      }
    }
  }

  private var current: DailyMessage? {
    let packs = Set(packsRaw.split(separator: ",").compactMap { QuotePack(rawValue: String($0)) })
    // Readwise highlights can be excluded from the rotation without disconnecting.
    let lines = readwiseEnabled ? stored : stored.filter { $0.source != "readwise" }
    let pool = DailyMessageSelector.pool(packs: packs, stored: lines)
    let slot = DayBucket.from(date: clock.now).order
    guard let base = DailyMessageSelector.index(count: pool.count, day: clock.today, slot: slot)
    else { return nil }
    return pool[(base + bump) % pool.count]
  }

  /// Walk to the next line, with a selection tick and a soft blur-swap.
  private func advance() {
    Haptics.pick()
    withAnimation(.smooth(duration: 0.35)) { bump += 1 }
  }

  private func reload() {
    stored = QuoteStore.shared.messages()
  }
}
