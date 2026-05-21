import SwiftUI

// Tiny cross-platform shims so view files can call the same modifiers on
// both iOS and macOS. UIKit-only nav-bar modifiers are no-ops on Mac.

extension View {
  @ViewBuilder
  func septenaInlineTitle() -> some View {
    #if os(iOS)
    self.toolbarTitleDisplayMode(.inline)
    #else
    self
    #endif
  }

  @ViewBuilder
  func septenaHideNavBar() -> some View {
    #if os(iOS)
    self.toolbar(.hidden, for: .navigationBar)
    #else
    self
    #endif
  }

  /// Always-visible search bar. On iOS 26 the system places `.searchable`
  /// in the new bottom field by default, which is what we want — `.automatic`
  /// lets the platform pick. macOS slots it into the toolbar.
  @ViewBuilder
  func septenaAlwaysVisibleSearch(text: Binding<String>) -> some View {
    self.searchable(text: text)
  }

  /// URL-style text field tweaks (no autocap, URL keyboard, URL content type).
  /// No-op on macOS where the AppKit text field already handles this sensibly.
  @ViewBuilder
  func septenaURLField() -> some View {
    #if os(iOS)
    self.autocapitalization(.none)
      .keyboardType(.URL)
      .textContentType(.URL)
    #else
    self
    #endif
  }

  /// macOS-only Esc-to-cancel hook. `.onExitCommand` is the AppKit-correct
  /// way to catch Esc inside a TextField (`onKeyPress(.escape)` doesn't
  /// fire because AppKit consumes Esc as the cancel responder).
  @ViewBuilder
  func septenaOnEscape(_ action: @escaping () -> Void) -> some View {
    #if os(macOS)
    self.onExitCommand(perform: action)
    #else
    self
    #endif
  }

  /// Run `action` when the user secondary-clicks (right-click / two-finger
  /// click) on this view. macOS only — iOS surfaces the context menu via
  /// long-press. The catcher sits as an overlay so it sees the right-click
  /// before SwiftUI's `.contextMenu` consumes it; hit-testing is selective
  /// so left-clicks, drags, hover all still reach SwiftUI underneath.
  @ViewBuilder
  func septenaOnRightClick(_ action: @escaping () -> Void) -> some View {
    #if os(macOS)
    self.overlay(RightClickCatcher(action: action).allowsHitTesting(true))
    #else
    self
    #endif
  }
}

#if os(macOS)
import AppKit

/// Transparent AppKit view that fires `action` on right-mouse-down then
/// forwards to the next responder so SwiftUI's `.contextMenu` still opens.
/// `hitTest(_:)` returns self only for secondary-click events; all other
/// events pass through to the SwiftUI content beneath.
struct RightClickCatcher: NSViewRepresentable {
  let action: () -> Void

  func makeNSView(context: Context) -> NSView { Catcher(action: action) }
  func updateNSView(_ nsView: NSView, context: Context) {
    (nsView as? Catcher)?.action = action
  }

  final class Catcher: NSView {
    var action: () -> Void
    init(action: @escaping () -> Void) {
      self.action = action
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Only claim the hit for secondary-click events. Everything else
    /// (primary click, hover, drag) falls through to SwiftUI.
    override func hitTest(_ point: NSPoint) -> NSView? {
      guard super.hitTest(point) != nil else { return nil }
      guard let event = NSApp.currentEvent else { return nil }
      switch event.type {
      case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
        return self
      default:
        return nil
      }
    }

    override func rightMouseDown(with event: NSEvent) {
      action()
      // Forward up the responder chain so SwiftUI's contextMenu still
      // opens — without this, returning self in hitTest would swallow it.
      nextResponder?.rightMouseDown(with: event)
    }
  }
}
#endif

/// Click-to-edit title: renders as `Text` until tapped, then becomes a
/// `TextField` focused for editing. Commit on Enter / blur, cancel on Esc.
struct ClickToEditTitle: View {
  let placeholder: String
  @Binding var text: String
  /// Called once the user finishes editing with a non-empty title. Receives
  /// the trimmed new value (use it to detect "did it actually change").
  var onCommit: (String) -> Void
  /// Font + foreground style applied to both the Text view and the field.
  var font: Font = .septenaScreenTitle
  var foreground: Color = Theme.inkPrimary

  @State private var isEditing = false
  @State private var snapshot: String = ""
  @FocusState private var focused: Bool

  var body: some View {
    Group {
      if isEditing {
        TextField(placeholder, text: $text)
          .textFieldStyle(.plain)
          .focusEffectDisabled()
          .focused($focused)
          .font(font)
          .foregroundStyle(foreground)
          .submitLabel(.done)
          .onSubmit { finish(commit: true) }
          .onChange(of: focused) { _, isFocused in
            if !isFocused { finish(commit: true) }
          }
          .onAppear { focused = true }
          .septenaOnEscape { finish(commit: false) }
          .onKeyPress(.escape) { finish(commit: false); return .handled }
      } else {
        Text(text.isEmpty ? placeholder : text)
          .font(font)
          .foregroundStyle(text.isEmpty ? Theme.inkSecondary : foreground)
          .contentShape(Rectangle())
          .onTapGesture { startEditing() }
      }
    }
  }

  private func startEditing() {
    snapshot = text
    isEditing = true
  }

  private func finish(commit: Bool) {
    if commit {
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        text = snapshot
      } else if trimmed != snapshot {
        onCommit(trimmed)
      }
    } else {
      text = snapshot
    }
    isEditing = false
  }
}

extension View {
  /// Apply the Septena sheet chrome — thin-material glass background plus a
  /// large continuous corner radius so modals match the iOS 26 Liquid Glass
  /// aesthetic. Detents must still be set per-sheet.
  func septenaSheetChrome() -> some View {
    self
      .presentationBackground(.thinMaterial)
      .presentationCornerRadius(Theme.cornerRadius)
  }
}

/// Zero-effect button style. Suppresses the brief label tint that SwiftUI's
/// default `.plain` style applies on click — useful when a row already shows
/// "I was tapped" via a persistent background pill, so the extra flash adds
/// nothing but visual noise.
struct InertButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
  }
}

/// Inline edit/new-task card chrome. Both platforms render a white card
/// floating above the off-white page; macOS adds a margin so the card reads
/// as its own object (compact), iOS keeps it full-bleed for a list feel.
struct InlineCardChrome: ViewModifier {
  func body(content: Content) -> some View {
    #if os(macOS)
    // No outer padding — the card occupies the same x/y rectangle as the
    // closed row it's replacing, so the title doesn't shift right or down
    // when entering edit mode. Rounded corners + shadow stay so it still
    // reads as a card lifted off the list.
    content
      .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
      .shadow(color: .black.opacity(0.07), radius: 5, x: 0, y: 1)
    #else
    // iOS: clip to rounded rect so the card reads as a contained
    // surface, not a full-bleed rectangle, and the shadow has shape.
    content
      .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
      .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 0)
    #endif
  }
}
