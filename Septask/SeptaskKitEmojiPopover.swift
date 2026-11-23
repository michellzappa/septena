#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Area emoji popover

/// The area glyph picker in the Mac shell: the same `EmojiPickerContent` the
/// SwiftUI area page shows (curated grid, free-form field, Clear, "More…" to
/// the Character Viewer), hosted in the shell's `KitPopover`. Each pick saves
/// through `AreasMutator.setEmoji`, the write the SwiftUI page uses.
@MainActor
enum KitEmojiPopover {
  static func present(for area: Area, relativeTo rect: NSRect, of view: NSView,
                      preferredEdge: NSRectEdge = .maxY) {
    let handle = KitPopoverHandle()
    let model = Model(emoji: area.emoji ?? "")
    let content = EmojiPickerContent(
      emoji: Binding(get: { model.emoji }, set: { model.emoji = $0 }),
      onSelect: { value in model.save(value, areaID: area.id) },
      onDismiss: { handle.close() })
    let host = NSHostingView(rootView: content)
    KitPopover.present(host, size: NSSize(width: 320, height: 380),
                       relativeTo: rect, of: view,
                       preferredEdge: preferredEdge, handle: handle)
  }

  /// Holds the draft glyph and the last saved value, so a repeat of the same
  /// glyph (the free-form field re-commits on every change) writes once.
  private final class Model {
    var emoji: String
    private var saved: String

    init(emoji: String) {
      self.emoji = emoji
      self.saved = emoji
    }

    func save(_ value: String, areaID: String) {
      guard value != saved else { return }
      saved = value
      Task { @MainActor in
        do {
          try await SeptenaServices.shared.areasMutator.setEmoji(id: areaID,
                                                                 emoji: value.isEmpty ? nil : value)
        } catch {
          SeptenaLog.error("[emoji] save failed for area \(areaID)", error)
        }
      }
    }
  }
}
#endif
