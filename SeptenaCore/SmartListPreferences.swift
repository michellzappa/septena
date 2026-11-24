import Foundation
import Observation

// Per-account customization for the "special" smart lists in the sidebar
// (`registry/destinations.json`).
//
// Registry-based and synced across all devices via `smartListOrder`,
// `smartListHidden`, and `smartListPlacement` in `registry/settings.json`:
//   • Two special zones frame user Areas & Projects: `.top` (working lists)
//     above and `.bottom` (archive / utility lists) below. Smart lists never
//     mix into Areas or Projects in the middle.
//   • `todayBand` destinations (`inbox`) draw inside Today and never take part
//     in sidebar ordering, visibility, or placement.
//   • `order` is ORDERING ONLY, never membership — any destination in
//     `Self.sidebarDestinations` absent from `order` is appended in its
//     canonical `sidebarOrder`, and unknown IDs are ignored.
//   • `hidden` lists destination IDs explicitly hidden by the user.
//     Destinations with `canHide == false` (e.g. `today`) are never hidden.
//   • `placement` stores explicit `"top"` / `"bottom"` overrides keyed by
//     destination ID. Unset IDs fall back to `dest.sidebarSection` from the
//     registry; destinations with `canMoveSection == false` stay in their
//     registry section.
//   • Destinations with `visibility == "whenNonEmpty"` (`review`, `agent`,
//     `starred`, `faded`, `recentlyDeleted`) still obey progressive disclosure
//     when not hidden.

enum SmartListSection: String, CaseIterable, Sendable, Identifiable {
  case top
  case bottom

  var id: String { rawValue }
}

extension Notification.Name {
  /// Posted whenever the user or an inbound sync changes smart-list order,
  /// visibility, or top/bottom placement so AppKit and SwiftUI sidebars rebuild live.
  static let septenaSmartListsChanged = Notification.Name("septena.smartListsChanged")
}

@MainActor
@Observable
final class SmartListPreferences {
  static let shared = SmartListPreferences()

  struct Snapshot: Equatable {
    let order: [String]
    let hidden: [String]
    let placement: [String: String]
  }

  /// Sanitized user-defined order of canonical `RegistryDestination.id`s.
  /// Empty means canonical registry `sidebarOrder`.
  private(set) var order: [String]

  /// Sanitized list of hidden `RegistryDestination.id`s.
  private(set) var hidden: [String]

  /// Sanitized per-destination section overrides (`id -> "top" | "bottom"`).
  /// Only entries differing from the registry default are stored.
  private(set) var placement: [String: String]

  /// Monotonically incremented on every change so `@Observable` SwiftUI views
  /// reading `SmartListPreferences.shared` always invalidate.
  private(set) var revision: UInt = 0

  private var isAdoptingSynced = false
  private var syncObserver: NSObjectProtocol?

  private init() {
    let ud = UserDefaults.standard
    let savedOrder = ud.stringArray(forKey: RegistrySettings.StorageKey.smartListOrder) ?? []
    let savedHidden = ud.stringArray(forKey: RegistrySettings.StorageKey.smartListHidden) ?? []
    let savedPlacement = ud.dictionary(forKey: RegistrySettings.StorageKey.smartListPlacement) as? [String: String] ?? [:]
    self.order = Self.sanitizeOrder(savedOrder)
    self.hidden = Self.sanitizeHidden(savedHidden)
    self.placement = Self.sanitizePlacement(savedPlacement)

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
  /// ordering, placement, or show/hide.
  static let sidebarDestinations: [RegistryDestination] =
    RegistryDestinations.all.filter { $0.visibility != "todayBand" && $0.applies(to: RegistryPlatform.current) }
  static let sidebarById: [String: RegistryDestination] =
    Dictionary(uniqueKeysWithValues: sidebarDestinations.map { ($0.id, $0) })

  /// All canonical sidebar smart-list destinations from `registry/destinations.json`,
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

  /// Resolved sidebar section (`.top` above Areas & Projects, `.bottom` below).
  func section(for destinationID: String) -> SmartListSection {
    _ = revision
    guard let dest = Self.sidebarById[destinationID] else { return .top }
    let defaultSection = SmartListSection(rawValue: dest.sidebarSection) ?? .top
    guard dest.canMoveSection else { return defaultSection }
    if let override = placement[destinationID], let sec = SmartListSection(rawValue: override) {
      return sec
    }
    return defaultSection
  }

  /// All registry sidebar destinations currently assigned to `section`, in user order.
  func orderedDestinations(in targetSection: SmartListSection) -> [RegistryDestination] {
    orderedDestinations.filter { section(for: $0.id) == targetSection }
  }

  /// True when the destination is hidden by the user. Destinations marked
  /// `canHide == false` in `registry/destinations.json` are never hidden.
  func isHidden(_ destinationID: String) -> Bool {
    _ = revision
    guard let dest = Self.sidebarById[destinationID], dest.canHide else {
      return false
    }
    return hidden.contains(destinationID)
  }

  /// All visible special smart-list destinations in display order, honoring
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

  /// Visible special smart-list destinations in a specific zone (`.top` or `.bottom`).
  func visibleDestinations(in targetSection: SmartListSection,
                           nonEmptyIDs: Set<String>) -> [RegistryDestination] {
    visibleDestinations(nonEmptyIDs: nonEmptyIDs).filter { section(for: $0.id) == targetSection }
  }

  /// Every list the user has enabled, in sidebar order (top zone, then
  /// bottom), whether or not a `whenNonEmpty` list has rows now.
  var enabledDestinations: [RegistryDestination] {
    (orderedDestinations(in: .top) + orderedDestinations(in: .bottom))
      .filter { !isHidden($0.id) }
  }

  /// Digit shortcut per destination ID (⌘1, ⌘2, …): counts the enabled lists
  /// down the sidebar. `whenNonEmpty` lists take no digit. They come and go
  /// with their rows, and would renumber the lists below them.
  var digitShortcuts: [String: RegistryShortcut] {
    let numbered = enabledDestinations
      .filter { $0.visibility == RegistryDestinations.digitShortcutVisibility }
    return Dictionary(uniqueKeysWithValues:
      zip(numbered.map(\.id), RegistryDestinations.digitShortcuts))
  }

  /// True when visibility, placement, or order differs from the canonical
  /// registry defaults.
  var isCustomized: Bool {
    _ = revision
    if !hidden.isEmpty || !placement.isEmpty { return true }
    return orderedDestinations.map(\.id) != Self.sidebarDestinations.map(\.id)
  }

  // MARK: - Mutations (persisted locally + synced per account)

  func snapshot() -> Snapshot {
    Snapshot(order: order, hidden: hidden, placement: placement)
  }

  func restore(_ snap: Snapshot) {
    applyLocal(order: Self.sanitizeOrder(snap.order),
               hidden: Self.sanitizeHidden(snap.hidden),
               placement: Self.sanitizePlacement(snap.placement))
  }

  func setHidden(_ shouldHide: Bool, for destinationID: String) {
    guard let dest = Self.sidebarById[destinationID], dest.canHide else { return }
    var next = hidden
    if shouldHide {
      if !next.contains(destinationID) { next.append(destinationID) }
    } else {
      next.removeAll { $0 == destinationID }
    }
    applyLocal(order: order, hidden: Self.sanitizeHidden(next), placement: placement)
  }

  func setSection(_ targetSection: SmartListSection, for destinationID: String) {
    guard let dest = Self.sidebarById[destinationID], dest.canMoveSection else { return }
    var next = placement
    if targetSection.rawValue == dest.sidebarSection {
      next.removeValue(forKey: destinationID)
    } else {
      next[destinationID] = targetSection.rawValue
    }
    applyLocal(order: order, hidden: hidden, placement: Self.sanitizePlacement(next))
  }

  func reorder(orderedIDs: [String]) {
    var full = Self.sanitizeOrder(orderedIDs)
    let seen = Set(full)
    for dest in Self.sidebarDestinations where !seen.contains(dest.id) {
      full.append(dest.id)
    }
    applyLocal(order: full, hidden: hidden, placement: placement)
  }

  /// SwiftUI `.onMove` helper for reordering within one section in Settings.
  func moveInSection(_ targetSection: SmartListSection,
                     fromOffsets source: IndexSet,
                     toOffset destination: Int) {
    var sectionIDs = orderedDestinations(in: targetSection).map(\.id)
    let moving = source.sorted().map { sectionIDs[$0] }
    for index in source.sorted(by: >) {
      sectionIDs.remove(at: index)
    }
    let removedBefore = source.filter { $0 < destination }.count
    let target = min(max(0, destination - removedBefore), sectionIDs.count)
    sectionIDs.insert(contentsOf: moving, at: target)

    // Splice the reordered section back into the global order while keeping
    // the other section's items untouched in their slots.
    var iter = sectionIDs.makeIterator()
    let rebuilt = orderedDestinations.map { dest -> String in
      if section(for: dest.id) == targetSection, let next = iter.next() {
        return next
      }
      return dest.id
    }
    reorder(orderedIDs: rebuilt)
  }

  /// Sidebar drag-reorder supporting both intra-section reordering and moving
  /// a smart list across Areas & Projects between `.top` and `.bottom`.
  /// Preserves relative positions of hidden or empty `whenNonEmpty` lists.
  func reorderVisible(movedID: String,
                      toSection targetSection: SmartListSection,
                      targetVisibleIDs: [String],
                      toVisibleIndex: Int) {
    guard let dest = Self.sidebarById[movedID] else { return }
    let currentSection = section(for: movedID)
    let resolvedSection = dest.canMoveSection ? targetSection : currentSection

    var nextPlacement = placement
    if resolvedSection != currentSection {
      if resolvedSection.rawValue == dest.sidebarSection {
        nextPlacement.removeValue(forKey: movedID)
      } else {
        nextPlacement[movedID] = resolvedSection.rawValue
      }
    }

    var remainingTargetVisible = targetVisibleIDs
    let adjustedVisibleTarget: Int
    if let fromVisible = remainingTargetVisible.firstIndex(of: movedID) {
      remainingTargetVisible.remove(at: fromVisible)
      adjustedVisibleTarget = toVisibleIndex > fromVisible ? toVisibleIndex - 1 : toVisibleIndex
    } else {
      adjustedVisibleTarget = toVisibleIndex
    }
    let clampedTarget = min(max(0, adjustedVisibleTarget), remainingTargetVisible.count)

    var full = orderedDestinations.map(\.id)
    full.removeAll { $0 == movedID }

    let insertIndex: Int
    if clampedTarget < remainingTargetVisible.count,
       let anchorIndex = full.firstIndex(of: remainingTargetVisible[clampedTarget]) {
      insertIndex = anchorIndex
    } else if let lastVisible = remainingTargetVisible.last,
              let lastIndex = full.firstIndex(of: lastVisible) {
      insertIndex = lastIndex + 1
    } else {
      insertIndex = full.count
    }

    full.insert(movedID, at: min(max(0, insertIndex), full.count))
    applyLocal(order: Self.sanitizeOrder(full),
               hidden: hidden,
               placement: Self.sanitizePlacement(nextPlacement))
  }

  func resetToDefaults() {
    applyLocal(order: [], hidden: [], placement: [:])
  }

  /// Resets in-memory and UserDefaults mirrors without pushing to sync. Called
  /// when switching accounts or deleting the account so the previous account's
  /// smart-list layout never leaks into the next sign-in.
  func clearLocalForAccountSwitch() {
    isAdoptingSynced = true
    defer { isAdoptingSynced = false }
    let ud = UserDefaults.standard
    ud.removeObject(forKey: RegistrySettings.StorageKey.smartListOrder)
    ud.removeObject(forKey: RegistrySettings.StorageKey.smartListHidden)
    ud.removeObject(forKey: RegistrySettings.StorageKey.smartListPlacement)
    let hadState = !order.isEmpty || !hidden.isEmpty || !placement.isEmpty
    order = []
    hidden = []
    placement = [:]
    if hadState { notifyChanged() }
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
    if let remotePlacement = settings.smartListPlacement {
      let clean = Self.sanitizePlacement(remotePlacement)
      if clean != placement {
        placement = clean
        UserDefaults.standard.set(clean, forKey: RegistrySettings.StorageKey.smartListPlacement)
        changed = true
      }
    }
    if changed { notifyChanged() }
  }

  private func applyLocal(order newOrder: [String],
                          hidden newHidden: [String],
                          placement newPlacement: [String: String]) {
    guard newOrder != order || newHidden != hidden || newPlacement != placement else { return }
    order = newOrder
    hidden = newHidden
    placement = newPlacement
    let ud = UserDefaults.standard
    ud.set(newOrder, forKey: RegistrySettings.StorageKey.smartListOrder)
    ud.set(newHidden, forKey: RegistrySettings.StorageKey.smartListHidden)
    ud.set(newPlacement, forKey: RegistrySettings.StorageKey.smartListPlacement)
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
    s.smartListPlacement = placement
    SettingsMirror.upsert(settings: s, context: context, engine: nil)
    #else
    var s = SettingsMirror.loadSettings(context: context)
      ?? AppSettings(sectionOrder: nil, targets: nil, units: nil, time: nil,
                     theme: nil, eink: nil, nutrition: nil, hkSync: nil)
    s.smartListOrder = order
    s.smartListHidden = hidden
    s.smartListPlacement = placement
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
    let known = Self.sidebarById
    var out: [String] = []
    var seen = Set<String>()
    for id in raw {
      guard let dest = known[id], dest.canHide, seen.insert(id).inserted else { continue }
      out.append(id)
    }
    return out
  }

  private static func sanitizePlacement(_ raw: [String: String]) -> [String: String] {
    let known = Self.sidebarById
    var out: [String: String] = [:]
    for (id, sec) in raw {
      guard let dest = known[id], dest.canMoveSection,
            sec == SmartListSection.top.rawValue || sec == SmartListSection.bottom.rawValue,
            sec != dest.sidebarSection
      else { continue }
      out[id] = sec
    }
    return out
  }
}
