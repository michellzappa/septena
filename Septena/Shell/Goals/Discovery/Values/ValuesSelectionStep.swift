import SwiftUI

struct ValuesSelectionStep: View {
  @Binding var selectedValues: Set<String>
  let customValues: [String]
  let onAddCustom: (String) -> Void

  @State private var customText = ""

  private var allCustomValues: [String] {
    customValues.filter { value in
      !ValuesSuggestions.all.contains(value)
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Choose your values")
            .font(.title2.weight(.semibold))
          Text("Pick 3-7. A tighter set makes better goals.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        ForEach(ValuesSuggestions.categories, id: \.key) { category in
          VStack(alignment: .leading, spacing: 10) {
            Label(category.title, systemImage: icon(for: category.key))
              .font(.headline)
              .foregroundStyle(color(for: category.key))

            SelectablePillsView(
              items: category.values,
              selectedItems: $selectedValues,
              tint: color(for: category.key),
              maxSelections: 7
            ) { _ in
              Haptics.tick()
            }
          }
        }

        if !allCustomValues.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            Label("Added by you", systemImage: "plus.circle")
              .font(.headline)
              .foregroundStyle(ValuesMiniApp.accent)

            SelectablePillsView(
              items: allCustomValues,
              selectedItems: $selectedValues,
              tint: ValuesMiniApp.accent,
              maxSelections: 7
            ) { _ in
              Haptics.tick()
            }
          }
        }

        DiscoveryPillTextInput(placeholder: "Add your own",
                               text: $customText,
                               accent: ValuesMiniApp.accent,
                               onSubmit: addCustom)
      }
      .padding()
    }
  }

  private func addCustom() {
    guard selectedValues.count < 7 else {
      Haptics.warning()
      customText = ""
      return
    }
    onAddCustom(customText)
    customText = ""
    Haptics.tick()
  }

  private func icon(for key: String) -> String {
    switch key {
    case "personal": return "person.fill"
    case "relational": return "heart.fill"
    case "ethical": return "leaf.fill"
    default: return "briefcase.fill"
    }
  }

  private func color(for key: String) -> Color {
    switch key {
    case "personal": return .blue
    case "relational": return .pink
    case "ethical": return .mint
    default: return .orange
    }
  }
}
