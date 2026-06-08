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
      return String(localized: "What do you love?", comment: "Ikigai prompt")
    case .identity:
      return String(localized: "What are you good at?", comment: "Ikigai prompt")
    case .value:
      return String(localized: "What can you be paid for?", comment: "Ikigai prompt")
    case .world:
      return String(localized: "What does the world need?", comment: "Ikigai prompt")
    }
  }

  var subtitle: String {
    switch self {
    case .love:
      return String(localized: "Activities, topics, and moments that consistently pull you in.", comment: "Ikigai prompt subtitle")
    case .identity:
      return String(localized: "Skills, traits, and strengths other people rely on you for.", comment: "Ikigai prompt subtitle")
    case .value:
      return String(localized: "Capabilities that could become offers, services, products, or roles.", comment: "Ikigai prompt subtitle")
    case .world:
      return String(localized: "Needs, communities, or problems you feel responsible to support.", comment: "Ikigai prompt subtitle")
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
        Text("\(quadrant.subtitle) Choose 2-4.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      SelectablePillsView(
        items: visibleSuggestions,
        selectedItems: selectedItems,
        tint: quadrant.accent,
        maxSelections: 4
      ) { _ in
        Haptics.tick()
      }

      DiscoveryPillTextInput(placeholder: "Add your own",
                             text: $customText,
                             accent: quadrant.accent,
                             onSubmit: addCustom)

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
        HStack(spacing: 8) {
          if suggesting {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "wand.and.stars")
          }
          Text(suggesting ? "Suggesting..." : "Suggest More")
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      .buttonStyle(.plain)
      .foregroundStyle(suggesting ? .secondary : quadrant.accent)
      .background(quadrant.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(quadrant.accent.opacity(0.28), lineWidth: 1)
      }
      .disabled(suggesting)

      Spacer(minLength: 0)
    }
    .padding()
  }

  private func addCustom() {
    guard selectedItems.wrappedValue.count < 4 else {
      Haptics.warning()
      customText = ""
      return
    }
    onAddCustom(customText)
    customText = ""
    Haptics.tick()
  }
}
