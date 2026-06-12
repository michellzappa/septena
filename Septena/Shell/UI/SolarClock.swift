import Foundation

// SolarClock — today's sunrise and sunset for the ambient sky.
//
// NO location permission. The device's time zone (which every app reads
// freely) maps to a representative city coordinate via the small built-in
// table below, and the NOAA approximation does the rest on-device. Within
// one zone, solar times vary by minutes to ~half an hour — invisible inside
// the sky gradient's two-hour dawn/dusk transitions — and the zone follows
// the user automatically when they travel. Nothing is asked, fetched, or
// stored. Unknown zone (or polar edge) → the fixed "design day" the solar
// ring was tuned on.

@MainActor
enum SolarClock {
  struct Times: Equatable {
    /// Local clock hours, 0..<24.
    var sunriseHour: Double
    var sunsetHour: Double
  }

  /// The fixed fallback day: up 6:30, down 19:00 — matches the hand-tuned
  /// solar-ring stops from before geography existed.
  static let designDay = Times(sunriseHour: 6.5, sunsetHour: 19.0)

  private static var cache: (key: String, times: Times)?

  /// Today's times. Cached per (calendar day, time zone); `now` should come
  /// from `DayClock`.
  static func today(now: Date) -> Times {
    let zone = TimeZone.current.identifier
    let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
    let key = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)|\(zone)"
    if let cache, cache.key == key { return cache.times }
    let times = zoneCoordinates[zone]
      .flatMap { compute(on: now, latitude: $0.lat, longitude: $0.lon) }
      ?? designDay
    cache = (key, times)
    return times
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

  /// Representative coordinates per IANA zone (zone1970-style city points,
  /// one decimal — city-level is all sunrise needs). Major zones only;
  /// anything absent falls back to the design day. Includes a few legacy
  /// aliases (Calcutta, Saigon) in case the OS reports them.
  private static let zoneCoordinates: [String: (lat: Double, lon: Double)] = [
    // Europe
    "Europe/London": (51.5, -0.1), "Europe/Dublin": (53.3, -6.3),
    "Europe/Lisbon": (38.7, -9.1), "Europe/Madrid": (40.4, -3.7),
    "Europe/Paris": (48.9, 2.3), "Europe/Amsterdam": (52.4, 4.9),
    "Europe/Brussels": (50.8, 4.4), "Europe/Luxembourg": (49.6, 6.1),
    "Europe/Zurich": (47.4, 8.5), "Europe/Berlin": (52.5, 13.4),
    "Europe/Copenhagen": (55.7, 12.6), "Europe/Oslo": (59.9, 10.8),
    "Europe/Stockholm": (59.3, 18.1), "Europe/Helsinki": (60.2, 24.9),
    "Europe/Rome": (41.9, 12.5), "Europe/Vienna": (48.2, 16.4),
    "Europe/Prague": (50.1, 14.4), "Europe/Warsaw": (52.2, 21.0),
    "Europe/Budapest": (47.5, 19.0), "Europe/Athens": (38.0, 23.7),
    "Europe/Bucharest": (44.4, 26.1), "Europe/Sofia": (42.7, 23.3),
    "Europe/Kyiv": (50.5, 30.5), "Europe/Kiev": (50.5, 30.5),
    "Europe/Istanbul": (41.0, 28.9), "Europe/Moscow": (55.8, 37.6),
    "Europe/Zagreb": (45.8, 16.0), "Europe/Belgrade": (44.8, 20.5),
    "Europe/Bratislava": (48.1, 17.1), "Europe/Ljubljana": (46.1, 14.5),
    "Europe/Tallinn": (59.4, 24.8), "Europe/Riga": (56.9, 24.1),
    "Europe/Vilnius": (54.7, 25.3), "Europe/Minsk": (53.9, 27.6),
    "Atlantic/Reykjavik": (64.1, -21.9), "Atlantic/Canary": (28.1, -15.4),
    "Atlantic/Azores": (37.7, -25.7), "Atlantic/Madeira": (32.6, -16.9),
    // Americas
    "America/St_Johns": (47.6, -52.7), "America/Halifax": (44.6, -63.6),
    "America/New_York": (40.7, -74.0), "America/Toronto": (43.7, -79.4),
    "America/Detroit": (42.3, -83.0), "America/Montreal": (45.5, -73.6),
    "America/Indiana/Indianapolis": (39.8, -86.2),
    "America/Kentucky/Louisville": (38.3, -85.8),
    "America/Chicago": (41.9, -87.6), "America/Winnipeg": (49.9, -97.1),
    "America/Mexico_City": (19.4, -99.1), "America/Monterrey": (25.7, -100.3),
    "America/Denver": (39.7, -105.0), "America/Edmonton": (53.5, -113.5),
    "America/Boise": (43.6, -116.2), "America/Regina": (50.5, -104.6),
    "America/Phoenix": (33.4, -112.1), "America/Los_Angeles": (34.1, -118.2),
    "America/Vancouver": (49.3, -123.1), "America/Tijuana": (32.5, -117.0),
    "America/Anchorage": (61.2, -149.9), "Pacific/Honolulu": (21.3, -157.9),
    "America/Sao_Paulo": (-23.5, -46.6), "America/Bahia": (-13.0, -38.5),
    "America/Fortaleza": (-3.7, -38.5), "America/Recife": (-8.1, -34.9),
    "America/Belem": (-1.5, -48.5), "America/Manaus": (-3.1, -60.0),
    "America/Cuiaba": (-15.6, -56.1), "America/Campo_Grande": (-20.4, -54.6),
    "America/Argentina/Buenos_Aires": (-34.6, -58.4),
    "America/Santiago": (-33.4, -70.7), "America/Lima": (-12.0, -77.0),
    "America/Bogota": (4.6, -74.1), "America/Caracas": (10.5, -66.9),
    "America/Guatemala": (14.6, -90.5), "America/Costa_Rica": (9.9, -84.1),
    "America/El_Salvador": (13.7, -89.2), "America/Managua": (12.1, -86.3),
    "America/Tegucigalpa": (14.1, -87.2), "America/Panama": (9.0, -79.5),
    "America/Havana": (23.1, -82.4), "America/Santo_Domingo": (18.5, -69.9),
    "America/Puerto_Rico": (18.5, -66.1), "America/Jamaica": (18.0, -76.8),
    "America/Montevideo": (-34.9, -56.2), "America/La_Paz": (-16.5, -68.1),
    "America/Asuncion": (-25.3, -57.6), "America/Guayaquil": (-2.2, -79.9),
    // Asia & Middle East
    "Asia/Tokyo": (35.7, 139.7), "Asia/Seoul": (37.6, 127.0),
    "Asia/Shanghai": (31.2, 121.5), "Asia/Hong_Kong": (22.3, 114.2),
    "Asia/Taipei": (25.0, 121.5), "Asia/Manila": (14.6, 121.0),
    "Asia/Singapore": (1.4, 103.8), "Asia/Kuala_Lumpur": (3.1, 101.7),
    "Asia/Jakarta": (-6.2, 106.8), "Asia/Makassar": (-5.1, 119.4),
    "Asia/Bangkok": (13.8, 100.5), "Asia/Ho_Chi_Minh": (10.8, 106.7),
    "Asia/Saigon": (10.8, 106.7), "Asia/Yangon": (16.8, 96.2),
    "Asia/Dhaka": (23.7, 90.4), "Asia/Kolkata": (22.6, 88.4),
    "Asia/Calcutta": (22.6, 88.4), "Asia/Colombo": (6.9, 79.9),
    "Asia/Kathmandu": (27.7, 85.3), "Asia/Katmandu": (27.7, 85.3),
    "Asia/Karachi": (24.9, 67.0), "Asia/Kabul": (34.5, 69.2),
    "Asia/Tashkent": (41.3, 69.3), "Asia/Almaty": (43.2, 76.9),
    "Asia/Dubai": (25.3, 55.3), "Asia/Qatar": (25.3, 51.5),
    "Asia/Riyadh": (24.7, 46.7), "Asia/Kuwait": (29.4, 48.0),
    "Asia/Baghdad": (33.3, 44.4), "Asia/Tehran": (35.7, 51.4),
    "Asia/Jerusalem": (31.8, 35.2), "Asia/Beirut": (33.9, 35.5),
    "Asia/Amman": (32.0, 35.9), "Asia/Damascus": (33.5, 36.3),
    "Asia/Nicosia": (35.2, 33.4), "Asia/Baku": (40.4, 49.9),
    "Asia/Tbilisi": (41.7, 44.8), "Asia/Yerevan": (40.2, 44.5),
    "Asia/Ulaanbaatar": (47.9, 106.9), "Asia/Novosibirsk": (55.0, 82.9),
    "Asia/Yekaterinburg": (56.8, 60.6), "Asia/Vladivostok": (43.1, 131.9),
    // Africa
    "Africa/Cairo": (30.1, 31.2), "Africa/Lagos": (6.5, 3.4),
    "Africa/Accra": (5.6, -0.2), "Africa/Abidjan": (5.3, -4.0),
    "Africa/Dakar": (14.7, -17.4), "Africa/Casablanca": (33.6, -7.6),
    "Africa/Algiers": (36.8, 3.1), "Africa/Tunis": (36.8, 10.2),
    "Africa/Tripoli": (32.9, 13.2), "Africa/Nairobi": (-1.3, 36.8),
    "Africa/Addis_Ababa": (9.0, 38.7), "Africa/Dar_es_Salaam": (-6.8, 39.3),
    "Africa/Kampala": (0.3, 32.6), "Africa/Khartoum": (15.6, 32.5),
    "Africa/Johannesburg": (-26.2, 28.0), "Africa/Lusaka": (-15.4, 28.3),
    "Africa/Harare": (-17.8, 31.0), "Africa/Maputo": (-26.0, 32.6),
    "Africa/Luanda": (-8.8, 13.2), "Africa/Kinshasa": (-4.3, 15.3),
    // Oceania
    "Australia/Sydney": (-33.9, 151.2), "Australia/Melbourne": (-37.8, 145.0),
    "Australia/Brisbane": (-27.5, 153.0), "Australia/Perth": (-32.0, 115.9),
    "Australia/Adelaide": (-34.9, 138.6), "Australia/Hobart": (-42.9, 147.3),
    "Australia/Darwin": (-12.5, 130.8), "Pacific/Auckland": (-36.8, 174.8),
    "Pacific/Fiji": (-18.1, 178.4), "Pacific/Guam": (13.5, 144.8),
    "Pacific/Port_Moresby": (-9.4, 147.2),
  ]
}
