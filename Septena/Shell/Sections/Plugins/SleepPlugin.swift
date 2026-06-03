import SwiftUI
import SwiftData

// Sleep — HealthKit / Oura-mirrored sleep data. No Today timeline
// contribution (sleep ends in the morning, doesn't slot into a
// chronological log), no MCP brief yet. The destination view owns
// rendering. When the MCP gateway gains sleep tools, declare the
// brief here.

@MainActor
enum SleepPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["sleep"]!
  }

  static func destinationView() -> AnyView? { AnyView(SleepDestinationView()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "sleep",
      title: "Sleep",
      intro: "Mirrors bed time, wake time, duration, and stages from HealthKit and Oura. Septena reads; it never writes back.",
      bullets: [
        .init("Oura wins when connected", "Richer per-night detail. HealthKit fills in nights Oura missed.", icon: "moon.stars"),
        .init("Read-only", "Edit nights in Apple Health or the Oura app — Septena reflects whatever's there.", icon: "lock"),
      ],
      primaryActionLabel: "Open Sleep",
      complete: complete
    ))
  }

  // MARK: - Notifications

  /// Minutes before the learned bedtime to surface the wind-down nudge.
  private static let windDownLead = 30

  static var notificationDescriptors: [NotificationDescriptor] {
    // Exempt from quiet hours — it's *about* the 21:00–08:00 window, so it
    // must survive the filter that silences everything else at night.
    [NotificationDescriptor(id: "sleep.bedtime", sectionKey: "sleep",
                            title: "Bedtime wind-down",
                            priority: 1, quietHoursExempt: true)]
  }

  static func evaluateNotification(_ descriptorID: String,
                                   context: ModelContext,
                                   now: Date) -> NotificationPlan? {
    guard descriptorID == "sleep.bedtime" else { return nil }
    // Median of the last two weeks' Oura bedtimes (minutes since midnight).
    // Most bedtimes sit just before midnight, so a plain median is fine; a
    // sparse history (< 3 nights) yields no nudge rather than a guess.
    let bedtimes = OuraStore.shared.history(days: 14)
      .compactMap { NextScoring.parseHHMM($0.bedtime) }
    guard bedtimes.count >= 3, let usual = NextScoring.median(bedtimes) else { return nil }

    let fireMinute = usual - windDownLead
    let h = (usual / 60) % 24, m = usual % 60
    let bedLabel = String(format: "%02d:%02d", h, m)
    return NotificationPlan(descriptorID: descriptorID, title: "Sleep",
                            body: "Wind down — your usual bedtime is around \(bedLabel).",
                            threadID: "sleep", minuteOfDay: fireMinute)
  }
}
