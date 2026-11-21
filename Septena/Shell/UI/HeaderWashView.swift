import SwiftUI

/// Procedural Header Wash backdrop for SwiftUI task lists (iOS, iPadOS, and
/// classic macOS window). See ADR 0019 and `docs/CUSTOMIZATION_SPEC.md`.
///
/// Renders purely via `HeaderWashEngine` in CoreGraphics, anchored to the top
/// edge (`ignoresSafeArea(edges: .top)`) so geometry bleeds cleanly behind the
/// iOS status bar / Dynamic Island and fades to transparent over `fadeHeight`.
/// Smart lists derive their daily seed automatically from `dayClock.today`
/// (`YYYY-MM-DD`); projects can optionally pass `projectID`.
struct HeaderWashView: View {
  var projectID: String? = nil
  var fadeHeight: CGFloat = 380

  private let appearance = AppearancePreferences.shared
  @Environment(DayClock.self) private var dayClock
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.scenePhase) private var scenePhase

  /// Continuous animation phase tracking: when `shouldAnimate` toggles on, phase
  /// advances smoothly from `accumulatedPhase` (0 on first enable) with zero
  /// discontinuity, and freezes cleanly in place when paused or toggled off.
  /// Calendar day / seed NEVER reads `Date()` — it comes from `dayClock.today`.
  @State private var accumulatedPhase: Double = 0
  @State private var runStartDate: Date? = nil
  @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

  private var shouldAnimate: Bool {
    appearance.isSlowDrift
      && !reduceMotion
      && !lowPowerMode
      && scenePhase == .active
  }

  private func phase(at date: Date) -> Double {
    guard shouldAnimate, let start = runStartDate else {
      return accumulatedPhase
    }
    return accumulatedPhase + max(0, date.timeIntervalSince(start))
  }

  var body: some View {
    if appearance.hasActiveTexture {
      TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !shouldAnimate)) { timeline in
        let currentPhase = phase(at: timeline.date)
        let isDark = colorScheme == .dark
        let params = HeaderWashParams(
          style: appearance.canvasTexture,
          isDark: isDark,
          accent: appearance.accentRGB(isDark: isDark),
          intensity: appearance.textureIntensity,
          seed: AppearancePreferences.resolvedSeed(dayISO: dayClock.today, projectID: projectID),
          phase: currentPhase,
          fadeHeight: fadeHeight,
          mini: false,
          increaseContrast: contrast == .increased
        )
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
          context.withCGContext { cg in
            HeaderWashEngine.draw(in: cg, size: size, params: params)
          }
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: fadeHeight + 24)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .onAppear {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if shouldAnimate && runStartDate == nil {
          runStartDate = Date()
        }
      }
      .onChange(of: shouldAnimate) { _, active in
        if active {
          runStartDate = Date()
        } else if let start = runStartDate {
          accumulatedPhase += max(0, Date().timeIntervalSince(start))
          runStartDate = nil
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
      }
    }
  }
}

/// Compact static procedural texture preview rendered by the exact same
/// `HeaderWashEngine` used on live task lists (`mini: true`).
struct HeaderWashPreviewCanvas: View {
  let style: HeaderTextureStyle
  let isDark: Bool
  let accent: RGBTriple
  let intensity: Int
  let seed: UInt32

  var body: some View {
    if style == .none {
      Color.clear
    } else {
      Canvas(opaque: false, rendersAsynchronously: false) { context, size in
        let params = HeaderWashParams(
          style: style,
          isDark: isDark,
          accent: accent,
          intensity: max(55, intensity),
          seed: seed,
          phase: 0,
          fadeHeight: max(size.height, 44),
          mini: true,
          increaseContrast: false
        )
        context.withCGContext { cg in
          HeaderWashEngine.draw(in: cg, size: size, params: params)
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}
