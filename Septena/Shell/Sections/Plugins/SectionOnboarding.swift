import SwiftUI

// When a section's onboarding sheet is presented as one step of the first-run
// welcome chain (rather than standalone from Settings), the welcome injects
// this so the shared scaffold can show "Step N of M" and a "Skip all" exit
// without the plugins knowing anything about the chain. Absent (nil) for a
// standalone sheet — then the chrome is exactly as before.
struct OnboardingChainContext {
  let step: Int          // 1-based position in the chain
  let total: Int
  let skipAll: () -> Void
}

private struct OnboardingChainKey: EnvironmentKey {
  static let defaultValue: OnboardingChainContext? = nil
}

extension EnvironmentValues {
  var onboardingChain: OnboardingChainContext? {
    get { self[OnboardingChainKey.self] }
    set { self[OnboardingChainKey.self] = newValue }
  }
}

// The ONE onboarding scaffold for every section's first-enable sheet. It
// replaced the two earlier scaffolds (an explainer-only one and a
// starter-picker one) that had drifted into different dismiss chrome. The
// content still varies — some sections only explain themselves, others offer
// a starter catalog to seed — but the chrome is now identical everywhere so
// the user never has to relearn the sheet:
//
//   • top-left "Close" dismisses (the iOS sheet convention), and
//   • ONE bottom primary button: "Add N <noun>" once starters are selected,
//     otherwise "Done".
//
// Grounded in the manifest, not re-passed: title, hero glyph and accent all
// resolve from `sectionKey` via `SectionManifest` / `SectionTheme`. Callers
// describe only what's section-specific:
//
//   • explainer sections → `bullets` (what the section does), nothing else;
//   • starter sections   → `groups` + how to render/dedupe a row + the write;
//   • a section may pass both — bullets render above the starters.
//
// Pure additive seeding: no deletes, no CloudKit schema. Closures run env-free
// (read via `MirrorReader.shared`, write via the section mutator off
// `SeptenaServices`) because `onboarding(complete:)` builds the view as a
// factory, before it has an `@Environment`.

/// Hero header for the onboarding sheet — accent-tinted section glyph (from
/// `SectionManifest.iconSymbol`), title, and a short intro, centered.
@MainActor
struct SectionOnboardingHero: View {
  let sectionKey: String
  let title: String
  let intro: String

  @Environment(SectionTheme.self) private var theme
  private var accent: Color { theme.color(for: sectionKey) }
  private var heroSymbol: String {
    SectionManifest.byKey[sectionKey]?.iconSymbol ?? "circle.fill"
  }

  var body: some View {
    VStack(spacing: 12) {
      ZStack {
        Circle()
          .fill(accent.opacity(0.15))
          .frame(width: 72, height: 72)
        Image(systemName: heroSymbol)
          .scaledFont(size: 32, weight: .semibold, relativeTo: .largeTitle)
          .foregroundStyle(accent)
      }
      .accessibilityHidden(true)

      Text(title)
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)

      Text(intro)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }
}

extension View {
  /// Row styling for the hero `Section` — clear background, no list insets.
  @MainActor
  func onboardingHeroSection() -> some View {
    self
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
  }
}

/// Leading glyph for a starter row: an emoji (habits, symptoms, chores,
/// supplements), an SF Symbol (intake, medications), or nothing (groceries,
/// training).
enum StarterGlyph {
  case emoji(String)
  case symbol(String)
  case none
}

/// One titled group of starters. Flat pickers pass a single group with a nil
/// header; Habits groups its starters by bucket into several.
struct StarterGroup<Item: Identifiable>: Identifiable {
  let id: String
  var header: String?
  var footer: String?
  var items: [Item]

  init(id: String = "default", header: String? = nil, footer: String? = nil, items: [Item]) {
    self.id = id
    self.header = header
    self.footer = footer
    self.items = items
  }
}

/// An explainer card: a lead, a body, and an optional SF Symbol.
struct OnboardingBullet: Identifiable {
  let id = UUID()
  let lead: String
  let body: String
  let icon: String?

  init(_ lead: String, _ body: String, icon: String? = nil) {
    self.lead = lead
    self.body = body
    self.icon = icon
  }
}

/// Placeholder element for explain-only onboardings (no starter catalog). Never
/// instantiated — it only satisfies the generic `Item` parameter.
struct NoStarter: Identifiable { let id = UUID() }

@MainActor
struct SectionOnboarding<Item: Identifiable, Extra: View>: View {
  let sectionKey: String
  let intro: String
  let bullets: [OnboardingBullet]
  /// Plural noun for the confirm button ("habits" → "Add 3 habits"). Empty →
  /// just "Add 3" (Intake, whose templates have no single shared noun).
  let nounPlural: String
  let groups: [StarterGroup<Item>]
  let glyph: (Item) -> StarterGlyph
  let primary: (Item) -> String
  let secondary: (Item) -> String?
  /// How a starter matches an already-existing row, compared against the set
  /// from `loadExistingKeys` (lowercased title/name, or a seed id).
  let existsKey: (Item) -> AnyHashable
  let loadExistingKeys: () async -> Set<AnyHashable>
  let add: ([Item]) -> Void
  let complete: () -> Void
  /// Escape hatch for bespoke rows (e.g. Intake's "Custom" wizard launcher),
  /// rendered as trailing Sections below the starter groups.
  @ViewBuilder let extraSections: () -> Extra

  @Environment(SectionTheme.self) private var theme
  /// Non-nil only while presented as a step of the first-run welcome chain.
  @Environment(\.onboardingChain) private var chain
  @State private var selected: Set<Item.ID> = []
  @State private var existing: Set<AnyHashable> = []

  private var accent: Color { theme.color(for: sectionKey) }
  private var title: String { SectionManifest.displayLabel(key: sectionKey, stored: "") }
  private var allItems: [Item] { groups.flatMap(\.items) }
  private func exists(_ item: Item) -> Bool { existing.contains(existsKey(item)) }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SectionOnboardingHero(sectionKey: sectionKey, title: title, intro: intro)
            .onboardingHeroSection()
        }

        ForEach(bullets) { bullet in
          Section { bulletRow(bullet) }
        }

        ForEach(groups) { group in
          Section {
            ForEach(group.items) { row($0) }
          } header: {
            if let header = group.header { Text(header) }
          } footer: {
            if let footer = group.footer { Text(footer) }
          }
        }

        extraSections()
      }
      .formStyle(.grouped)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      // In the welcome chain, the title carries the step counter and a
      // "Skip all" exits the remaining intros. Standalone, neither shows.
      .navigationTitle(chain.map { "Step \($0.step) of \($0.total)" } ?? "")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { complete() }
        }
        if let chain {
          ToolbarItem(placement: .primaryAction) {
            Button("Skip all") { chain.skipAll() }
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        Button(confirmTitle) { confirm() }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(accent)
          .frame(maxWidth: .infinity)
          .padding()
          .background(.bar)
      }
      .task { existing = await loadExistingKeys() }
    }
  }

  @ViewBuilder
  private func bulletRow(_ bullet: OnboardingBullet) -> some View {
    HStack(alignment: .top, spacing: 12) {
      if let icon = bullet.icon {
        Image(systemName: icon)
          .font(.title3)
          .foregroundStyle(accent)
          .frame(width: 28, alignment: .center)
          .padding(.top, 2)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(bullet.lead).font(.subheadline.weight(.semibold))
        Text(bullet.body).font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func row(_ item: Item) -> some View {
    let exists = exists(item)
    let isSelected = selected.contains(item.id)
    Button {
      guard !exists else { return }
      if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
    } label: {
      HStack(spacing: 12) {
        glyphView(glyph(item), dimmed: exists)
        VStack(alignment: .leading, spacing: 2) {
          Text(primary(item))
            .foregroundStyle(exists ? .secondary : .primary)
            .strikethrough(exists, color: .secondary)
          if let sub = secondary(item) {
            Text(sub).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        if exists {
          Text("Already added").font(.caption).foregroundStyle(.secondary)
        } else {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.6))
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(exists)
  }

  @ViewBuilder
  private func glyphView(_ glyph: StarterGlyph, dimmed: Bool) -> some View {
    switch glyph {
    case .emoji(let value):
      Text(value).font(.title3).opacity(dimmed ? 0.4 : 1)
    case .symbol(let name):
      Image(systemName: name)
        .font(.title3)
        .foregroundStyle(dimmed ? Color.secondary : accent)
        .frame(width: 28)
    case .none:
      EmptyView()
    }
  }

  private var confirmTitle: String {
    guard !selected.isEmpty else { return String(localized: "Done") }
    return nounPlural.isEmpty
      ? String(localized: "Add \(selected.count)")
      : String(localized: "Add \(selected.count) \(nounPlural)")
  }

  private func confirm() {
    // Re-filter against the existing set in case it changed while open (CK
    // sync, multi-device). Additive only — never overwrites an existing row.
    if !selected.isEmpty {
      add(allItems.filter { selected.contains($0.id) && !exists($0) })
    }
    complete()
  }
}

// Convenience inits so each call site stays terse. The explainer-only and the
// no-extra starter forms fix the generic parameters so callers never spell out
// `NoStarter` or `{ EmptyView() }`; only Intake reaches for the full init.
extension SectionOnboarding where Item == NoStarter, Extra == EmptyView {
  /// Explain-only onboarding: hero + bullet cards + a "Done" button.
  init(
    sectionKey: String,
    intro: String,
    bullets: [OnboardingBullet],
    complete: @escaping () -> Void
  ) {
    self.init(
      sectionKey: sectionKey, intro: intro, bullets: bullets, nounPlural: "",
      groups: [], glyph: { _ in .none }, primary: { _ in "" }, secondary: { _ in nil },
      existsKey: { _ in AnyHashable("") }, loadExistingKeys: { [] },
      add: { _ in }, complete: complete, extraSections: { EmptyView() }
    )
  }
}

extension SectionOnboarding where Extra == EmptyView {
  /// Flat single-group starter picker (the common case).
  init(
    sectionKey: String,
    intro: String,
    nounPlural: String,
    bullets: [OnboardingBullet] = [],
    header: String? = nil,
    footer: String? = nil,
    items: [Item],
    glyph: @escaping (Item) -> StarterGlyph = { _ in .none },
    primary: @escaping (Item) -> String,
    secondary: @escaping (Item) -> String? = { _ in nil },
    existsKey: @escaping (Item) -> AnyHashable,
    loadExistingKeys: @escaping () async -> Set<AnyHashable>,
    add: @escaping ([Item]) -> Void,
    complete: @escaping () -> Void
  ) {
    self.init(
      sectionKey: sectionKey, intro: intro, bullets: bullets, nounPlural: nounPlural,
      groups: [StarterGroup(header: header, footer: footer, items: items)],
      glyph: glyph, primary: primary, secondary: secondary,
      existsKey: existsKey, loadExistingKeys: loadExistingKeys,
      add: add, complete: complete, extraSections: { EmptyView() }
    )
  }

  /// Multi-group starter picker (Habits, by bucket).
  init(
    sectionKey: String,
    intro: String,
    nounPlural: String,
    bullets: [OnboardingBullet] = [],
    groups: [StarterGroup<Item>],
    glyph: @escaping (Item) -> StarterGlyph = { _ in .none },
    primary: @escaping (Item) -> String,
    secondary: @escaping (Item) -> String? = { _ in nil },
    existsKey: @escaping (Item) -> AnyHashable,
    loadExistingKeys: @escaping () async -> Set<AnyHashable>,
    add: @escaping ([Item]) -> Void,
    complete: @escaping () -> Void
  ) {
    self.init(
      sectionKey: sectionKey, intro: intro, bullets: bullets, nounPlural: nounPlural,
      groups: groups,
      glyph: glyph, primary: primary, secondary: secondary,
      existsKey: existsKey, loadExistingKeys: loadExistingKeys,
      add: add, complete: complete, extraSections: { EmptyView() }
    )
  }
}
