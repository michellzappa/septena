import SwiftUI

// Accessibility primitives shared across the app.
//
// The goal of this file is to give every view one place to reach for when it
// needs to do the right thing for VoiceOver, Dynamic Type, Reduce Motion, and
// the rest of the modern Apple accessibility surface. The conventions:
//
//   • Declarative state belongs in modifiers (`.a11yAnimation`, `.a11yMinTap`,
//     `.a11yHeader`). They read the environment for you, so call sites don't
//     have to hold `@Environment(\.accessibilityReduceMotion)` themselves.
//   • Imperative side-effects (announcing a state change after a network
//     write, for example) go through `Accessibility.announce(_:)` and friends.
//   • Scaled spacing/sizes use `@ScaledMetric` *inside* a `ViewModifier` so
//     they participate in Dynamic Type without leaking property wrappers into
//     every call site.
//
// New helpers should follow the same pattern: small, composable, and named so
// the call site reads like a sentence ("min tap target", "header trait").

// MARK: - Imperative announcements
//
// Use these when state changes outside the view tree — a successful write,
// a banner appearing, a toast — that VoiceOver wouldn't otherwise notice.
// All three are safe to call from any thread.
//
// Namespaced as `A11y` to avoid colliding with SwiftUI's `Accessibility*`
// types (e.g. `AccessibilityNotification`) — a top-level `enum Accessibility`
// shadows them and confuses type lookup inside this file.

enum A11y {

  /// Speak `message` immediately. Use for confirmations, counts updated by
  /// async work, and other transient feedback. Pass `highPriority: true` to
  /// interrupt VoiceOver's current speech (use sparingly — most updates
  /// should queue behind whatever the user is hearing).
  static func announce(_ message: String, highPriority: Bool = false) {
    guard !message.isEmpty else { return }
    if highPriority {
      var attributed = AttributedString(message)
      // Type inferred from the property — avoids naming SwiftUI's nested
      // priority type, which lives in a moving namespace across releases.
      attributed.accessibilitySpeechAnnouncementPriority = .high
      AccessibilityNotification.Announcement(attributed).post()
    } else {
      AccessibilityNotification.Announcement(message).post()
    }
  }

  /// Tell VoiceOver the layout reshuffled (e.g. a sheet collapsed, a row
  /// became visible). `focused` optionally moves focus to the named element.
  static func layoutChanged(focused message: String? = nil) {
    AccessibilityNotification.LayoutChanged(message).post()
  }

  /// Tell VoiceOver the whole screen changed (e.g. a full-screen sheet
  /// replaced the dashboard). Resets the rotor and reads `focused` if given.
  static func screenChanged(focused message: String? = nil) {
    AccessibilityNotification.ScreenChanged(message).post()
  }
}

// MARK: - Motion-aware animation
//
// `\.accessibilityReduceMotion` is true when the user has turned on Reduce
// Motion in Settings. Animations that *convey* meaning (a row expanding to
// reveal sub-rows) should disable themselves; animations that are purely
// decorative (a fade-in for polish) should also disable, since the user
// preference is a hard switch, not a hint.

/// View modifier flavor — read motion preference from the environment and
/// drop the animation if the user opts out.
private struct A11yAnimationModifier<V: Equatable>: ViewModifier {
  let animation: Animation?
  let value: V
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.animation(reduceMotion ? nil : animation, value: value)
  }
}

extension View {

  /// Drop-in replacement for `.animation(_:value:)` that honors Reduce Motion.
  /// The animation is suppressed entirely when the user has the setting on —
  /// the value change still happens, but instantaneously.
  func a11yAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
    modifier(A11yAnimationModifier(animation: animation, value: value))
  }
}

/// Motion preferences wrapped so they can be passed around (e.g. into
/// imperative `withAnimation` blocks where we can't read the environment).
struct A11yMotion {
  let reduceMotion: Bool

  /// Imperative analogue of `withAnimation` that respects Reduce Motion.
  /// When the user prefers reduced motion, runs `body` without an animation
  /// transaction so state still updates but instantly.
  @discardableResult
  func run<R>(_ animation: Animation? = .default, _ body: () -> R) -> R {
    if reduceMotion { return body() }
    return withAnimation(animation, body)
  }
}

extension EnvironmentValues {
  /// Composite view of the motion-related accessibility settings, suitable
  /// for `@Environment(\.a11yMotion)` at a view's top level.
  var a11yMotion: A11yMotion {
    A11yMotion(reduceMotion: accessibilityReduceMotion)
  }
}

// MARK: - Settle
//
// One place owns the "confirm → linger → fade" timing the whole app uses for
// completing checklist-style items (tasks, habits, supplements, chores).
//
// The pattern: when you check something off it should NOT vanish under your
// finger. It stays in place, struck through, for a beat — long enough to read
// as "done" — then animates out of the open list (rows below slide up) and
// lands in the Done section. Re-checking within that window cancels the
// fade-out (you changed your mind).
//
// `SettleStore` is the cancellable timer behind that beat. It owns *only* the
// scheduling; callers supply the `finalize` closure that does the actual state
// mutation, wrapped in their own motion-gated animation (`A11yMotion.run`) so
// Reduce Motion drops the fade while keeping the delayed removal. The
// `settling` set lets a view keep a just-completed row visible during the
// window (e.g. `TaskListView.visibleItems`, which otherwise filters done tasks).

@MainActor
@Observable
final class SettleStore {
  /// How long a checked item lingers, struck through, before it fades out.
  static let delay: Duration = .milliseconds(2000)

  /// Ids currently lingering (checked, not yet faded). Read by views that need
  /// to keep a just-completed row on screen during the window.
  private(set) var settling: Set<String> = []

  private var pending: [String: Task<Void, Never>] = [:]

  func isSettling(_ id: String) -> Bool { settling.contains(id) }

  /// Keep `id` lingering, then run `finalize` after the delay. The caller
  /// wraps its own state mutation in the right (motion-gated) animation.
  /// Re-scheduling the same id restarts the clock.
  func schedule(_ id: String, finalize: @escaping () -> Void) {
    pending[id]?.cancel()
    settling.insert(id)
    pending[id] = Task { [weak self] in
      try? await Task.sleep(for: SettleStore.delay)
      guard !Task.isCancelled, let self else { return }
      self.settling.remove(id)
      self.pending[id] = nil
      finalize()
    }
  }

  /// User un-checked within the window → abort the fade-out.
  func cancel(_ id: String) {
    pending[id]?.cancel()
    pending[id] = nil
    settling.remove(id)
  }

  /// Drop every pending settle (e.g. on a full reload or filter swap) so no
  /// orphaned timer fires against stale state.
  func cancelAll() {
    for task in pending.values { task.cancel() }
    pending.removeAll()
    settling.removeAll()
  }
}

// MARK: - Dynamic-Type-aware tap targets
//
// Apple HIG asks for 44×44 pt minimums on iOS and ~24 pt on macOS. WCAG 2.2
// AA (success criterion 2.5.8) requires at least 24×24 css px. We scale the
// minimum with Dynamic Type so the hit area grows with text — important
// since icon-only buttons in this app tend to be 28–32 pt and disappear
// behind AX5 text otherwise.

#if os(macOS)
private let _a11yDefaultTapTarget: CGFloat = 28
#else
private let _a11yDefaultTapTarget: CGFloat = 44
#endif

private struct A11yMinTapTargetModifier: ViewModifier {
  @ScaledMetric private var minSize: CGFloat

  init(base: CGFloat) {
    self._minSize = ScaledMetric(wrappedValue: base)
  }

  func body(content: Content) -> some View {
    content
      .frame(minWidth: minSize, minHeight: minSize)
      .contentShape(Rectangle())
  }
}

extension View {

  /// Expand the receiver's hit region to at least Apple's HIG minimum
  /// (44 pt iOS / 28 pt macOS), scaled with Dynamic Type. The visible
  /// content stays its original size — only the tap region grows, via
  /// `.contentShape(Rectangle())`.
  func a11yMinTapTarget(_ base: CGFloat? = nil) -> some View {
    modifier(A11yMinTapTargetModifier(base: base ?? _a11yDefaultTapTarget))
  }
}

// MARK: - Scaled metrics for icons / chips
//
// Same idea as the tap target, but for the inner glyph or chip size where
// we *do* want the visual to grow with Dynamic Type. Use when replacing a
// hard-coded `Font.system(size: 22)` or `.frame(width: 32, height: 32)`.

private struct A11yScaledFrameModifier: ViewModifier {
  @ScaledMetric private var size: CGFloat

  init(base: CGFloat) {
    self._size = ScaledMetric(wrappedValue: base)
  }

  func body(content: Content) -> some View {
    content.frame(width: size, height: size)
  }
}

extension View {

  /// Set a square frame that scales with Dynamic Type. Prefer this over
  /// `.frame(width: N, height: N)` for icon-only buttons and glyph chips.
  func a11yScaledFrame(_ base: CGFloat) -> some View {
    modifier(A11yScaledFrameModifier(base: base))
  }
}

// MARK: - Scaled system font
//
// A fixed-point `Font.system(size:)` does NOT participate in Dynamic Type —
// it renders at the same pt size regardless of the user's text-size setting,
// which is the single biggest Dynamic Type gap in this app. This modifier is
// a drop-in replacement: the argument labels mirror `.system(size:weight:
// design:)` exactly, so migrating a call site is purely swapping
// `.font(.system(...))` for `.scaledFont(...)`.
//
// The size is anchored with `@ScaledMetric` so it keeps its exact value at
// the default text size and grows/shrinks proportionally from there. Pass
// `relativeTo:` to pick which text style sets the scaling curve — default
// `.body` suits most UI text; use `.largeTitle` for big display numerals so
// they don't balloon disproportionately at AX5.

private struct ScaledSystemFontModifier: ViewModifier {
  @ScaledMetric private var size: CGFloat
  let weight: Font.Weight?
  let design: Font.Design?

  init(size: CGFloat,
       relativeTo textStyle: Font.TextStyle,
       weight: Font.Weight?,
       design: Font.Design?) {
    self._size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
    self.weight = weight
    self.design = design
  }

  func body(content: Content) -> some View {
    content.font(.system(size: size,
                         weight: weight ?? .regular,
                         design: design ?? .default))
  }
}

extension View {

  /// Dynamic-Type-aware replacement for `.scaledFont(size:weight:design:)`.
  /// Renders at `size` pt at the default text setting and scales from there.
  func scaledFont(size: CGFloat,
                  weight: Font.Weight? = nil,
                  design: Font.Design? = nil,
                  relativeTo textStyle: Font.TextStyle = .body) -> some View {
    modifier(ScaledSystemFontModifier(size: size,
                                      relativeTo: textStyle,
                                      weight: weight,
                                      design: design))
  }
}

// MARK: - Semantic trait shortcuts
//
// These are thin wrappers over the built-in modifiers, kept here so call
// sites read as a single intent ("this is a header") rather than a chain
// of three modifiers — and so we can adjust the implementation in one
// place later (e.g. add `.accessibilitySortPriority` to headers).

extension View {

  /// Mark the receiver as a header in the accessibility tree. Provide
  /// `label` only if the visible text isn't already accurate.
  func a11yHeader(_ label: String? = nil) -> some View {
    let view = self.accessibilityAddTraits(.isHeader)
    if let label {
      return AnyView(view.accessibilityLabel(label))
    }
    return AnyView(view)
  }

  /// Mark the receiver as updating its value frequently (live counters,
  /// timers). VoiceOver will re-read the value on changes without
  /// interrupting the user's current speech.
  func a11yLiveValue() -> some View {
    accessibilityAddTraits(.updatesFrequently)
  }

  /// Compose multiple child accessibility elements into one. Pass a
  /// `label` for what the combined element should announce.
  func a11yCombine(_ label: String) -> some View {
    accessibilityElement(children: .combine)
      .accessibilityLabel(label)
  }

  /// Compose into one element while preserving children for VoiceOver
  /// rotor navigation — useful for cards where the headline is the
  /// announce text but stats inside should still be reachable.
  func a11yCombineKeepingChildren(_ label: String) -> some View {
    accessibilityElement(children: .contain)
      .accessibilityLabel(label)
  }
}

// MARK: - Identifier namespace
//
// `.accessibilityIdentifier` doubles as a UI-test hook and a Voice Control
// name. We namespace by view so identifiers don't collide and can be
// referenced from snapshot/UI-test code without magic strings.
//
// Usage:
//   .a11yID(.dashboard("module-tile-training"))

enum A11yID {
  case dashboard(String)
  case tasks(String)
  case addInfo(String)
  case sidebar(String)
  case settings(String)
  case custom(String)

  var raw: String {
    switch self {
    case .dashboard(let s): return "dashboard.\(s)"
    case .tasks(let s):     return "tasks.\(s)"
    case .addInfo(let s):   return "addInfo.\(s)"
    case .sidebar(let s):   return "sidebar.\(s)"
    case .settings(let s):  return "settings.\(s)"
    case .custom(let s):    return s
    }
  }
}

extension View {

  /// Namespaced accessibility identifier. Prefer this over the raw
  /// `.accessibilityIdentifier(_:)` so identifiers stay consistent and
  /// greppable.
  func a11yID(_ id: A11yID) -> some View {
    accessibilityIdentifier(id.raw)
  }
}
