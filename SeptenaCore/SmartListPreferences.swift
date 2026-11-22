import Foundation
import Observation

// Per-account customization for the top "special" smart lists in the sidebar
// (`registry/destinations.json`).
//
// Registry-based and synced across all devices via `smartListOrder` and
// `smartListHidden` in `registry/settings.json`:
//   • `order` is ORDERING ONLY, never membership — any destination in
//     `Self.sidebarDestinations` absent from `order` is appended in its
//     canonical `sidebarOrder`, and unknown IDs are ignored.
//   • `hidden` lists destination IDs explicitly hidden by the user.
//     Destinations with `canHide == false` (e.g. `today`) are never hidden.
//   • Destinations with `visibility == "whenNonEmpty"` (`starred`, `faded`,
//     `recentlyDeleted`) still obey progressive disclosure when not hidden:
//     they appear only while non-empty, and stay hidden when explicitly hidden.
//
// Smart lists remain a dedicated "special" group above Areas & Projects on
// every surface — reorderable among themselves, never mixed into areas or
// projects below.

extension Notification.Name {
  /// Posted whenever the user or an inbound sync changes smart-list order or
  /// visibility so AppKit and SwiftUI sidebars rebuild live.
  static let septenaSmartListsChanged = Notification.Name("septena.smartListsChanged")
}

@MainActor
@Observable
final class SmartListPreferences {
  static let shared = SmartListPreferences()

  struct Snapshot: Equatable {
    let order: [String]
    let hidden: [String]
  }

  /// Sanitized user-defined order of canonical `RegistryDestination.id`s.
  /// Empty means canonical registry `sidebarOrder`.
  private(set) var order: [String]

  /// Sanitized set (stored in stable order) of hidden `RegistryDestination.id`s.
  private(set) var hidden: [String]

  /// Monotonically incremented on every change so `@Observable` SwiftUI views
  /// reading `SmartListPreferences.shared` always invalidate.
  private(set) var revision: UInt = 0

  private var isAdoptingSynced = false
  private var syncObserver: NSObjectProtocol?

  private init() {
    let ud = UserDefaults.standard
    let savedOrder = ud.stringArray(forKey: RegistrySettings.StorageKey.smartListOrder) ?? []
    let savedHidden = ud.stringArray(forKey: RegistrySettings.StorageKey.smartListHidden) ?? []
    self.order = Self.sanitizeOrder(savedOrder)
    self.hidden = Self.sanitizeHidden(savedHidden)

    #if SEPTASK
    syncObserver = NotificationCenter.default.addObserver(
      forName: .septaskSettingsPulled, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.adoptSynced(SeptaskSyncedSettings.current())
      }
    }
    #endif
  }

  // MARK: - Resolution (registry-driven)

  /// The destinations that are sidebar rows. A `todayBand` destination
  /// (Inbox) draws inside Today and has no row, so it never takes part in
  /// ordering or show/hide.
  static let sidebarDestinations: [RegistryDestination] =
    RegistryDestinations.all.filter { $0.visibility != "todayBand" }
  static let sidebarById: [String: RegistryDestination] =
    Dictionary(uniqueKeysWithValues: sidebarDestinations.map { ($0.id, $0) })

  /// All canonical smart-list destinations from `registry/destinations.json`,
  /// ordered by the account's `smartListOrder` with any unmentioned registry
  /// destinations appended in their canonical `sidebarOrder`.
  var orderedDestinations: [RegistryDestination] {
    _ = revision
    let known = Self.sidebarById
    var result: [RegistryDestination] = []
    var seen = Set<String>()
    for id in order {
      if let dest = known[id], seen.insert(id).inserted {
        result.append(dest)
      }
    }
    for dest in Self.sidebarDestinations where seen.insert(dest.id).inserted {
      result.append(dest)
    }
    return result
  }

  /// True when the destination is hidden by the user. Destinations marked
  /// `canHide == false` in `registry/destinations.json` are never hidden.
  func isHidden(_ destinationID: String) -> Bool {
    _ = revision
    guard let dest = RegistryDestinations.byId[destinationID], dest.canHide else {
      return false
    }
    return hidden.contains(destinationID)
  }

  /// The visible special smart-list destinations in display order, honoring
  /// both user show/hide choices and registry `whenNonEmpty` visibility.
  func visibleDestinations(nonEmptyIDs: Set<String>) -> [RegistryDestination] {
    orderedDestinations.filter { dest in
      guard !isHidden(dest.id) else { return false }
      if dest.visibility == "whenNonEmpty" {
        return nonEmptyIDs.contains(dest.id)
      }
      return true
    }
  }

  /// True when either visibility or order differs from the canonical registry
  /// defaults.
  var isCustomized: Bool {
    _ = revision
    if !hidden.isEmpty { return true }
    return orderedDestinations.map(\.id) != Self.sidebarDestinations.map(\.id)
  }

  // MARK: - Mutations (persisted locally + synced per account)

  func snapshot() -> Snapshot {
    Snapshot(order: order, hidden: hidden)
  }

  func restore(_ snap: Snapshot) {
    applyLocal(order: Self.sanitizeOrder(snap.order),
               hidden: Self.sanitizeHidden(snap.hidden))
  }

  func setHidden(_ shouldHide: Bool, for destinationID: String) {
    guard let dest = RegistryDestinations.byId[destinationID], dest.canHide else { return }
    var next = hidden
    if shouldHide {
      if !next.contains(destinationID) { next.append(destinationID) }
    } else {
      next.removeAll { $0 == destinationID }
    }
    applyLocal(order: order, hidden: Self.sanitizeHidden(next))
  }

  func reorder(orderedIDs: [String]) {
    var full = Self.sanitizeOrder(orderedIDs)
    let seen = Set(full)
    for dest in Self.sidebarDestinations where !seen.contains(dest.id) {
      full.append(dest.id)
    }
    applyLocal(order: full, hidden: hidden)
  }

  /// SwiftUI `.onMove` helper for the full ordered list in Settings.
  func move(fromOffsets source: IndexSet, toOffset destination: Int) {
    var ids = orderedDestinations.map(\.id)
    let moving = source.sorted().map { ids[$0] }
    for index in source.sorted(by: >) {
      ids.remove(at: index)
    }
    let removedBefore = source.filter { $0 < destination }.count
    let target = min(max(0, destination - removedBefore), ids.count)
    ids.insert(contentsOf: moving, at: target)
    reorder(orderedIDs: ids)
  }

  /// Sidebar drag-reorder when only a subset of smart lists are currently
  /// visible (others are hidden or empty `whenNonEmpty` lists). Moves `movedID`
  /// to `toVisibleIndex` among `visibleIDs` while keeping hidden/empty lists in
  /// their relative positions.
  func reorderVisible(visibleIDs: [String], movedID: String, toVisibleIndex: Int) {
    guard let fromVisible = visibleIDs.firstIndex(of: movedID) else { return }
    var remainingVisible = visibleIDs
    remainingVisible.remove(at: fromVisible)
    let adjustedVisibleTarget = toVisibleIndex > fromVisible ? toVisibleIndex - 1 : toVisibleIndex
    let clampedTarget = min(max(0, adjustedVisibleTarget), remainingVisible.count)

    var full = orderedDestinations.map(\.id)
    full.removeAll { $0 == movedID }

    let insertIndex: Int
    if clampedTarget < remainingVisible.count,
       let anchorIndex = full.firstIndex(of: remainingVisible[clampedTarget]) {
      insertIndex = anchorIndex
    } else if let lastVisible = remainingVisible.last,
              let lastIndex = full.firstIndex(of: lastVisible) {
      insertIndex = lastIndex + 1
    } else {
      insertIndex = full.count
    }

    full.insert(movedID, at: min(max(0, insertIndex), full.count))
    reorder(orderedIDs: full)
  }

  func resetToDefaults() {
    applyLocal(order: [], hidden: [])
  }

  // MARK: - Sync

  /// Adopts synced smart-list preferences from `AppSettings` (pulled from the
  /// backend on launch or live sync). Does not re-push.
  func adoptSynced(_ settings: AppSettings) {
    isAdoptingSynced = true
    defer { isAdoptingSynced = false }
    var changed = false
    if let remoteOrder = settings.smartListOrder {
      let clean = Self.sanitizeOrder(remoteOrder)
      if clean != order {
        order = clean
        UserDefaults.standard.set(clean, forKey: RegistrySettings.StorageKey.smartListOrder)
        changed = true
      }
    }
    if let remoteHidden = settings.smartListHidden {
      let clean = Self.sanitizeHidden(remoteHidden)
      if clean != hidden {
        hidden = clean
        UserDefaults.standard.set(clean, forKey: RegistrySettings.StorageKey.smartListHidden)
        changed = true
      }
    }
    if changed { notifyChanged() }
  }

  private func applyLocal(order newOrder: [String], hidden newHidden: [String]) {
    guard newOrder != order || newHidden != hidden else { return }
    order = newOrder
    hidden = newHidden
    let ud = UserDefaults.standard
    ud.set(newOrder, forKey: RegistrySettings.StorageKey.smartListOrder)
    ud.set(newHidden, forKey: RegistrySettings.StorageKey.smartListHidden)
    pushSynced()
    notifyChanged()
  }

  private func pushSynced() {
    guard !isAdoptingSynced else { return }
    let context = LocalStore.shared.container.mainContext
    #if SEPTASK
    var s = SettingsMirror.loadSettings(context: context) ?? SeptaskSyncedSettings.empty
    s.smartListOrder = order
    s.smartListHidden = hidden
    SettingsMirror.upsert(settings: s, context: context, engine: nil)
    #else
    var s = SettingsMirror.loadSettings(context: context)
      ?? AppSettings(sectionOrder: nil, targets: nil, units: nil, time: nil,
                     theme: nil, eink: nil, nutrition: nil, hkSync: nil)
    s.smartListOrder = order
    s.smartListHidden = hidden
    SettingsMirror.upsert(settings: s, context: context, engine: SeptenaServices.shared.ckEngine)
    #endif
  }

  private func notifyChanged() {
    revision &+= 1
    NotificationCenter.default.post(name: .septenaSmartListsChanged, object: nil)
  }

  // MARK: - Sanitization

  private static func sanitizeOrder(_ raw: [String]) -> [String] {
    let known = Self.sidebarById
    var out: [String] = []
    var seen = Set<String>()
    for id in raw where known[id] != nil && seen.insert(id).inserted {
      out.append(id)
    }
    return out
  }

  private static func sanitizeHidden(_ raw: [String]) -> [String] {
    let known = RegistryDestinations.byId
    var out: [String] = []
    var seen = Set<String>()
    for id in raw {
      guard let dest = known[id], dest.canHide, seen.insert(id).inserted else { continue }
      out.append(id)
    }
    return out
  }
}
