import Foundation
import simd

// SkyAtmosphere — the physical sky renderer shared by every surface that draws
// the "real current sky": the phone's `SkyTopWash`, and the watch's
// `WatchSkyWash`. Pure Foundation + simd (no SwiftUI, no DayClock), so it
// compiles straight into the watch target alongside `SolarClock` and the two
// can never disagree about the sky overhead.

/// Faithful port of Horizon's atmosphere renderer (`gradient.ts`). Pure and
/// `nonisolated` — ~30k iterations, so callers run it off the main thread and
/// only when the sun has moved enough to matter.
enum SkyAtmosphere {
  typealias V3 = SIMD3<Double>

  /// One gradient stop. `location` runs 0 = zenith (top) … 1 = horizon
  /// (bottom); `r/g/b` are sRGB-encoded 0…1 (post-gamma, like a CSS `rgb()`).
  struct Stop: Equatable, Sendable {
    var location: Double
    var r, g, b: Double
  }

  // Coefficients of media components (m^-1)
  private static let rayleighScatter = V3(5.802e-6, 13.558e-6, 33.1e-6)
  private static let mieScatter = 3.996e-6
  private static let mieAbsorb = 4.44e-6
  private static let ozoneAbsorb = V3(0.65e-6, 1.881e-6, 0.085e-6)

  // Altitude density distribution metrics
  private static let rayleighScaleHeight = 8e3
  private static let mieScaleHeight = 1.2e3

  // Geometry
  private static let groundRadius = 6_360e3
  private static let topRadius = 6_460e3
  private static let sunIntensity = 1.0

  // Rendering — `samples` drives both the stop count and the integration
  // steps (32 in the original; 24 is visually identical for a soft wash and
  // ~40% cheaper).
  private static let samples = 24
  private static let fovDeg = 75.0

  // Post-processing
  private static let exposure = 25.0
  private static let gamma = 2.2
  private static let sunsetBiasStrength = 0.1

  // ACES tonemapper (Knarkowicz)
  private static func aces(_ c: V3) -> V3 {
    func f(_ x: Double) -> Double {
      let n = x * (2.51 * x + 0.03)
      let d = x * (2.43 * x + 0.59) + 0.14
      return max(0, min(1, n / d))
    }
    return V3(f(c.x), f(c.y), f(c.z))
  }

  // Enhance sunset hues (warmer near the horizon / twilight, neutral midday)
  private static func applySunsetBias(_ c: V3) -> V3 {
    let lum = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    let w = 1.0 / (1.0 + 2.0 * lum)
    let k = sunsetBiasStrength
    return V3(max(0, c.x * (1.0 + 0.5 * k * w)),   // boost red
             max(0, c.y * (1.0 - 0.5 * k * w)),    // suppress green
             max(0, c.z * (1.0 + 1.0 * k * w)))    // boost blue
  }

  private static func rayleighPhase(_ angle: Double) -> Double {
    (3 * (1 + pow(cos(angle), 2))) / (16 * Double.pi)
  }

  private static func miePhase(_ angle: Double) -> Double {
    let g = 0.8
    let scale = 3 / (8 * Double.pi)
    let num = (1 - g * g) * (1 + pow(cos(angle), 2))
    let denom = (2 + g * g) * pow(1 + g * g - 2 * g * cos(angle), 1.5)
    return (scale * num) / denom
  }

  // Ray/sphere intersection (Real-Time Collision Detection §5.3.2). Sphere
  // centered at the origin, so M = P. nil = miss.
  private static func intersectSphere(_ p: V3, _ d: V3, _ r: Double) -> Double? {
    let b = simd_dot(p, d)
    let c = simd_dot(p, p) - r * r
    let discr = b * b - c
    if discr < 0 { return nil }
    let t = -b - sqrt(discr)
    if t < 0 { return -b + sqrt(discr) }   // origin inside sphere → far hit
    return t
  }

  // Per-channel transmittance (Beer-Lambert) along a ray to the top of the
  // atmosphere, by marching the optical depth.
  private static func transmittance(height: Double, angle: Double) -> V3 {
    let rayOrigin = V3(0, groundRadius + height, 0)
    let rayDirection = V3(sin(angle), cos(angle), 0)
    guard let distance = intersectSphere(rayOrigin, rayDirection, topRadius),
          distance != 0 else { return V3(1, 1, 1) }

    let segmentLength = distance / Double(samples)
    var t = 0.5 * segmentLength
    var odRayleigh = 0.0, odMie = 0.0, odOzone = 0.0
    for _ in 0..<samples {
      let pos = rayOrigin + rayDirection * t
      let h = simd_length(pos) - groundRadius
      odRayleigh += exp(-h / rayleighScaleHeight) * segmentLength
      odMie += exp(-h / mieScaleHeight) * segmentLength
      // Triangular ozone profile centered at 25 km, half-width 15 km.
      odOzone += (1.0 - min(abs(h - 25e3) / 15e3, 1.0)) * segmentLength
      t += segmentLength
    }

    let tau = -(rayleighScatter * odRayleigh
                + V3(mieAbsorb, mieAbsorb, mieAbsorb) * odMie
                + ozoneAbsorb * odOzone)
    return V3(exp(tau.x), exp(tau.y), exp(tau.z))
  }

  /// Render the sky at a given solar `elevation` (radians) into ordered
  /// stops (ascending `location`, zenith → horizon).
  static func render(elevation: Double) -> [Stop] {
    let cameraPosition = V3(0, groundRadius, 0)
    let sunDirection = simd_normalize(V3(cos(elevation), sin(elevation), 0))
    let focalZ = 1.0 / tan((fovDeg * 0.5 * .pi) / 180.0)

    var stops: [Stop] = []
    stops.reserveCapacity(samples)

    for i in 0..<samples {
      let s = Double(i) / Double(samples - 1)
      let viewDirection = simd_normalize(V3(0, s, focalZ))
      var inscattered = V3(0, 0, 0)

      if let tExitTop = intersectSphere(cameraPosition, viewDirection, topRadius),
         tExitTop > 0 {
        let segmentLength = tExitTop / Double(samples)
        var tRay = segmentLength * 0.5

        let originRadius = simd_length(cameraPosition)
        let isDownward = simd_dot(cameraPosition, viewDirection) / originRadius < 0.0
        let startHeight = originRadius - groundRadius
        let startCos = max(-1.0, min(1.0, simd_dot(cameraPosition / originRadius, viewDirection)))
        let camToSpace = transmittance(height: startHeight, angle: acos(abs(startCos)))

        for _ in 0..<samples {
          let samplePos = cameraPosition + viewDirection * tRay
          let sampleRadius = simd_length(samplePos)
          let upUnit = samplePos / sampleRadius
          let sampleHeight = sampleRadius - groundRadius

          let viewCos = max(-1.0, min(1.0, simd_dot(upUnit, viewDirection)))
          let sunCos = max(-1.0, min(1.0, simd_dot(upUnit, sunDirection)))
          let toSpace = transmittance(height: sampleHeight, angle: acos(abs(viewCos)))

          var camToSample = V3(0, 0, 0)
          for k in 0..<3 {
            camToSample[k] = isDownward ? toSpace[k] / camToSpace[k]
                                        : camToSpace[k] / toSpace[k]
          }
          let toLight = transmittance(height: sampleHeight, angle: acos(sunCos))

          let densityRay = exp(-sampleHeight / rayleighScaleHeight)
          let densityMie = exp(-sampleHeight / mieScaleHeight)
          let sunViewAngle = acos(max(-1.0, min(1.0, simd_dot(sunDirection, viewDirection))))
          let phaseR = rayleighPhase(sunViewAngle)
          let phaseM = miePhase(sunViewAngle)

          for k in 0..<3 {
            let scattered = toLight[k]
              * (rayleighScatter[k] * densityRay * phaseR + mieScatter * densityMie * phaseM)
            inscattered[k] += camToSample[k] * scattered * segmentLength
          }
          tRay += segmentLength
        }
        inscattered *= sunIntensity
      }

      // Exposure → sunset bias → ACES tonemap → gamma → sRGB.
      var color = applySunsetBias(inscattered * exposure)
      color = aces(color)
      color = V3(pow(color.x, 1 / gamma), pow(color.y, 1 / gamma), pow(color.z, 1 / gamma))

      // s = 0 looks at the horizon (bottom), s = 1 highest into the sky (top).
      stops.append(Stop(location: 1 - s,
                        r: max(0, min(1, color.x)),
                        g: max(0, min(1, color.y)),
                        b: max(0, min(1, color.z))))
    }

    stops.sort { $0.location < $1.location }
    return stops
  }
}
