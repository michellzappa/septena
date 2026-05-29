import SwiftUI

// SectionDrawer — the standard outer container for every section's
// destination view. One pattern replaces the per-section List/ScrollView
// drift: ScrollView + LazyVStack, grouped background, the goals strip
// always pinned at the top, consistent padding.
//
// Destination views supply only their section-specific content via the
// trailing closure. Group content into `DrawerSection`s the same way you
// previously used List `Section("Title") { ... }`.

/// Cross-cutting load lifecycle a destination can hand to its drawer.
/// `.idle` is the no-op default (drawer renders the content as-is);
/// `.loading` surfaces a subtle inline spinner in the toolbar so the
/// user knows a fetch is in flight without blocking what's already on
/// screen (most destinations cache via `paintFromCache`); `.failed`
/// replaces `content()` with a standardized retry affordance.
enum DrawerLoadState: Equatable {
  case idle
  case loading
  case failed(String)
}

struct SectionDrawer<Content: View>: View {
  let sectionKey: String
  /// Editorial title rendered left-aligned at the top of the drawer body
  /// (Fraunces, ~34pt). The system nav bar title is suppressed so the
  /// drawer owns the page's identity. Pass an empty string to skip it
  /// (utility drawers that don't need a heading).
  let title: String
  /// Tint used for the "+" toolbar affordance (and inherited by sheets
  /// presented from this drawer). Defaults to the section's theme color
  /// if the destination doesn't override.
  var accent: Color? = nil
  /// Invoked with the tapped `LogAction.id` when the drawer's "+"
  /// affordance fires. Required for + to appear — if `nil`, no button
  /// is rendered even if the plugin declares `logActions`.
  var onLog: ((String) -> Void)? = nil
  /// Drawer-level load lifecycle. `.idle` is the no-op default. When
  /// the destination knows about its own fetch state, surface it here
  /// so the toolbar spinner / failure-state UI stays consistent.
  var loadState: DrawerLoadState = .idle
  /// Invoked when the user taps "Try again" on the failed-state UI.
  /// Required only when `loadState` can become `.failed`.
  var onRetry: (() -> Void)? = nil
  /// Binding to a destination's search query. Non-nil installs the
  /// system `.searchable` field on the drawer (sheet-style pull-down on
  /// iOS, leading-edge field on macOS). The destination consumes the
  /// string to filter its content; the drawer just hosts the input.
  var searchText: Binding<String>? = nil
  /// Optional search-field placeholder. Defaults to "Search".
  var searchPrompt: String = "Search"
  /// Binding to the YYYY-MM-DD date the destination is currently
  /// viewing. Non-nil installs the `DrawerDateStrip` under the title so
  /// the user can step prev/next, jump to today, or open a date picker
  /// without leaving the drawer. The destination reads the same binding
  /// to fetch its day-scoped data, replacing per-section
  /// `BrowseXDaySheet` detours.
  var currentDate: Binding<String>? = nil
  @ViewBuilder var content: () -> Content

  @Environment(SectionTheme.self) private var theme

  private var resolvedAccent: Color {
    accent ?? theme.color(for: sectionKey)
  }

  private var actions: [LogAction] {
    SectionRegistry.plugin(forKey: sectionKey)?.logActions ?? []
  }

  /// True when the destination has a date strip pointing at a past day.
  /// Hides the goals strip and signals to destinations (via the shared
  /// `SeptenaDate.today` comparison they can do themselves) that
  /// histograms / heatmaps should also be hidden — past days are a
  /// read-only log review, not a dashboard.
  private var isTimeTraveling: Bool {
    guard let currentDate else { return false }
    return currentDate.wrappedValue != SeptenaDate.today
  }

  var body: some View {
    ScrollView {
      // Spacing/margins tuned to match insetGrouped List: ~20pt screen
      // inset and ~28pt between sections so the page breathes the same
      // way the old List did.
      LazyVStack(spacing: Theme.Spacing.xxl) {
        if !title.isEmpty {
          Text(title)
            .font(.septenaScreenTitle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let currentDate {
          DrawerDateStrip(date: currentDate)
        }
        if !isTimeTraveling {
          SectionGoalsStrip(sectionKey: sectionKey)
        }
        if case .failed(let message) = loadState {
          failedView(message)
        } else {
          content()
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, Theme.Spacing.sm)
      .padding(.bottom, 24)
    }
    .background(Theme.groupedBackground)
    // Conditional `.searchable` — present only when the destination
    // passes a binding so non-search drawers don't render an empty
    // input. We use a switch over the Optional so SwiftUI's view
    // identity stays stable per branch.
    .modifier(OptionalSearchable(text: searchText, prompt: searchPrompt))
    // Inline title display so the section name sits on the same row as
    // the toolbar's + button — keeps the drawer top compact.
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .tint(resolvedAccent)
    // Suppress the centered nav-bar title — the drawer renders its own
    // left-aligned editorial heading inside the scroll content.
    #if os(iOS)
    .toolbar {
      ToolbarItem(placement: .principal) { EmptyView() }
    }
    #endif
    .toolbar {
      if loadState == .loading {
        // Subtle inline activity indicator next to the title slot so
        // background fetches surface without blocking the cached
        // content underneath.
        ToolbarItem(placement: .primaryAction) {
          ProgressView()
            .controlSize(.small)
        }
      }
      if let onLog, !actions.isEmpty {
        ToolbarItem(placement: .primaryAction) {
          if actions.count == 1, let only = actions.first {
            Button { onLog(only.id) } label: {
              Label(only.title,
                    systemImage: only.systemImage ?? "plus")
            }
            .tint(resolvedAccent)
            .keyboardShortcut("n", modifiers: .command)
          } else {
            Menu {
              // First menu item carries the ⌘N shortcut so it parallels
              // the single-action case — the most common log path is
              // one keystroke even when other options exist.
              ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
                Button {
                  onLog(action.id)
                } label: {
                  if let img = action.systemImage {
                    Label(action.title, systemImage: img)
                  } else {
                    Text(action.title)
                  }
                }
                .keyboardShortcut(idx == 0 ? KeyboardShortcut("n", modifiers: .command) : nil)
              }
            } label: {
              Image(systemName: "plus")
            }
            .tint(resolvedAccent)
          }
        }
      }
    }
  }
}

extension SectionDrawer {
  /// Standardized failed-state placeholder. Renders as a centered
  /// `ContentUnavailableView` with the destination's error message and
  /// a "Try again" button bound to `onRetry`. Drops in cleanly inside
  /// the drawer's LazyVStack so the goals strip + nav chrome stay
  /// untouched while the body recovers.
  @ViewBuilder
  fileprivate func failedView(_ message: String) -> some View {
    ContentUnavailableView {
      Label("Couldn't load", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      if let onRetry {
        Button("Try again") { onRetry() }
          .buttonStyle(.borderedProminent)
      }
    }
  }
}

#Preview("DrawerSection — padding modes") {
  ScrollView {
    VStack(spacing: 24) {
      DrawerSection("Standard") {
        VStack(alignment: .leading, spacing: 4) {
          Text("Free-form content").font(.septenaCardTitle)
          Text("Inset 14h / 12v from the rounded edge.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      DrawerSection("Tight (charts)", padding: .tight) {
        Rectangle().fill(.blue.opacity(0.35)).frame(height: 80)
      }
      DrawerSection("None (LogRow rows)", padding: .none) {
        ForEach(0..<3) { i in
          LogRow(title: "Row \(i + 1)", trailing: "0\(i):0\(i)")
        }
      }
    }
    .padding()
  }
  .background(Theme.groupedBackground)
}

/// Applies `.searchable` only when a binding is provided. SwiftUI
/// modifiers can't be applied conditionally inline without rebuilding
/// view identity on every render; this modifier branches once at
/// composition time and stays stable thereafter.
private struct OptionalSearchable: ViewModifier {
  let text: Binding<String>?
  let prompt: String

  func body(content: Content) -> some View {
    if let text {
      content.searchable(text: text, prompt: prompt)
    } else {
      content
    }
  }
}

// DrawerSection — titled, rounded, grouped block. Visual analogue of an
// insetGrouped List `Section("Title")`: secondary-grouped fill, rounded
// corners, an uppercase footnote header. Content is laid out as a VStack;
// inner views render at their natural height (no row insets to fight).

/// How a `DrawerSection` should inset its content from the rounded
/// card's edges. Most free-form content wants the `.standard` h14/v12
/// padding; row-stacks built from `LogEntryRow` (which carries its own
/// padding) use `.none`; charts use `.tight`.
enum DrawerPadding {
  case standard, tight, none
}

struct DrawerSection<Content: View>: View {
  let title: String?
  let spacing: CGFloat
  let padding: DrawerPadding
  @ViewBuilder var content: () -> Content

  init(_ title: String? = nil,
       spacing: CGFloat = Theme.Spacing.xs,
       padding: DrawerPadding = .standard,
       @ViewBuilder content: @escaping () -> Content) {
    // Default xs gap between rows so adjacent items breathe inside the
    // drawer card. Pass `spacing: 0` for tightly-packed stacks (charts,
    // dense stat grids) where the rounded card itself is the only frame
    // the contents need.
    self.title = title
    self.spacing = spacing
    self.padding = padding
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      if let title, !title.isEmpty {
        // Title-case subheadline with a soft secondary tint — matches
        // the look of the original Caffeine destination's section labels.
        Text(title)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.horizontal, Theme.Spacing.xl)
      }
      paddedStack
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .fill(Theme.secondaryGroupedBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
  }

  @ViewBuilder
  private var paddedStack: some View {
    let stack = VStack(spacing: spacing) { content() }
    switch padding {
    case .standard: stack.padding(.horizontal, Theme.Spacing.lg)
                         .padding(.vertical, Theme.Spacing.md)
    case .tight:    stack.padding(.horizontal, Theme.Spacing.md)
                         .padding(.vertical, Theme.Spacing.sm)
    case .none:     stack
    }
  }
}
