import SwiftUI
#if os(macOS)
import AppKit
#endif

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

  /// Standard app-modal sheet sizing, so the tab-root's sheets don't each
  /// repeat the iOS-detents / macOS-frame `#if os` split: iOS gets presentation
  /// detents + a drag indicator; macOS gets a fixed frame (its sheets aren't
  /// detent-driven).
  @ViewBuilder
  func septenaModalSheet(detents: Set<PresentationDetent> = [.large],
                         macWidth: CGFloat,
                         macHeight: CGFloat) -> some View {
    #if os(iOS)
    self.presentationDetents(detents)
      .presentationDragIndicator(.visible)
    #else
    self.frame(width: macWidth, height: macHeight)
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

  /// Neutral-gray native `List(selection:)` row highlight on macOS and iPad.
  /// The app root tints with the section accent; without an explicit override
  /// here the selection capsule reads as meaningless blue. iPhone compact keeps
  /// the system default (edit-mode circles only).
  @ViewBuilder
  func septenaNeutralListSelection() -> some View {
    #if os(macOS)
    self.tint(Theme.selectionNeutral)
    #elseif os(iOS)
    self.modifier(NeutralListSelectionOnPad())
    #else
    self
    #endif
  }

  /// Task list chrome: `.inset` capsule rows on macOS and iPad regular width.
  /// iPhone compact stays `.plain` (selection is edit-mode circles only).
  @ViewBuilder
  func septenaTaskListStyle() -> some View {
    #if os(macOS)
    self.listStyle(.inset)
    #elseif os(iOS)
    self.modifier(TaskListStyleOnPad())
    #else
    self
    #endif
  }

  /// Neutral fill behind a selected `List(selection:)` row. Native UIKit/AppKit
  /// paints accent blue by default; pair with `septenaSuppressListCellSelection`.
  @ViewBuilder
  func selectableListRow(tag: String, isSelected: Bool) -> some View {
    self
      // Native hairline separators (was `.hidden`) so the rows read as one
      // continuous grouped card, the same as the Tasks sidebar — not a stack
      // of individually-rounded pills.
      .listRowBackground(SelectableListRowBackground(isSelected: isSelected))
      .listRowInsets(EdgeInsets())
      .tag(tag)
      .septenaSuppressListCellSelection()
  }

  /// Disable the platform's accent selection fill so `listRowBackground` is the
  /// only row highlight (UIKit blue on iOS, AppKit accent on macOS).
  @ViewBuilder
  func septenaSuppressListCellSelection() -> some View {
    #if os(iOS)
    self.background(TaskListCellSelectionSuppressor())
    #elseif os(macOS)
    self.background(TaskListRowSelectionSuppressor())
    #else
    self
    #endif
  }
}

/// Grouped-card row fill for native `insetGrouped` lists (the Next home).
/// Full-bleed so the enclosing section supplies the single rounded card (corners
/// on the first/last row only) — was a per-row `RoundedRectangle`, which made
/// every row read as its own pill with curved gaps between them. `cardSurface`
/// is the elevated grouped-cell color that lifts off the gray canvas; selected
/// rows tint with the neutral selection fill, edge to edge.
struct SelectableListRowBackground: View {
  let isSelected: Bool
  var body: some View {
    Rectangle()
      .fill(isSelected ? Theme.listSelectionFill : Theme.cardSurface)
  }
}

/// Row background for the custom scroll list (the task-list detail). The
/// grouped-card chrome (`TaskCardChrome`) now paints both the card surface AND
/// the selected-cell fill — edge-to-edge within the card, with the card's own
/// corners — so the row's own background stays clear. (It used to draw an inset
/// rounded capsule here, which floated as a separate bar on top of the card.)
struct ScrollRowSelectionBackground: View {
  let isSelected: Bool
  var body: some View {
    Color.clear
  }
}

#if os(iOS)
/// Applies `Theme.selectionNeutral` to selectable lists on iPad (regular width).
private struct NeutralListSelectionOnPad: ViewModifier {
  @Environment(\.horizontalSizeClass) private var hSize
  func body(content: Content) -> some View {
    if hSize == .regular {
      content.tint(Theme.selectionNeutral)
    } else {
      content
    }
  }
}

/// iPad regular width uses inset capsule rows like macOS; iPhone uses plain.
private struct TaskListStyleOnPad: ViewModifier {
  @Environment(\.horizontalSizeClass) private var hSize
  func body(content: Content) -> some View {
    if hSize == .regular {
      content.listStyle(.inset)
    } else {
      content.listStyle(.plain)
    }
  }
}

/// UITableView paints accent-blue behind selected rows regardless of SwiftUI
/// `.tint`. Disable the UIKit layer so our `listRowBackground` is the only
/// highlight. Attached per task row (inside the cell hierarchy).
private struct TaskListCellSelectionSuppressor: UIViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme

  func makeUIView(context: Context) -> UIView {
    let v = UIView()
    v.isUserInteractionEnabled = false
    return v
  }
  func updateUIView(_ uiView: UIView, context: Context) {
    DispatchQueue.main.async {
      var v: UIView? = uiView
      while let current = v {
        if let cell = current as? UITableViewCell {
          cell.selectionStyle = .none
          cell.selectedBackgroundView = UIView()
          cell.multipleSelectionBackgroundView = UIView()
          if #available(iOS 14.0, *) {
            var bg = UIBackgroundConfiguration.listPlainCell()
            bg.backgroundColor = .clear
            cell.backgroundConfiguration = bg
          }
          // Selected cells inherit traits that flip SwiftUI `Color.primary` to
          // white. Pin the cell subtree to the app color scheme so fixed ink wins.
          let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
          cell.contentView.overrideUserInterfaceStyle = style
          cell.contentView.findHostingView()?.overrideUserInterfaceStyle = style
          return
        }
        v = current.superview
      }
    }
  }
}

private extension UIView {
  func findHostingView() -> UIView? {
    let name = String(describing: type(of: self))
    if name.contains("Hosting") { return self }
    for sub in subviews {
      if let match = sub.findHostingView() { return match }
    }
    return nil
  }
}
#endif

#if os(macOS)
import AppKit

/// NSTableView paints accent-blue behind selected rows regardless of SwiftUI
/// `.tint`. Disable the AppKit layer so our `listRowBackground` is the only
/// highlight. Attached per task row (inside the cell hierarchy).
private struct TaskListRowSelectionSuppressor: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { PassThroughView() }

  /// macOS equivalent of UIKit `isUserInteractionEnabled = false`.
  private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      var v: NSView? = nsView
      while let current = v {
        if let row = current as? NSTableRowView {
          row.selectionHighlightStyle = .none
          return
        }
        v = current.superview
      }
    }
  }
}

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

/// Drop the insertion point at the END of the key window's active text field,
/// clearing the select-all that AppKit applies when a field becomes first
/// responder (so a freshly-focused inline rename reads as "continue typing",
/// not "overwrite"). SwiftUI's `TextField` exposes no cursor/selection API, so
/// this is the contained AppKit reach — a one-shot responder read, like the
/// `NSEvent.modifierFlags` read in `SelectableScrollList`, not an installed
/// monitor. A no-op unless a field editor currently holds focus.
func septenaMoveCursorToEnd() {
  guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
  let end = (editor.string as NSString).length
  editor.setSelectedRange(NSRange(location: end, length: 0))
}

#endif

/// Layout constants for `ClickToEditTitle` (file-scoped — generics can't hold statics).
private enum ClickToEditTitleMetrics {
  static let menuSpacing: CGFloat = 6
  static let menuWidth: CGFloat = 28
  /// Matches `.septenaScreenTitle` (large title) single-line cap height.
  static let titleLineHeight: CGFloat = 40
}

/// Click-to-edit title: renders as `Text` until tapped, then becomes a
/// `TextField` focused for editing. Commit on Enter / blur, cancel on Esc.
/// An optional trailing `menu` (e.g. the list-jump chevron) sits inline after
/// the title, hidden while editing so the field can use the full row width.
struct ClickToEditTitle<Menu: View>: View {
  let placeholder: String
  @Binding var text: String
  /// Called once the user finishes editing with a non-empty title. Receives
  /// the trimmed new value (use it to detect "did it actually change").
  var onCommit: (String) -> Void
  /// Font + foreground style applied to both the Text view and the field.
  var font: Font = .septenaScreenTitle
  var foreground: Color = Theme.inkPrimary
  @ViewBuilder var menu: () -> Menu

  @State private var isEditing = false
  @State private var snapshot: String = ""
  @FocusState private var focused: Bool

  init(placeholder: String,
       text: Binding<String>,
       font: Font = .septenaScreenTitle,
       foreground: Color = Theme.inkPrimary,
       onCommit: @escaping (String) -> Void,
       @ViewBuilder menu: @escaping () -> Menu) {
    self.placeholder = placeholder
    self._text = text
    self.font = font
    self.foreground = foreground
    self.onCommit = onCommit
    self.menu = menu
  }

  var body: some View {
    GeometryReader { geo in
      let maxW = geo.size.width
      if isEditing {
        titleField(maxWidth: maxW)
          .frame(width: maxW, alignment: .leading)
      } else {
        HStack(spacing: ClickToEditTitleMetrics.menuSpacing) {
          titleField(maxWidth: maxW)
          menu()
            .fixedSize()
        }
        // Hug title + chevron; cap at row width so long titles truncate in
        // place and the chevron never drifts to the far right.
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: maxW, alignment: .leading)
      }
    }
    .frame(height: ClickToEditTitleMetrics.titleLineHeight)
  }

  @ViewBuilder
  private func titleField(maxWidth: CGFloat) -> some View {
    if isEditing {
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .focusEffectDisabled()
        .focused($focused)
        .font(font)
        .foregroundStyle(foreground)
        .lineLimit(1)
        .frame(maxWidth: maxWidth, alignment: .leading)
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
        .lineLimit(1)
        .truncationMode(.tail)
        .contentShape(Rectangle())
        .septenaEditableTitleCursor()
        .onTapGesture { startEditing() }
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
  /// I-beam on hover for click-to-edit titles (area / project detail headers).
  @ViewBuilder
  func septenaEditableTitleCursor() -> some View {
    #if os(macOS)
    self.onHover { hovering in
      if hovering {
        NSCursor.iBeam.push()
      } else {
        NSCursor.pop()
      }
    }
    #else
    self
    #endif
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

  /// Grouped-gray canvas + top scroll-edge blur for home-tab List / ScrollView
  /// roots. Pair with `.scrollContentBackground(.hidden)` on List surfaces.
  /// No `.toolbarBackground` — Liquid Glass owns the bar material.
  func homeTabScrollSurface() -> some View {
    self
      .background { Theme.groupedBackground.ignoresSafeArea() }
      .scrollEdgeEffectStyle(.soft, for: .top)
  }

  #if os(macOS)
  /// macOS grouped-list cell: plain List row shaped as a Tasks-style card slice.
  func septenaHomeListRow(index: Int, count: Int, isSelected: Bool = false) -> some View {
    self
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .septenaSuppressListCellSelection()
      .taskCardChrome(TaskCardPosition(index: index, count: count), isSelected: isSelected)
  }
  #endif

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

/// Subtle pointer-hover background wash — no scale/lift, just a 6% primary
/// tint. Works on macOS trackpad and iPadOS pointer / Apple Pencil hover.
private struct PointerHoverWash<S: Shape>: ViewModifier {
  let shape: S
  var opacity: Double = 0.06
  @State private var hovered = false

  func body(content: Content) -> some View {
    content
      .background {
        shape.fill(Color.primary.opacity(hovered ? opacity : 0))
      }
      .onHover { hovered = $0 }
  }
}

extension View {
  /// Universal pointer / Apple-Pencil-hover for tappable custom surfaces
  /// (dashboard tiles, cards, log rows). System controls get hover for free;
  /// `.buttonStyle(.plain)` opts out, so tappable-but-plain surfaces must
  /// request it back. Background wash only — no scale or lift.
  ///
  /// Scope: rectangular tappable *surfaces* (tiles / cards / full-width rows),
  /// not inline text buttons or chevrons — use `inlineHover` for those.
  func tileHover(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return modifier(PointerHoverWash(shape: shape))
  }

  /// Alias for list rows — same affordance as `tileHover`, canonical row radius.
  func rowHover(cornerRadius: CGFloat = Theme.cornerRadiusSmall) -> some View {
    tileHover(cornerRadius: cornerRadius)
  }

  /// Pointer hover for compact plain buttons (menu triggers, chevrons, filing
  /// pills). Background wash only — no scale or lift.
  @ViewBuilder
  func inlineHover(cornerRadius: CGFloat? = nil, capsule: Bool = false) -> some View {
    if capsule {
      modifier(PointerHoverWash(shape: Capsule()))
    } else if let cornerRadius {
      let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      modifier(PointerHoverWash(shape: shape))
    } else {
      modifier(PointerHoverWash(
        shape: RoundedRectangle(cornerRadius: 6, style: .continuous)))
    }
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

/// Plain button with cross-platform pointer hover for full-width tappable rows.
/// Drop-in for `.buttonStyle(.plain)` on navigation rows, picker sheets, and
/// any surface where `.buttonStyle(.plain)` opts out of the system hover.
/// Parent chrome (`taskCardChrome`, `septenaNextRow`) already paints hover —
/// keep `.plain` there to avoid doubling up.
struct PlainHoverRowButtonStyle: ButtonStyle {
  var cornerRadius: CGFloat = Theme.cornerRadiusSmall

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .rowHover(cornerRadius: cornerRadius)
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
