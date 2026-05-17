import SwiftUI

// Unified quick-add palette. Port of the webapp's ⌘K command palette (one
// entry point, ten section pages). Triggered by long-pressing the FAB on
// iPhone / iPad or ⌘K on a hardware keyboard.

struct AddInfoSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(SeptenaClient.self) private var client
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
        ToolbarItem(placement: .cancellationAction) {
          if router.page != nil {
            Button { router.pop() } label: {
              Label("Back", systemImage: "chevron.left")
            }
          } else {
            Button("Cancel") { dismiss() }
          }
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
    case .caffeine:    AddCaffeinePage(router: router)
    case .cannabis:    AddCannabisPage(router: router)
    case .gut:         AddGutPage(router: router)
    case .training:    AddTrainingPage(router: router)
    }
  }
}

// MARK: - Root list

private struct RootView: View {
  @Environment(SectionTheme.self) private var theme
  @Bindable var router: AddInfoRouter

  var body: some View {
    List {
      Section("Actions") {
        ForEach(AddInfoSection.actionOrder) { section in
          Button {
            router.push(section)
          } label: {
            AddInfoRow(
              title: section.title,
              systemImage: section.systemImage,
              tint: section.accent(theme: theme),
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
  }
}
