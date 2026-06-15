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
  /// fall through to SwiftUI underneath, so a row inside a `List(selection:)`
  /// still selects on the first click. A SwiftUI `TapGesture` here would
  /// instead enter the gesture arena and swallow the List's selection click.
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

/// Transparent AppKit view that fires `action` on a secondary-click and then
/// gets out of the way so SwiftUI's `.contextMenu` opens the menu itself.
///
/// We deliberately NEVER claim the event: `hitTest(_:)` runs `action` (e.g.
/// "select this row") the instant a right-click lands, then returns `nil` so
/// the click falls straight THROUGH to the SwiftUI content beneath. Because the
/// event is never forwarded up the responder chain to the backing
/// `NSTableView`, the table never paints its own right-click row emphasis — that
/// emphasis is drawn independently of `selectionHighlightStyle` and would
/// otherwise stack on top of our on-theme selection bubble, producing the
/// "double selection" highlight. All other events (primary click, hover, drag)
/// pass through untouched too.
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

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard super.hitTest(point) != nil else { return nil }
      guard NSApp.currentEvent?.type == .rightMouseDown else { return nil }
      // Update selection now, then let the click reach SwiftUI's `.contextMenu`
      // below by returning nil. `action` (selectOnly) is idempotent, so the
      // occasional repeated hit-test during menu tracking is harmless.
      action()
      return nil
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

/// Reaches the `NSTableView` backing a SwiftUI `List` and turns OFF its native
/// selection highlight (`selectionHighlightStyle = .none`). Selection stays
/// fully live — click, ⌘/⇧-click, and ↑↓ keyboard nav all still update the
/// `List(selection:)` set — we just stop AppKit from painting the system-blue
/// full-bleed bar, so a view can draw its own on-theme selection background
/// instead. `.tint(.clear)` does NOT achieve this on a `.plain` macOS list;
/// the highlight style does.
///
/// Self-scoping: place it inside a list row (its host view is then a descendant
/// of the table), and it walks UP the superview chain to the first enclosing
/// `NSTableView` — guaranteed to be *that* list's table, never a sibling
/// list/sidebar in another split-view pane. Re-applies on every SwiftUI update
/// so it survives the list rebuilding its table (e.g. on a filter swap).
struct PlainListSelectionHighlightDisabler: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { Host() }
  func updateNSView(_ nsView: NSView, context: Context) {
    (nsView as? Host)?.disableHighlight()
  }

  final class Host: NSView {
    private weak var table: NSTableView?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // Defer one runloop hop so the List's NSTableView is in the tree.
      DispatchQueue.main.async { [weak self] in self?.disableHighlight() }
    }

    func disableHighlight() {
      if let table {
        table.selectionHighlightStyle = .none
        return
      }
      var ancestor = superview
      while let current = ancestor {
        if let found = current as? NSTableView {
          found.selectionHighlightStyle = .none
          table = found
          return
        }
        ancestor = current.superview
      }
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
