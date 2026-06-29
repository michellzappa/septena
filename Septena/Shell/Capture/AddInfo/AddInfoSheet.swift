import SwiftUI

// Unified quick-add palette. Port of the webapp's ⌘K command palette (one
// entry point, ten section pages). Triggered by long-pressing the FAB on
// iPhone / iPad or ⌘K on a hardware keyboard.

struct AddInfoSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(SectionTheme.self) private var theme
  @Environment(NavigationState.self) private var nav

  @State private var router = AddInfoRouter()
  let initialSection: AddInfoSection?

  var body: some View {
    NavigationStack {
      Group {
        if let page = router.page {
          pageView(for: page)
        } else {
          RootView(router: router)
        }
      }
      .navigationTitle(router.page?.title ?? "Add")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        // TODO(backlog): restore root navigation when AddInfoSheet is repurposed as a
        // universal creation palette — for now it is always launched directly on a
        // section page and has no root to pop back to.
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      #if os(iOS)
      .searchable(text: $router.query,
                  placement: .navigationBarDrawer(displayMode: .always),
                  prompt: router.page?.placeholder ?? "Start, log, or add…")
      #else
      .searchable(text: $router.query,
                  prompt: router.page?.placeholder ?? "Start, log, or add…")
      #endif
    }
    .onAppear {
      if let s = initialSection, router.page == nil {
        router.push(s)
      }
    }
    .environment(router)
  }

  @ViewBuilder
  private func pageView(for page: AddInfoSection) -> some View {
    switch page {
    case .tasks:       AddTaskPage(router: router)
    case .groceries:   AddGroceryPage(router: router)
    case .habits:      AddHabitPage(router: router)
    case .supplements: AddSupplementPage(router: router)
    case .chores:      AddChorePage(router: router)
    case .nutrition:   AddNutritionPage(router: router)
    case .gut:         AddGutPage(router: router)
    case .training:    AddTrainingPage(router: router)
    }
  }
}

// MARK: - Root list

private struct RootView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(DayClock.self) private var clock
  @Environment(SectionTheme.self) private var theme
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(NavigationState.self) private var nav
  @Bindable var router: AddInfoRouter

  @State private var intakeTiles: [IntakeTileDTO] = []

  private var entries: [AddInfoPaletteEntry] {
    AddInfoPalette.entries(
      sections: settingsStore.sections,
      intakeTiles: intakeTiles,
      mirroredFallback: SettingsMirror.loadSections(context: modelContext)
    )
  }

  var body: some View {
    List {
      Section("Log or add") {
        ForEach(entries) { entry in
          Button {
            select(entry)
          } label: {
            AddInfoRow(
              title: entry.title,
              systemImage: entry.iconSymbol,
              tint: AddInfoPalette.accent(for: entry, theme: theme),
              accessory: .chevron
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #else
    .listStyle(.inset)
    #endif
    .task { loadIntakeTiles() }
  }

  private func loadIntakeTiles() {
    intakeTiles = IntakeReader.loadTiles(context: modelContext, date: clock.today)
  }

  private func select(_ entry: AddInfoPaletteEntry) {
    switch entry.destination {
    case .addInfoPage(let section):
      router.push(section)
    case .moodCheckin:
      dismiss()
      nav.showMoodCheckin = true
    case .presentSection(let key):
      dismiss()
      nav.presentSection(key: key)
    case .intakeKind(let id):
      dismiss()
      nav.presentIntakeKind(id)
    }
  }
}
