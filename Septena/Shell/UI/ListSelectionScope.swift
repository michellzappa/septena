import Foundation

/// Ordered action targets for a list whose selection is stored as a `Set`.
/// Keeps keyboard/render order when resolving bulk operations.
struct ListSelectionScope<ID: Hashable> {
  let selection: Set<ID>
  let orderedIDs: [ID]

  var actionIDs: [ID] {
    selection.isEmpty ? [] : orderedIDs.filter { selection.contains($0) }
  }

  var singleID: ID? { actionIDs.count == 1 ? actionIDs.first : nil }

  var isMulti: Bool { actionIDs.count > 1 }

  var count: Int { actionIDs.count }
}

/// What a context menu or shortcut should operate on — one row or many.
enum SelectionActionTarget<Item> {
  case single(Item)
  case bulk([Item])

  var items: [Item] {
    switch self {
    case .single(let item): return [item]
    case .bulk(let items): return items
    }
  }

  var isSingle: Bool {
    if case .single = self { return true }
    return false
  }

  var isBulk: Bool { !isSingle }

  var count: Int { items.count }

  /// Standard resolution: if the interacted id is part of a multi-selection,
  /// act on the whole ordered selection; otherwise act on that one item.
  static func resolve<ID: Hashable>(
    interactedID: ID,
    scope: ListSelectionScope<ID>,
    item: (ID) -> Item?
  ) -> SelectionActionTarget<Item>? {
    if scope.selection.contains(interactedID), scope.isMulti {
      let bulk = scope.actionIDs.compactMap(item)
      return bulk.isEmpty ? nil : .bulk(bulk)
    }
    guard let one = item(interactedID) else { return nil }
    return .single(one)
  }
}
