import Foundation
import CoreBluetooth
#if canImport(UIKit)
import UIKit
#endif

// AranetBridge — passive BLE ad scanner for Aranet4 CO2 sensors.
//
// We do NOT connect via GATT. Earlier revisions tried that and ran into
// Aranet4 firmware that silently refuses third-party central
// connections even with "Smart Home Integration" toggled on. Instead,
// we listen for the device's broadcast advertisements: when Smart Home
// Integration is enabled the Aranet4 emits a manufacturer-specific
// payload every ~5s containing the current CO2 / temp / humidity /
// pressure / battery / status numbers. Reading them off the ad packet
// has three advantages over the GATT path:
//
//   1. No connection → no pairing, no bonding, no permission to be
//      "the one allowed central".
//   2. Works alongside the official Aranet Home app simultaneously —
//      the device advertises to everyone whether or not it has an
//      active GATT link.
//   3. No reconnect logic, no service/characteristic discovery, no
//      `setNotifyValue` plumbing.
//
// Cost: the ad payload only exposes the current reading. There's no
// path to read the device's onboard history buffer (that requires
// GATT). For our use case (live dashboard + per-device persistence
// in AirStore) this is acceptable.

private let kKnownPeripheralKey = "septena.aranet.peripheralUUID"
/// UserDefaults key for the "Background Capture" toggle in Settings →
/// Aranet. When on, scan with explicit service UUID filters so iOS
/// continues to deliver callbacks while the app is suspended.
private let kBackgroundCaptureKey = "septena.aranet.backgroundCapture"
/// Stable identifier handed to `CBCentralManagerOptionRestoreIdentifierKey`.
/// Lets iOS re-hand the central back to us when our process is
/// relaunched in the background to deliver a queued BLE event. Must
/// stay constant across launches — changing it loses the queued
/// peripherals (you'd get a fresh, empty manager on next launch).
private let kCentralRestoreID = "com.septena.aranet.central"

/// Candidate service UUIDs to filter on in background-capture mode.
/// Background CB scans MUST be filtered by service UUID (iOS won't
/// deliver callbacks for unfiltered scans while the app is suspended).
/// Different Aranet4 firmware revisions advertise different UUIDs, so
/// we filter on the union of every UUID community reverse-engineering
/// has documented. Foreground scans still use no filter; the
/// `services=[…]` line in the discovery log will tell you which of
/// these your device actually broadcasts (and therefore whether
/// background capture has any hope of working).
private let aranetBackgroundFilterUUIDs: [CBUUID] = [
  CBUUID(string: "f0cd1400-95da-4f4b-9ac8-aa55d312af0c"),
  CBUUID(string: "0000fce0-0000-1000-8000-00805f9b34fb"),
  CBUUID(string: "fce0"),
]

/// SAF Tehnika Bluetooth SIG company ID. The first two bytes of an
/// Aranet ad's manufacturer-specific data, little-endian (`02 07`).
private let aranetCompanyID: UInt16 = 0x0702

@MainActor
@Observable
final class AranetBridge: NSObject {
  // Observable surface — views/Settings read these.
  var state: ConnectionState = .idle
  var latest: AranetSnapshot? = nil
  var deviceName: String? = nil
  var lastError: String? = nil

  /// State labels are inherited from the GATT-era bridge so the
  /// existing Settings UI keeps rendering without churn. In passive
  /// mode the meanings are:
  ///   • `.idle` / `.disconnected` — not listening
  ///   • `.scanning`               — listening, no Aranet ads heard yet
  ///   • `.connected`              — at least one ad parsed in this session
  ///   • `.bluetoothOff` / `.unauthorized` — radio/permission states
  ///   • `.connecting` is unused now but kept in the enum for API
  ///     compatibility (Settings + Air view switch on it).
  enum ConnectionState: Equatable {
    case idle
    case unauthorized
    case bluetoothOff
    case scanning
    case connecting
    case connected
    case disconnected
  }

  /// Called on each fresh, parsed snapshot. SeptenaServices wires this
  /// to `AirStore.ingest` in `start()` so every captured ad flows into
  /// SwiftData without any view-side glue.
  var onSnapshot: ((AranetSnapshot) -> Void)?

  /// Lazily created — instantiating `CBCentralManager` is what triggers
  /// the system Bluetooth permission prompt, so we defer construction
  /// until the user actively asks us to scan.
  private var central: CBCentralManager?
  /// Set when the consumer asked us to listen. Drives auto-resume on
  /// `centralManagerDidUpdateState` once Bluetooth comes back on.
  private var wantsActive = false
  /// First-ad watchdog — surfaces a clear error if scanning runs for
  /// 20s without ever hearing an Aranet4 ad. Most common cause is that
  /// the device's Smart Home Integration is actually disabled despite
  /// what the UI shows; less commonly the device is out of range or
  /// in a different room.
  private var firstAdWatchdog: Task<Void, Never>?

  override init() {
    super.init()
    // No CBCentralManager here on purpose — see `ensureCentral()`.
  }

  /// Whether the user has opted in to background capture in Settings →
  /// Aranet. Drives both (a) which scan-filter mode `start()` uses and
  /// (b) whether the central is built with a restore identifier so
  /// iOS will relaunch the app on BLE events. Read fresh on each
  /// `start()` so flipping the toggle takes effect next scan.
  var backgroundCaptureEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: kBackgroundCaptureKey) }
    set {
      UserDefaults.standard.set(newValue, forKey: kBackgroundCaptureKey)
      // Toggling requires a central tear-down + rebuild — restore ID
      // is an init-time option, can't be added later. Next start()
      // call will reconstruct with the right options.
      if let central, central.isScanning { central.stopScan() }
      self.central = nil
    }
  }

  /// Build the CBCentralManager on first use. This line is what
  /// triggers iOS's Bluetooth permission prompt. If background capture
  /// is on, we pass `CBCentralManagerOptionRestoreIdentifierKey` so
  /// iOS can hand the same central back to us on a background
  /// relaunch — without this option the central would be a fresh
  /// instance with no memory of the scan we left running.
  private func ensureCentral() -> CBCentralManager {
    if let central { return central }
    var options: [String: Any] = [
      CBCentralManagerOptionShowPowerAlertKey: true,
    ]
    if backgroundCaptureEnabled {
      options[CBCentralManagerOptionRestoreIdentifierKey] = kCentralRestoreID
    }
    let new = CBCentralManager(delegate: self, queue: .main, options: options)
    central = new
    return new
  }

  // MARK: - Public API

  /// Begin listening for Aranet ads. Idempotent. First call lazily
  /// creates the CBCentralManager, which triggers iOS's Bluetooth
  /// permission prompt.
  func start() {
    wantsActive = true
    lastError = nil
    let central = ensureCentral()
    guard central.state == .poweredOn else {
      reflectState()
      return
    }
    state = .scanning
    if backgroundCaptureEnabled {
      // Background-compatible scan path. iOS requires:
      //   • An explicit service-UUID filter (unfiltered scans are
      //     killed when the app suspends).
      //   • `allowDuplicates` is *ignored* in background; iOS dedupes
      //     hard regardless. We still pass it for the foreground
      //     portion of the same scan session.
      //
      // Trade-off: ad-callback resolution drops from ~5s (foreground,
      // no dedupe) to ~15–30 min (background, throttled). For the
      // sleep-quality correlation use case that's still useful —
      // even one reading per half hour gives you average + peak CO2
      // across the night.
      let filter = aranetBackgroundFilterUUIDs.map(\.uuidString).joined(separator: ",")
      SeptenaLog.info("[Aranet] starting background-capable scan (filter=\(filter))")
      central.scanForPeripherals(
        withServices: aranetBackgroundFilterUUIDs,
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
      )
    } else {
      // Foreground-only scan path. No service filter (Aranet4 firmware
      // varies in which UUIDs it advertises, and we don't want to miss
      // devices) + `allowDuplicates = true` so we get one callback per
      // ~5s broadcast cycle.
      SeptenaLog.info("[Aranet] starting foreground passive scan (no UUID filter, allow duplicates)")
      central.scanForPeripherals(
        withServices: nil,
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
      )
    }
    armFirstAdWatchdog()
  }

  /// Stop listening. Safe to call before `start()` has ever run.
  func stop() {
    wantsActive = false
    cancelFirstAdWatchdog()
    guard let central else { state = .idle; return }
    if central.isScanning { central.stopScan() }
    state = .idle
  }

  /// Clear the stored peripheral identifier. Kept for UI compatibility
  /// — in passive mode we no longer pin to a single device, so this
  /// just resets the cached name/latest in case the user is swapping
  /// hardware.
  func forget() {
    UserDefaults.standard.removeObject(forKey: kKnownPeripheralKey)
    stop()
    deviceName = nil
    latest = nil
  }

  /// True if we've previously seen any Aranet4 ad. Used by views to
  /// decide whether `start()` is safe to call silently (no prompt
  /// expected because the user already granted Bluetooth previously).
  var hasKnownPeripheral: Bool {
    UserDefaults.standard.string(forKey: kKnownPeripheralKey) != nil
  }

  // MARK: - Internals

  private func reflectState() {
    guard let central else { state = .idle; return }
    switch central.state {
    case .poweredOn:
      if state == .idle && wantsActive { start() }
    case .poweredOff:    state = .bluetoothOff
    case .unauthorized:  state = .unauthorized
    case .unsupported:   state = .bluetoothOff
    case .resetting,
         .unknown:       state = .idle
    @unknown default:    state = .idle
    }
  }

  /// Arm the 20s first-ad watchdog. If we never receive a parsable
  /// Aranet4 ad in that window, set a friendly error string so the
  /// Settings pane shows actionable guidance. Cleared on first parse.
  private func armFirstAdWatchdog() {
    firstAdWatchdog?.cancel()
    firstAdWatchdog = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 20_000_000_000)
      guard !Task.isCancelled, let self else { return }
      guard self.state == .scanning, self.latest == nil else { return }
      SeptenaLog.info("[Aranet] first-ad watchdog fired — no Aranet4 ads heard")
      self.lastError = "No Aranet4 broadcasts heard. Open the Aranet Home app and turn on Smart Home Integration (Settings → Bluetooth), then come back."
    }
  }

  private func cancelFirstAdWatchdog() {
    firstAdWatchdog?.cancel()
    firstAdWatchdog = nil
  }
}

// MARK: - CBCentralManagerDelegate

extension AranetBridge: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    reflectState()
  }

  /// Called by iOS when our process is relaunched in the background
  /// to receive a queued BLE event. The dict's
  /// `CBCentralManagerRestoredStateScanServicesKey` tells us which
  /// scan was active when we were suspended; we don't need to act on
  /// it directly (iOS resumes the scan automatically) but flipping
  /// `wantsActive` ensures `centralManagerDidUpdateState` will fall
  /// through to a fresh `start()` if iOS hasn't already resumed.
  /// Without this method implemented, restore would fail and the
  /// scan would be dropped on relaunch.
  func centralManager(_ central: CBCentralManager,
                      willRestoreState dict: [String: Any]) {
    let services = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] ?? []
    SeptenaLog.info("[Aranet] willRestoreState — restoring scan with services=\(services.map(\.uuidString))")
    wantsActive = true
    state = .scanning
  }

  func centralManager(_ central: CBCentralManager,
                      didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any],
                      rssi RSSI: NSNumber) {
    // Pull both name sources — iOS may return either depending on
    // whether the peripheral has been cached previously.
    let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    let name = peripheral.name ?? advName ?? ""
    let lower = name.lowercased()
    guard lower.hasPrefix("aranet4") else {
      // Not our device — but if it's another Aranet model, log it so
      // the user gets a hint about model mismatch when nothing parses.
      if lower.hasPrefix("aranet") {
        SeptenaLog.info("[Aranet] saw non-Aranet4 model: \(name) — skipped")
      }
      return
    }

    let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
    // Service UUIDs from the ad packet. Critical diagnostic: iOS will
    // only deliver background BLE scan callbacks for scans filtered on
    // a specific service UUID, so we need to know whether the Aranet4
    // includes one in its ads at all (varies by firmware). Logged on
    // every hit so the Settings "Enable background capture" toggle's
    // viability is self-evident from the console.
    let svcUUIDs   = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let overflowUUIDs = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
    let svcList = (svcUUIDs + overflowUUIDs).map(\.uuidString).joined(separator: ",")
    let hex = mfg?.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ") ?? "—"
    SeptenaLog.info("[Aranet] ad from \(name) rssi=\(RSSI) bytes=\(mfg?.count ?? 0) " +
                    "services=[\(svcList.isEmpty ? "—" : svcList)] mfg=\(hex)")

    guard let mfg, let snap = AranetSnapshot(advertisementData: mfg) else {
      // Discovery without parseable payload — that's the "Smart Home
      // Integration is off" case. The watchdog will surface guidance
      // to the user; nothing for us to do here per-ad.
      return
    }

    // First successful parse → remember the device, flip state to
    // "connected" (i.e. receiving), and cancel the watchdog.
    if latest == nil {
      UserDefaults.standard.set(peripheral.identifier.uuidString,
                                forKey: kKnownPeripheralKey)
    }
    cancelFirstAdWatchdog()
    deviceName = name
    latest = snap
    lastError = nil
    state = .connected
    onSnapshot?(snap)
  }
}

// MARK: - Snapshot

/// One decoded reading parsed from an Aranet4 broadcast advertisement.
///
/// Byte layout of the manufacturer-specific data (Smart Home
/// Integration mode), from the community-reversed firmware spec:
///
///   Offset Bytes Field
///   ------ ----- ------------------------------------------
///    0–1    2    Company ID (0x0702, SAF Tehnika)
///    2–7    6    Vendor header / firmware identifiers
///    8–9    2    CO2 (UInt16 LE, ppm)
///   10–11   2    Temperature (Int16 LE, × 20 → °C)
///   12–13   2    Pressure (UInt16 LE, × 10 → hPa)
///   14      1    Humidity (UInt8, percent)
///   15      1    Battery (UInt8, percent)
///   16      1    Status (UInt8) — 0=OK, 1=error, 2=warming up
///   17–18   2    Interval (UInt16 LE, seconds)
///   19–20   2    Age (UInt16 LE, seconds since last measurement)
///
/// Total payload is ~22 bytes including the company ID prefix.
/// Some firmware revisions emit a shortened beacon ad with only the
/// CO2 word; we fall back to that if the full layout doesn't fit.
struct AranetSnapshot: Equatable {
  let co2Ppm: Int
  let tempC: Double
  let pressureHPa: Double
  let humidityPct: Int
  let batteryPct: Int
  let status: Int
  let intervalSec: Int
  let ageSec: Int
  let capturedAt: Date

  /// Parse from the manufacturer-specific advertisement payload. The
  /// first two bytes must be the SAF Tehnika company ID; everything
  /// after that is per the layout table in the doc comment.
  init?(advertisementData data: Data) {
    guard data.count >= 2 else { return nil }
    let cid = UInt16(data[0]) | (UInt16(data[1]) << 8)
    guard cid == aranetCompanyID else { return nil }

    // Helpers — all offsets are relative to the start of the
    // manufacturer-data blob, including the 2-byte company ID prefix.
    func u16(_ off: Int) -> UInt16? {
      guard data.count >= off + 2 else { return nil }
      return UInt16(data[off]) | (UInt16(data[off + 1]) << 8)
    }
    func i16(_ off: Int) -> Int16? { u16(off).map(Int16.init(bitPattern:)) }
    func u8(_ off: Int) -> UInt8? {
      guard data.count >= off + 1 else { return nil }
      return data[off]
    }

    // Full Smart Home Integration payload. We require at least the
    // status byte (offset 16) to consider the layout valid; anything
    // shorter is a different ad variant we can't trust.
    guard data.count >= 17,
          let co2 = u16(8),
          let tempRaw = i16(10),
          let pressureRaw = u16(12),
          let humidity = u8(14),
          let battery = u8(15),
          let status = u8(16) else {
      return nil
    }

    let interval = u16(17).map(Int.init) ?? 0
    let age = u16(19).map(Int.init) ?? 0

    self.co2Ppm      = Int(co2)
    self.tempC       = Double(tempRaw) / 20.0
    self.pressureHPa = Double(pressureRaw) / 10.0
    self.humidityPct = Int(humidity)
    self.batteryPct  = Int(battery)
    self.status      = Int(status)
    self.intervalSec = interval
    self.ageSec      = age
    self.capturedAt  = Date().addingTimeInterval(-Double(age))
  }

  /// Bucket the CO2 reading into the existing dashboard band labels.
  var co2Band: String {
    switch co2Ppm {
    case ..<700:  return "good"
    case ..<1000: return "ok"
    case ..<1400: return "poor"
    default:      return "bad"
    }
  }
}
