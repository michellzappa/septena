import SwiftUI

// Shared drawer and sheet plumbing for the task views: the adaptive-navigation
// environment, `macSheetFrame`, adaptive detail presentation, the edit scaffold
// and the close control. The life OS section drawer that gave this file its name
// left with ADR 0017.

private struct UsesPushNavigationKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// True when a destination should open as a pushed full pane (with room to
  /// dock an inspector) rather than a modal bottom sheet. This is the single source of
  /// truth for that rule: every surface reads it instead of
  /// recomputing from the size class, so they can never drift. True only on a
  /// dual-regular canvas (regular width AND height): iPad full-screen, an
  /// unfolded foldable, macOS. A landscape iPhone is regular-width but
  /// compact-height, so it reads false here and gets the bottom-sheet drawer.
  /// Published once at the app root by `.resolvesAdaptiveNavigation()`.
  var usesPushNavigation: Bool {
    get { self[UsesPushNavigationKey.self] }
    set { self[UsesPushNavigationKey.self] = newValue }
  }
}

extension View {
  /// Resolves the adaptive-navigation rule from the current size classes and
  /// publishes it into the environment as `\.usesPushNavigation`. macOS always
  /// pushes; iOS pushes only when BOTH size classes are regular (iPad
  /// full-screen / large multitasking / unfolded foldable), so a compact iPad
  /// window AND a landscape iPhone (regular width, compact height) both fall
  /// back to bottom sheets. Apply once near the app root.
  func resolvesAdaptiveNavigation() -> some View {
    modifier(ResolveAdaptiveNavigation())
  }
}

private struct ResolveAdaptiveNavigation: ViewModifier {
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  @Environment(\.verticalSizeClass) private var vSize
  #endif

  private var usesPush: Bool {
    #if os(macOS)
    return true
    #else
    // A pushed pane / side-by-side drawer wants a genuinely large canvas —
    // regular in BOTH dimensions (iPad full-screen, an unfolded foldable, a
    // wide Mac window). A landscape iPhone reports a regular *width* but a
    // compact *height*: it's short and notch-asymmetric, so the iPad pushed-
    // pane treatment looks broken there. Gating on height too sends it down
    // the bottom-sheet path (the polished portrait drawer) instead, while
    // staying size-class-driven — never an idiom check — so a foldable still
    // gets the full treatment when unfolded.
    return hSize == .regular && vSize == .regular
    #endif
  }

  func body(content: Content) -> some View {
    content.environment(\.usesPushNavigation, usesPush)
  }
}

extension View {
  /// macOS sheets size to their content's *ideal* height, and List/Form/
  /// NavigationStack-backed content has none — the sheet collapses to zero.
  /// Apply this to any sheet content compiled for macOS that isn't already
  /// framed (or wrapped in `sectionDrawerPresentation()`); it's a no-op on iOS,
  /// where detents own the sheet size.
  func macSheetFrame(width: CGFloat = 560, height: CGFloat = 600) -> some View {
    #if os(macOS)
    return frame(width: width, height: height)
    #else
    return self
    #endif
  }
}

// MARK: - Adaptive detail presentation
//
// One primitive for "open a record's detail / edit form" that resolves to
// the right idiom per surface:
//
//   • compact width (iPhone)        → modal `.sheet` (unchanged native idiom)
//   • regular width (iPad / macOS)  → docked `.inspector` trailing pane, so
//     the list/log stays visible and editing a record never covers the
//     context the user was just looking at.
//
// Convert a section's `.sheet(item:)` / `.sheet(isPresented:)` to the
// matching `.adaptiveDetail(...)` and it inherits coherent behavior on all
// three surfaces — no per-section size-class branching.
//
// Dismissal: a docked inspector is NOT a "presentation," so the inner
// form's `@Environment(\.dismiss)` is a no-op there. The primitive injects
// `\.adaptiveDetailClose`; edit forms should close through that (it falls
// back to `dismiss()` when absent, so a form still works if presented as a
// plain sheet elsewhere).

private struct AdaptiveDetailCloseKey: EnvironmentKey {
  static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
  /// Closes the enclosing adaptive detail presentation (sheet or docked
  /// inspector). `nil` when the view isn't hosted by `.adaptiveDetail` —
  /// callers should fall back to `@Environment(\.dismiss)`.
  var adaptiveDetailClose: (() -> Void)? {
    get { self[AdaptiveDetailCloseKey.self] }
    set { self[AdaptiveDetailCloseKey.self] = newValue }
  }
}

extension View {
  /// Item-driven adaptive detail. Drop-in replacement for `.sheet(item:)`.
  func adaptiveDetail<Item: Identifiable, DetailContent: View>(
    item: Binding<Item?>,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping (Item) -> DetailContent
  ) -> some View {
    modifier(AdaptiveDetailItem(item: item, onDismiss: onDismiss, detail: content))
  }

  /// Flag-driven adaptive detail. Drop-in replacement for
  /// `.sheet(isPresented:)`.
  func adaptiveDetail<DetailContent: View>(
    isPresented: Binding<Bool>,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> DetailContent
  ) -> some View {
    modifier(AdaptiveDetailFlag(isPresented: isPresented, onDismiss: onDismiss, detail: content))
  }

}

// MARK: - AdaptiveEditScaffold
//
// The standard chrome for an edit/create form hosted by `.adaptiveDetail`.
// Absorbs the two cross-surface rules so no individual form repeats them:
//
//   1. Close through `\.adaptiveDetailClose` (docked inspector) with a
//      `dismiss()` fallback (plain sheet). Save closes after the action runs.
//   2. Pick chrome by host: a docked inspector gets an inline header (a
//      nested NavigationStack would double-render its toolbar in the macOS
//      title bar); a bottom sheet gets a NavigationStack + nav-bar toolbar.
//
// A form supplies only what's genuinely its own — a title, the save action,
// optional labels / save-enabled flag — and its fields via the trailing
// closure. There are no per-form layout constants to copy.
//
//   var body: some View {
//     AdaptiveEditScaffold(title: navTitle, onSave: save) {
//       Form { … }.onAppear { seed() }
//     }
//   }
struct AdaptiveEditScaffold<FormContent: View>: View {
  let title: String
  /// Confirmation label. Defaults to "Save"; pass "Add", "Done", etc.
  var saveTitle: String = "Save"
  /// Hides the confirmation control entirely. Use when the close control already
  /// persists (autosave-on-close) so a separate Save would be redundant — the
  /// left control alone ("Done") both saves and closes.
  var showsSave: Bool = true
  /// Tints just the Cancel/Save controls. The form content stays neutral; pass
  /// a section color when you want the confirm/cancel affordances accented
  /// without coloring the whole form.
  var accent: Color? = nil
  /// Disables the confirmation control (e.g. while a required field is
  /// empty). The form owns the validation; the scaffold owns the affordance.
  var canSave: Bool = true
  /// Opt-in: there are unsaved changes. When an `onDiscard` is supplied, this
  /// turns Cancel into a guarded discard — Cancel/Esc on a dirty form prompts
  /// before dropping the work, and the interactive swipe-to-dismiss is blocked
  /// so an accidental gesture can never discard. Forms without `onDiscard` (the
  /// autosave-on-close ones) ignore this and Cancel just closes, as before.
  var isDirty: Bool = false
  /// Prompt shown in the discard confirmation (e.g. "Discard new task?").
  var discardTitle: String = "Discard changes?"
  /// The save action. The scaffold runs it, then closes — forms must NOT
  /// call dismiss/close themselves (that's what produced the double-close
  /// and dismiss-no-op bugs the inspector exposed).
  let onSave: () -> Void
  /// Opt-in discard action: run when the user explicitly confirms Cancel →
  /// Discard. Supply it to get the dirty-aware Cancel guard above (the form
  /// uses it to suppress any autosave-on-close so the draft is truly dropped).
  /// When nil, Cancel is a plain close.
  var onDiscard: (() -> Void)? = nil
  /// Optional trailing control in the header (e.g. a ⋯ overflow menu of
  /// contextual actions). Sits where Save would be when `showsSave` is false.
  var trailing: AnyView? = nil
  @ViewBuilder var content: () -> FormContent

  @Environment(\.dismiss) private var dismiss
  @Environment(\.adaptiveDetailClose) private var adaptiveClose
  @State private var showDiscardConfirm = false

  private var isInspector: Bool { adaptiveClose != nil }
  private func close() { (adaptiveClose ?? { dismiss() })() }
  private func confirm() { onSave(); close() }

  /// The leading control's action. Without discard semantics it's a plain close
  /// (the autosave-on-close forms persist via their own `.onDisappear`). With an
  /// `onDiscard`, a dirty form prompts first; a clean one just closes.
  private func requestCancel() {
    guard onDiscard != nil else { close(); return }
    if isDirty { showDiscardConfirm = true } else { discard() }
  }
  private func discard() { onDiscard?(); close() }

  var body: some View {
    Group {
      if isInspector {
        content()
          .safeAreaInset(edge: .top, spacing: 0) {
            AdaptiveEditHeader(
              title: title,
              saveTitle: saveTitle,
              showsSave: showsSave,
              canSave: canSave,
              accent: accent,
              onCancel: requestCancel,
              onSave: confirm,
              trailing: trailing
            )
          }
      } else {
        NavigationStack {
          content()
            // A default-styled macOS `Form` reports no flexible height, so in
            // this sheet branch it collapses to no apparent height. Grouped (the
            // app's house style, and already the iOS Form default) scrolls and
            // fills the sheet. Centralized here so no individual form repeats it.
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                DrawerCloseButton(action: requestCancel)
                  .tint(accent)
              }
              if showsSave {
                ToolbarItem(placement: .confirmationAction) {
                  Button(saveTitle, action: confirm)
                    .tint(accent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction) // Return / ⌘Return
                }
              }
              if let trailing {
                ToolbarItem(placement: .primaryAction) { trailing }
              }
            }
        }
      }
    }
    // A dirty form with discard semantics can't be swiped/clicked away — the
    // only exits are Save (commit) or Cancel (confirmed discard), so an
    // accidental gesture can never drop the work.
    .interactiveDismissDisabled(onDiscard != nil && isDirty)
    .confirmationDialog(discardTitle, isPresented: $showDiscardConfirm, titleVisibility: .visible) {
      Button("Discard", role: .destructive, action: discard)
      Button("Keep Editing", role: .cancel) {}
    }
  }
}

/// The inline header used by `AdaptiveEditScaffold` in its docked-inspector
/// mode: Close (x) · title · Save, on a material bar. Kept private — forms only
/// ever go through the scaffold.
/// The leading close control of every drawer and sheet: the system close
/// button (an x), never a "Cancel" text button. The edit to-do drawer set the
/// pattern; every sheet uses this one control so they cannot drift. The x only
/// leaves: a form with unsaved work still asks before it discards (the caller
/// routes the action through its own guard). Escape triggers it.
struct DrawerCloseButton: View {
  let action: () -> Void

  var body: some View {
    Button(role: .close, action: action)
      .keyboardShortcut(.cancelAction) // Esc
  }
}

private struct AdaptiveEditHeader: View {
  let title: String
  let saveTitle: String
  var showsSave: Bool = true
  let canSave: Bool
  var accent: Color? = nil
  let onCancel: () -> Void
  let onSave: () -> Void
  var trailing: AnyView? = nil

  var body: some View {
    HStack(spacing: 12) {
      DrawerCloseButton(action: onCancel)
      Spacer()
      Text(title).font(.headline)
      Spacer()
      if showsSave {
        Button(saveTitle, action: onSave)
          .fontWeight(.semibold)
          .disabled(!canSave)
          .keyboardShortcut(.defaultAction) // Return / ⌘Return
      }
      if let trailing { trailing }
    }
    .tint(accent)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }
}

private struct AdaptiveDetailItem<Item: Identifiable, DetailContent: View>: ViewModifier {
  @Binding var item: Item?
  let onDismiss: (() -> Void)?
  @ViewBuilder let detail: (Item) -> DetailContent

  // Detail content docks as an inspector exactly where sections push as a
  // full pane (regular width / macOS), so it shares the one push-navigation
  // rule rather than recomputing from the size class. On compact the section
  // is a bottom sheet, so edits stay sheets too.
  @Environment(\.usesPushNavigation) private var useInspector

  func body(content: Content) -> some View {
    if useInspector {
      content.inspector(isPresented: presented) {
        // `item` may briefly be nil during dismissal animation; guard so
        // the inspector empties cleanly instead of force-unwrapping.
        if let item {
          detail(item)
            .environment(\.adaptiveDetailClose, close)
            .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
      }
    } else {
      content.sheet(item: $item, onDismiss: onDismiss, content: detail)
    }
  }

  /// Bridges the optional item to the inspector's `isPresented` binding.
  /// Clearing it (swipe-away / toolbar toggle) routes through `close` so
  /// `onDismiss` fires exactly once on every dismissal path.
  private var presented: Binding<Bool> {
    Binding(get: { item != nil }, set: { if !$0 { close() } })
  }

  private func close() {
    item = nil
    onDismiss?()
  }
}

private struct AdaptiveDetailFlag<DetailContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  let onDismiss: (() -> Void)?
  @ViewBuilder let detail: () -> DetailContent

  @Environment(\.usesPushNavigation) private var useInspector

  func body(content: Content) -> some View {
    if useInspector {
      content
        .inspector(isPresented: $isPresented) {
          detail()
            .environment(\.adaptiveDetailClose, close)
            .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
        // Fire onDismiss when the inspector is toggled shut by the system.
        .onChange(of: isPresented) { _, now in if !now { onDismiss?() } }
    } else {
      content.sheet(isPresented: $isPresented, onDismiss: onDismiss, content: detail)
    }
  }

  private func close() {
    isPresented = false
  }
}

// DrawerSection — titled, rounded, grouped block. Visual analogue of an
// insetGrouped List `Section("Title")`: secondary-grouped fill, rounded
// corners, an uppercase footnote header. Content is laid out as a VStack;
// inner views render at their natural height (no row insets to fight).

private struct RowHInsetKey: EnvironmentKey {
  static let defaultValue: CGFloat = Theme.hPadding
}

private struct RowVInsetKey: EnvironmentKey {
  static let defaultValue: CGFloat = Theme.rowVPadding
}

extension EnvironmentValues {
  /// Horizontal inset a checkable / log row applies between its own edge and
  /// its content. Defaults to `Theme.hPadding` (20pt) — the value a row needs
  /// when it's the only frame around its content. A `DrawerSection` card lowers
  /// it to `Theme.Spacing.xl`: the card already sits 20pt off the screen edge,
  /// so the full 20pt row inset would stack into a visible double margin. At the
  /// card's value the row content lines up with the section title instead.
  var rowHInset: CGFloat {
    get { self[RowHInsetKey.self] }
    set { self[RowHInsetKey.self] = newValue }
  }

  /// Vertical padding a checkable / task row applies top and bottom. Defaults to
  /// `Theme.rowVPadding` — the airier rhythm the drawer's log/task rows keep.
  /// The deep task-list surfaces override it to `Theme.rowVPaddingTight` for a
  /// denser list without affecting drawer density.
  var rowVInset: CGFloat {
    get { self[RowVInsetKey.self] }
    set { self[RowVInsetKey.self] = newValue }
  }
}

// MARK: - Dual-mode side-by-side
