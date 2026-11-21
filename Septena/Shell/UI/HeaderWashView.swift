import CoreGraphics
import SwiftUI

/// Small bounded in-memory cache of pre-rasterized static `HeaderWashEngine`
/// textures so scrolling, navigation, and Settings previews blit a GPU texture
/// instead of re-running procedural 3D noise / marching-squares on the main thread.
@MainActor
private enum HeaderWashBitmapCache {
  struct Key: Hashable {
    let params: HeaderWashParams
    let pixelWidth: Int
    let pixelHeight: Int
  }

  private static var cache: [Key: CGImage] = [:]
  private static var order: [Key] = []
  private static let maxEntries = 24

  static func image(for params: HeaderWashParams, size: CGSize, scale: CGFloat) -> CGImage? {
    let pw = max(1, Int((size.width * scale).rounded()))
    let ph = max(1, Int((size.height * scale).rounded()))
    guard pw <= 4096, ph <= 4096 else { return nil }
    let key = Key(params: params, pixelWidth: pw, pixelHeight: ph)
    if let hit = cache[key] { return hit }

    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
      data: nil,
      width: pw,
      height: ph,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: cs,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Match SwiftUI Canvas top-left coordinate system.
    ctx.translateBy(x: 0, y: CGFloat(ph))
    ctx.scaleBy(x: scale, y: -scale)
    HeaderWashEngine.draw(in: ctx, size: size, params: params)
    guard let img = ctx.makeImage() else { return nil }

    cache[key] = img
    order.append(key)
    if order.count > maxEntries {
      let oldest = order.removeFirst()
      cache.removeValue(forKey: oldest)
    }
    return img
  }
}

/// Procedural Header Wash backdrop for SwiftUI task lists (iOS, iPadOS, and
/// classic macOS window). See ADR 0019 and `docs/CUSTOMIZATION_SPEC.md`.
///
/// Renders purely via `HeaderWashEngine` in CoreGraphics, anchored to the top
/// edge (`ignoresSafeArea(edges: .top)`) so geometry bleeds cleanly behind the
/// iOS status bar / Dynamic Island and fades to transparent over `fadeHeight`.
/// Static mode caches a Retina `CGImage`; Slow drift renders asynchronously off
/// the main thread so scrolling stays locked at 120 Hz.
struct HeaderWashView: View {
  var projectID: String? = nil
  var fadeHeight: CGFloat = 380

  private let appearance = AppearancePreferences.shared
  @Environment(DayClock.self) private var dayClock
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.scenePhase) private var scenePhase

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

  private func makeParams(phase: Double) -> HeaderWashParams {
    let isDark = colorScheme == .dark
    return HeaderWashParams(
      style: appearance.canvasTexture,
      isDark: isDark,
      accent: appearance.accentRGB(isDark: isDark),
      intensity: appearance.textureIntensity,
      seed: AppearancePreferences.resolvedSeed(dayISO: dayClock.today, projectID: projectID),
      phase: phase,
      fadeHeight: fadeHeight,
      mini: false,
      increaseContrast: contrast == .increased
    )
  }

  var body: some View {
    if appearance.hasActiveTexture {
      ZStack {
        if shouldAnimate {
          // 15 fps off-main-thread Canvas keeps slow ambient 3D contour drift
          // silky without competing with 120 Hz touch scrolling.
          TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
            let params = makeParams(phase: phase(at: timeline.date))
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
              context.withCGContext { cg in
                HeaderWashEngine.draw(in: cg, size: size, params: params)
              }
            }
          }
        } else {
          let params = makeParams(phase: accumulatedPhase)
          let scale = min(displayScale, 2.0)
          Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            if let img = HeaderWashBitmapCache.image(for: params, size: size, scale: scale) {
              context.draw(Image(decorative: img, scale: scale), in: CGRect(origin: .zero, size: size))
            }
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
/// `HeaderWashEngine` used on live task lists (`mini: true`), bitmap-cached
/// so opening Settings ▸ Appearance is instant.
struct HeaderWashPreviewCanvas: View {
  let style: HeaderTextureStyle
  let isDark: Bool
  let accent: RGBTriple
  let intensity: Int
  let seed: UInt32
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    if style == .none {
      Color.clear
    } else {
      let scale = min(displayScale, 2.0)
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
        if let img = HeaderWashBitmapCache.image(for: params, size: size, scale: scale) {
          context.draw(Image(decorative: img, scale: scale), in: CGRect(origin: .zero, size: size))
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}
