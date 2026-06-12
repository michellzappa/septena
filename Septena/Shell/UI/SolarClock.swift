import Foundation
import CoreLocation

// SolarClock — today's sunrise and sunset for the ambient sky.
//
// Computed entirely on-device from a stored COARSE location using the NOAA
// sunrise approximation: no network, no tracking. One location fix is
// captured when the user enables "Sunrise from location" (Settings ▸ Home)
// and on later launches while it stays on; the coordinate is rounded to
// ~0.1° (≈11 km) before storing — enough to place dawn within a minute or
// two, useless for locating a person. Off / unavailable / polar edge →
// the fixed "design day" the solar ring was tuned on.

@MainActor
enum SolarClock {
  struct Times: Equatable {
    /// Local clock hours, 0..<24.
    var sunriseHour: Double
    var sunsetHour: Double
  }

  /// The fixed fallback day: up 6:30, down 19:00 — matches the hand-tuned
  /// solar-ring stops from before location awareness existed.
  static let designDay = Times(sunriseHour: 6.5, sunsetHour: 19.0)

  private static var cache: (day: String, times: Times)?

  /// Today's times. Cached per calendar day; recomputed after a new fix
  /// (`invalidate()`) or rollover. `now` should come from `DayClock`.
  static func today(now: Date) -> Times {
    let day = Self.dayKey(now)
    if let cache, cache.day == day { return cache.times }
    let times = computeForStoredLocation(on: now) ?? designDay
    cache = (day, times)
    return times
  }

  /// Drop the day cache — called after a fresh location fix lands.
  static func invalidate() { cache = nil }

  private static func dayKey(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
  }

  private static func computeForStoredLocation(on date: Date) -> Times? {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: SettingsKey.solarFromLocation) else { return nil }
    let lat = defaults.double(forKey: SettingsKey.solarLatitude)
    let lon = defaults.double(forKey: SettingsKey.solarLongitude)
    guard lat != 0 || lon != 0 else { return nil }   // no fix captured yet
    return compute(on: date, latitude: lat, longitude: lon)
  }

  /// NOAA-style approximation (declination + equation of time), accurate to
  /// a couple of minutes — plenty for placing light on a dial. Returns nil
  /// in polar day/night, where "sunrise" isn't a clock moment.
  static func compute(on date: Date, latitude: Double, longitude: Double) -> Times? {
    let cal = Calendar.current
    let n = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 180)

    // Solar declination (degrees), Cooper's approximation.
    let decl = -23.44 * cos((2 * .pi / 365) * (n + 10))
    let latR = latitude * .pi / 180
    let declR = decl * .pi / 180
    let cosH = -tan(latR) * tan(declR)
    guard cosH > -1, cosH < 1 else { return nil }    // midnight sun / polar night
    let halfDayHours = acos(cosH) * 180 / .pi / 15   // solar noon → sunrise/sunset

    // Equation of time (minutes), standard approximation.
    let b = 2 * .pi * (n - 81) / 364
    let eotMin = 9.87 * sin(2 * b) - 7.53 * cos(b) - 1.5 * sin(b)

    // Solar noon in local clock hours: longitude correction + EoT + zone.
    let tzHours = Double(TimeZone.current.secondsFromGMT(for: date)) / 3600
    let solarNoon = 12 - longitude / 15 - eotMin / 60 + tzHours

    func wrap(_ h: Double) -> Double {
      var v = h.truncatingRemainder(dividingBy: 24)
      if v < 0 { v += 24 }
      return v
    }
    return Times(sunriseHour: wrap(solarNoon - halfDayHours),
                 sunsetHour: wrap(solarNoon + halfDayHours))
  }
}

/// One-shot coarse location fetch feeding `SolarClock`. Kilometer accuracy,
/// rounded before storing, requested only while "Sunrise from location" is
/// on. Created on the main run loop so delegate callbacks land there too.
@MainActor
final class SolarLocationFetcher: NSObject, CLLocationManagerDelegate {
  static let shared = SolarLocationFetcher()

  private lazy var manager: CLLocationManager = {
    let m = CLLocationManager()
    m.delegate = self
    m.desiredAccuracy = kCLLocationAccuracyKilometer
    return m
  }()
  private var active = false

  /// Kick a refresh when the feature is on: prompts the first time, then
  /// captures a single fix. Cheap enough to call once per launch (the hero
  /// does) so the stored coordinate tracks travel without any monitoring.
  func refreshIfEnabled() {
    guard UserDefaults.standard.bool(forKey: SettingsKey.solarFromLocation),
          !active else { return }
    switch manager.authorizationStatus {
    case .notDetermined:
      active = true
      manager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse:
      active = true
      manager.requestLocation()
    default:
      break   // denied/restricted → SolarClock stays on the design day
    }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    MainActor.assumeIsolated {
      guard active else { return }
      switch manager.authorizationStatus {
      case .authorizedAlways, .authorizedWhenInUse:
        manager.requestLocation()
      case .denied, .restricted:
        active = false
      default:
        break
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager,
                                   didUpdateLocations locations: [CLLocation]) {
    MainActor.assumeIsolated {
      active = false
      guard let c = locations.last?.coordinate else { return }
      // Round to ~0.1° (≈11 km grid): enough for sunrise, useless for
      // locating a person — the only thing we ever persist.
      let defaults = UserDefaults.standard
      defaults.set((c.latitude * 10).rounded() / 10, forKey: SettingsKey.solarLatitude)
      defaults.set((c.longitude * 10).rounded() / 10, forKey: SettingsKey.solarLongitude)
      SolarClock.invalidate()
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager,
                                   didFailWithError error: Error) {
    MainActor.assumeIsolated { active = false }
  }
}
