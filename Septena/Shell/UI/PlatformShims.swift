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

  /// Run `action` on a primary double-click. macOS only — iOS opens via a
  /// single tap. Like `septenaOnRightClick`, the catcher sits as an overlay
  /// that claims ONLY double-click (`clickCount >= 2`) events; single clicks
  /// fall through to SwiftUI underneath. Use this for rows in plain
  /// VStack/LazyVStack layouts (e.g. the drawer's `DrawerSection`).
  ///
  /// NOT for rows inside a native `List(selection:)`: there NSTableView's
  /// `mouseDown` runs its own event-tracking loop that swallows the second
  /// click before this overlay can re-hit-test it, so the catcher never fires.
  /// In a List, reach for `.onTapGesture(count: 2)` — it sees the double-click
  /// and still lets single clicks drive native selection.
  @ViewBuilder
  func septenaOnDoubleClick(_ action: @escaping () -> Void) -> some View {
    #if os(macOS)
    self.overlay(DoubleClickCatcher(action: action).allowsHitTesting(true))
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

/// Transparent AppKit view that fires `action` on a primary double-click and
/// otherwise gets out of the way. `hitTest(_:)` claims only `leftMouseDown`
/// events whose `clickCount >= 2`, so the first click of the gesture (and
/// every single click) falls through to the SwiftUI `List` beneath and still
/// drives native row selection.
struct DoubleClickCatcher: NSViewRepresentable {
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

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard super.hitTest(point) != nil else { return nil }
      guard let event = NSApp.currentEvent else { return nil }
      switch event.type {
      case .leftMouseDown where event.clickCount >= 2:
        return self
      default:
        return nil
      }
    }

    override func mouseDown(with event: NSEvent) {
      if event.clickCount >= 2 { action() }
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
  /// Shared page geometry for the four top-level surfaces (Week, Next,
  /// Tasks sidebar, Coach). Applied to the root content stack inside the
  /// surface's ScrollView — the single choke point for how a tab meets the
  /// screen edges, so the four can't drift apart:
  ///   • `Theme.pageGutter` leading/trailing,
  ///   • `Theme.pageTop` below the nav bar (pass `top: 0` when the
  ///     surface's sections pad their own tops, e.g. the Next feed),
  ///   • `Theme.pageBottom` scroll-past air above the tab bar.
  /// Backgrounds stay per-surface (the Tasks sidebar differs on macOS).
  func septenaSurface(top: CGFloat = Theme.pageTop) -> some View {
    self
      .padding(.horizontal, Theme.pageGutter)
      .padding(.top, top)
      .padding(.bottom, Theme.pageBottom)
  }

  /// Apply the Septena sheet chrome — thin-material glass background plus a
  /// large continuous corner radius so modals match the iOS 26 Liquid Glass
  /// aesthetic. Detents must still be set per-sheet.
  func septenaSheetChrome() -> some View {
    self
      .presentationBackground(.thinMaterial)
      .presentationCornerRadius(Theme.cornerRadius)
  }

  /// Liquid-glass capsule fill for floating chrome (status badges, pills).
  /// iOS 26 gets a true `.glassEffect`; macOS falls back to thin material so
  /// the same call site reads as glass on both — the gating dance lives here
  /// once instead of at every pill. Pass `tint` to wash the glass with a
  /// section accent (kept faint; the material carries the look), omit for
  /// neutral glass. Single choke point so every floating pill glasses in step.
  @ViewBuilder
  func glassCapsule(tint: Color? = nil) -> some View {
    #if os(iOS)
    if let tint {
      self.glassEffect(.regular.tint(tint.opacity(0.5)).interactive(), in: .capsule)
    } else {
      self.glassEffect(.regular.interactive(), in: .capsule)
    }
    #else
    self.background(.thinMaterial, in: Capsule())
    #endif
  }

  /// Liquid-glass fill for a floating *circular* control (toolbar glyph
  /// buttons). A self-contained glass circle — using this instead of
  /// `.buttonStyle(.glass)` keeps the control from being folded into the
  /// system's shared leading-toolbar glass group (the "bubble in a bubble"),
  /// so each button floats on its own like the prominent "+". macOS falls back
  /// to thin material. Tint optionally washes the glass; omit for neutral.
  @ViewBuilder
  func glassCircle(tint: Color? = nil) -> some View {
    #if os(iOS)
    if let tint {
      self.glassEffect(.regular.tint(tint.opacity(0.5)).interactive(), in: .circle)
    } else {
      self.glassEffect(.regular.interactive(), in: .circle)
    }
    #else
    self.background(.thinMaterial, in: Circle())
    #endif
  }

  /// Liquid-glass fill for a floating *card* surface (dashboard tiles). Same
  /// iOS-glass / macOS-material split as `glassCapsule`, in a continuous
  /// rounded rectangle. macOS keeps the opaque grouped card it always had —
  /// glass over the mac paper canvas reads muddy — so this only glasses iOS
  /// for now. Tint optionally washes the glass with the tile's section accent.
  @ViewBuilder
  func glassCard(cornerRadius: CGFloat = Theme.cornerRadius, tint: Color? = nil) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    #if os(iOS)
    if let tint {
      self.glassEffect(.regular.tint(tint.opacity(0.16)), in: shape)
    } else {
      self.glassEffect(.regular, in: shape)
    }
    #else
    self.background(shape.fill(Theme.secondaryGroupedBackground))
    #endif
  }
}

extension View {
  /// Universal pointer / Apple-Pencil-hover highlight for tappable custom
  /// surfaces (dashboard tiles, cards, log rows). System controls (tab bar,
  /// toolbar, `List` rows) get this for free; `.buttonStyle(.plain)` —
  /// which this app uses on ~all tappable cards — opts *out* of the automatic
  /// pointer effect, so anything tappable-but-plain must request it back.
  ///
  /// Pencil hover rides the same pointer-effect pipeline as the trackpad
  /// pointer, so this one modifier lights up both. The explicit hover
  /// content-shape makes the highlight follow the card's rounded corners
  /// instead of bleeding into a hard rectangle. macOS has no `.hoverEffect`,
  /// so it's a no-op there.
  ///
  /// Scope: rectangular tappable *surfaces* (tiles / cards / full-width rows),
  /// not inline text buttons or chevrons — those want a plain
  /// `.hoverEffect(.automatic)` with no card-shaped highlight.
  @ViewBuilder
  func tileHover(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
    #if os(iOS)
    self
      .contentShape(.hoverEffect,
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .hoverEffect(.highlight)
    #else
    self
    #endif
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
