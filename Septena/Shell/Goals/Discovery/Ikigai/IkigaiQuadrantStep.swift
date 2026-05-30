import SwiftUI

enum IkigaiQuadrant: String, CaseIterable, Identifiable {
  case love
  case identity
  case value
  case world

  var id: String { key }
  var key: String { rawValue }

  var title: String {
    switch self {
    case .love:
      return "What do you love?"
    case .identity:
      return "What are you good at?"
    case .value:
      return "What can you be paid for?"
    case .world:
      return "What does the world need?"
    }
  }

  var subtitle: String {
    switch self {
    case .love:
      return "Activities, topics, and moments that consistently pull you in."
    case .identity:
      return "Skills, traits, and strengths other people rely on you for."
    case .value:
      return "Capabilities that could become offers, services, products, or roles."
    case .world:
      return "Needs, communities, or problems you feel responsible to support."
    }
  }

  var symbol: String {
    switch self {
    case .love:
      return "heart"
    case .identity:
      return "person.badge.shield.checkmark"
    case .value:
      return "banknote"
    case .world:
      return "globe.europe.africa"
    }
  }

  var accent: Color {
    switch self {
    case .love:
      return .pink
    case .identity:
      return .blue
    case .value:
      return .green
    case .world:
      return .orange
    }
  }
}

struct IkigaiQuadrantStep: View {
  let quadrant: IkigaiQuadrant
  let suggestions: [String]
  let selectedItems: Binding<Set<String>>
  let onAddCustom: (String) -> Void
  let onSuggestMore: () async -> Void

  @State private var customText = ""
  @State private var suggesting = false
  @State private var hiddenAfterExpansion: Set<String> = []

  private var visibleSuggestions: [String] {
    suggestions.filter { item in
      selectedItems.wrappedValue.contains(item) || !hiddenAfterExpansion.contains(item)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        Label(quadrant.title, systemImage: quadrant.symbol)
          .font(.title2.weight(.semibold))
          .foregroundStyle(quadrant.accent)
        Text(quadrant.subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      SelectablePillsView(
        items: visibleSuggestions,
        selectedItems: selectedItems,
        tint: quadrant.accent
      ) { _ in
        Haptics.tick()
      }

      HStack(spacing: 10) {
        TextField("Add your own", text: $customText)
          .textFieldStyle(.roundedBorder)
          .onSubmit(addCustom)
        Button("Add", action: addCustom)
          .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      Button {
        Task {
          let selected = selectedItems.wrappedValue
          hiddenAfterExpansion.formUnion(suggestions.filter { !selected.contains($0) })
          Haptics.aiGeneration()
          suggesting = true
          await onSuggestMore()
          suggesting = false
        }
      } label: {
        if suggesting {
          ProgressView()
        } else {
          Label("Suggest more", systemImage: "sparkles")
        }
      }
      .buttonStyle(.bordered)
      .tint(quadrant.accent)

      Spacer(minLength: 0)
    }
    .padding()
  }

  private func addCustom() {
    onAddCustom(customText)
    customText = ""
    Haptics.tick()
  }
}
