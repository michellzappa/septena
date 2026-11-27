import Foundation
import Observation
import SeptenaSharedCore

// Sort By on lists (docs/LIST_SORT_SPEC.md, #779).
//
// A sort is a view setting per list. It never writes a task position, so
// Manual shows the user's own order again. The comparison lives once, in the
// shared core (`sort.rs`, `sortTasks`); this file holds the list keys, the one
// seam to the core and the synced choice per list. Never compare tasks here.

extension Notification.Name {
  /// Posted when the user or an inbound sync changes the sort of any list.
  /// Both shells reload the list on screen.
  static let septenaListSortChanged = Notification.Name("septena.listSortChanged")
}

enum ListSort {
  /// The stored manual order. The default, and the absence of a key.
  static let manual = "manual"

  /// The five choices with their localized titles, in registry order
  /// (`registry/settings.json` `listSort`, values `RegistryEntityEnums.listSort`).
  static let options: [RegistrySettingsOption] = {
    // The settings key, which shares its name with the `listSort` surface.
    let titled = RegistrySettings.optionsByKey["listSort"] ?? [] // septena-lint:allow registry-id-literal
    return RegistryEntityEnums.listSort.map { value in
      titled.first { $0.value == value } ?? RegistrySettingsOption(value: value, title: value)
    }
  }()

  static func isValid(_ sort: String) -> Bool { RegistryEntityEnums.listSort.contains(sort) }

  /// The localized label of a choice ("When", "Title", …).
  static func title(_ sort: String) -> String {
    options.first { $0.value == sort }?.title ?? sort
  }

  /// The header line of a sorted list ("Sorted by When"), nil for Manual.
  static func indicator(_ sort: String) -> String? {
    sort == manual ? nil : RegistrySurfaces.listSortSortedBy(sort: title(sort))
  }

  // MARK: - List keys (spec §5)

  /// The storage key of a list that takes a sort, nil for one that does not.
  /// A smart list takes one when its registry row says `supportsManualOrder`;
  /// every project page and every area page takes one.
  static func key(for filter: TaskFilter) -> String? {
    switch filter {
    case .project(let id): return "project:\(id)"
    case .area(let id): return "area:\(id)"
    default:
      guard let dest = filter.registryDestination, dest.supportsManualOrder else { return nil }
      return dest.id.rawValue
    }
  }

  // MARK: - Ordering

  /// The rows a sort may move on `filter`'s list: open tasks only, never a
  /// heading. On Today the Inbox rows (unfiled) keep their place: the Inbox
  /// band keeps its own order (spec §1). The one rule for both shells and
  /// the Today launch snapshot, so the first frame matches the live list.
  static func isSortable(_ task: SeptenaTask, in filter: TaskFilter) -> Bool {
    task.status == .open && !task.isHeading && !(filter == .today && task.isUnfiled)
  }

  /// `rows` of `filter`'s list in `sort` (see the other `ordered`).
  static func ordered(_ rows: [SeptenaTask], in filter: TaskFilter, sort: String,
                      pinned: Set<String> = [],
                      onScreen: [String] = []) -> [SeptenaTask] {
    ordered(rows, sort: sort, isSortable: { isSortable($0, in: filter) },
            pinned: pinned, onScreen: onScreen)
  }

  /// `rows` in the order the list shows under `sort`.
  ///
  /// Only rows `isSortable` accepts move, and only into the slots sortable
  /// rows held, so everything else (headings, completed rows, Today's Inbox
  /// rows) keeps its place. A grouped list forms its groups from the result
  /// in order, so each group comes out sorted: the core's sort is stable with
  /// manual order as the tie-break, and a subset of a sorted run is sorted.
  ///
  /// `pinned` rows (an open inline editor or a new draft) do not move while
  /// the edit lasts: each goes back after the row it followed on screen
  /// (`onScreen`), or after the row it follows in manual order when it is new.
  ///
  /// Fails safe: Manual, a core that lacks `sortTasks` or returns anything
  /// unexpected gives `rows` back unchanged.
  static func ordered(_ rows: [SeptenaTask], sort: String,
                      isSortable: (SeptenaTask) -> Bool,
                      pinned: Set<String> = [],
                      onScreen: [String] = []) -> [SeptenaTask] {
    guard sort != manual, isValid(sort) else { return rows }
    // Only a sortable row can be pinned: any other row keeps its slot anyway.
    let pinned = pinned.intersection(rows.filter(isSortable).map(\.id))
    let slots = rows.indices.filter { isSortable(rows[$0]) && !pinned.contains(rows[$0].id) }
    guard slots.count > 1 || !pinned.isEmpty else { return rows }
    let sortable = slots.map { rows[$0] }
    guard let ids = sortedIDs(sortable, sort: sort) else { return rows }
    let byID = Dictionary(sortable.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let sorted = ids.compactMap { byID[$0] }
    // The core returns a permutation of the input. Anything else: manual.
    guard sorted.count == sortable.count, Set(ids).count == ids.count else { return rows }
    var result = rows
    for (slot, task) in zip(slots, sorted) { result[slot] = task }
    return pinnedBack(result, manual: rows, pinned: pinned, onScreen: onScreen)
  }

  /// Puts each pinned row after its anchor: the row it followed on screen,
  /// or, for a row not on screen yet, the row it follows in manual order.
  private static func pinnedBack(_ sorted: [SeptenaTask], manual: [SeptenaTask],
                                 pinned: Set<String>, onScreen: [String]) -> [SeptenaTask] {
    let pins = manual.filter { pinned.contains($0.id) }
    guard !pins.isEmpty else { return sorted }
    var result = sorted.filter { !pinned.contains($0.id) }
    for pin in pins {
      let trail: [String]
      if let at = onScreen.firstIndex(of: pin.id) {
        trail = Array(onScreen[..<at].reversed())
      } else if let at = manual.firstIndex(where: { $0.id == pin.id }) {
        trail = manual[..<at].reversed().map(\.id)
      } else {
        trail = []
      }
      var insertAt = 0
      for id in trail {
        if let anchor = result.firstIndex(where: { $0.id == id }) {
          insertAt = anchor + 1
          break
        }
      }
      result.insert(pin, at: insertAt)
    }
    return result
  }

  /// One call to the shared core: the ids in sorted order, nil on any error.
  private static func sortedIDs(_ tasks: [SeptenaTask], sort: String) -> [String]? {
    let input = Input(tasks: tasks.map(Snapshot.init), sort: sort)
    guard let data = try? JSONEncoder().encode(input),
          let json = String(data: data, encoding: .utf8) else { return nil }
    do {
      let out = try invokeJson(function: "sortTasks", inputJson: json)
      return try JSONDecoder().decode([String].self, from: Data(out.utf8))
    } catch {
      SeptenaLog.error("[ListSort] sortTasks failed", error)
      return nil
    }
  }

  private struct Input: Encodable {
    let tasks: [Snapshot]
    let sort: String
  }

  /// The `TaskSnapshot` fields the sort reads (`views.rs`, camelCase; the
  /// core defaults every field left out). The same values
  /// `TaskListRules.snapshot` passes.
  private struct Snapshot: Encodable {
    let id: String
    let title: String
    let status: String
    let kind: String?
    let created: String?
    let createdAt: String?
    let scheduled: String?
    let deadline: String?

    init(_ task: SeptenaTask) {
      id = task.id
      title = task.title
      status = task.status.rawValue
      kind = task.kind.isEmpty ? nil : task.kind
      created = task.created
      createdAt = task.createdAt == .distantPast ? nil : SharedCoreValues.instant(task.createdAt)
      scheduled = task.scheduled
      deadline = task.deadline
    }
  }
}

// MARK: - The choice per list

/// The synced `listSort` record (`registry/settings.json`): list key → a
/// `listSort` value other than Manual. Stored and synced the way
/// `SmartListPreferences` stores `smartListPlacement`: a local UserDefaults
/// mirror, adopted from a pull, pushed through `SettingsMirror`.
@MainActor
@Observable
final class ListSortPreferences {
  static let shared = ListSortPreferences()

  /// The record's limit (`maxEntries`).
  static let maxEntries = 256

  private(set) var sorts: [String: String]

  /// Bumped on every change, so a view that reads `shared` invalidates.
  private(set) var revision: UInt = 0

  private var isAdoptingSynced = false
  private var syncObserver: NSObjectProtocol?

  private init() {
    let saved = UserDefaults.standard.dictionary(forKey: RegistrySettings.StorageKey.listSort) as? [String: String] ?? [:]
    sorts = Self.sanitize(saved)
    syncObserver = NotificationCenter.default.addObserver(
      forName: .septaskSettingsPulled, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.adoptSynced(SeptaskSyncedSettings.current())
      }
    }
  }

  /// The sort of `filter`'s list. Manual for a list that takes no sort.
  func sort(for filter: TaskFilter) -> String {
    guard let key = ListSort.key(for: filter) else { return ListSort.manual }
    return sort(forKey: key)
  }

  func sort(forKey key: String) -> String {
    _ = revision
    return sorts[key] ?? ListSort.manual
  }

  /// Picking Manual removes the key. A view change: never on the undo stack.
  func setSort(_ sort: String, for filter: TaskFilter) {
    guard let key = ListSort.key(for: filter), ListSort.isValid(sort) else { return }
    var next = sorts
    if sort == ListSort.manual {
      next.removeValue(forKey: key)
    } else {
      next[key] = sort
    }
    applyLocal(Self.pruned(next, keeping: key))
  }

  /// Resets the local mirror without a push, on an account switch or delete.
  func clearLocalForAccountSwitch() {
    isAdoptingSynced = true
    defer { isAdoptingSynced = false }
    UserDefaults.standard.removeObject(forKey: RegistrySettings.StorageKey.listSort)
    guard !sorts.isEmpty else { return }
    sorts = [:]
    notifyChanged()
  }

  /// Adopts the record from a pull. Does not push again.
  func adoptSynced(_ settings: AppSettings) {
    guard let remote = settings.listSort else { return }
    isAdoptingSynced = true
    defer { isAdoptingSynced = false }
    let clean = Self.sanitize(remote)
    guard clean != sorts else { return }
    sorts = clean
    UserDefaults.standard.set(clean, forKey: RegistrySettings.StorageKey.listSort)
    notifyChanged()
  }

  private func applyLocal(_ next: [String: String]) {
    guard next != sorts else { return }
    sorts = next
    UserDefaults.standard.set(next, forKey: RegistrySettings.StorageKey.listSort)
    pushSynced()
    notifyChanged()
  }

  private func pushSynced() {
    guard !isAdoptingSynced else { return }
    let context = LocalStore.shared.container.mainContext
    var s = SettingsMirror.loadSettings(context: context) ?? SeptaskSyncedSettings.empty
    s.listSort = sorts
    SettingsMirror.upsert(settings: s, context: context, engine: nil)
  }

  private func notifyChanged() {
    revision &+= 1
    ListSortFocus.bump()
    NotificationCenter.default.post(name: .septenaListSortChanged, object: nil)
  }

  /// Valid keys and values only; Manual is never stored.
  private static func sanitize(_ raw: [String: String]) -> [String: String] {
    raw.filter { key, value in
      !key.isEmpty && key.count <= 64 && value != ListSort.manual && ListSort.isValid(value)
    }
  }

  /// On write (spec §5): drop keys of projects and areas that no longer
  /// exist, then keep at most `maxEntries`. An empty structure read may be a
  /// failed read, so it prunes nothing (fail closed: keep the user's sorts).
  private static func pruned(_ raw: [String: String], keeping key: String) -> [String: String] {
    var out = sanitize(raw)
    let structure = StructureCache.snapshot(in: LocalStore.shared.container.mainContext)
    if !structure.areas.isEmpty || !structure.projects.isEmpty {
      let projectIDs = Set(structure.projects.map(\.id))
      let areaIDs = Set(structure.areas.map(\.id))
      out = out.filter { k, _ in
        if k.hasPrefix("project:") { return projectIDs.contains(String(k.dropFirst(8))) }
        if k.hasPrefix("area:") { return areaIDs.contains(String(k.dropFirst(5))) }
        return true
      }
    }
    if out.count > maxEntries {
      // Keep the list the user just set; drop the others in key order.
      let extra = out.keys.filter { $0 != key }.sorted().prefix(out.count - maxEntries)
      for k in extra { out.removeValue(forKey: k) }
    }
    return out
  }
}

/// The list in front, for the View ▸ Sort By menu: the shell that shows a
/// list sets it. The menu bar re-reads it through `revisionKey`, because a
/// `Commands` body re-evaluates on `@AppStorage`, not on a plain read.
@MainActor
enum ListSortFocus {
  /// Device-local, not a setting: only bumped to wake the menu bar.
  nonisolated static let revisionKey = "septena.lists.sortMenuRevision"

  static var filter: TaskFilter? {
    didSet {
      guard oldValue != filter else { return }
      bump()
    }
  }

  static func bump() {
    let ud = UserDefaults.standard
    ud.set(ud.integer(forKey: revisionKey) &+ 1, forKey: revisionKey)
  }
}
