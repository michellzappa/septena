#if os(macOS)
import AppKit
import SwiftData

// Checklist add-field suggestions in the AppKit composer (#860,
// docs/PROJECT_CHECKLIST_SPEC.md). The same block as the SwiftUI composer's
// `checklistSuggestionList`: the core's matches for the typed title, then
// Add "…". Drawn with the composer's reference chips.

@MainActor
final class KitChecklistSuggestionsView: NSView {
  private let stack = NSStackView()
  private var shown: [String] = []
  private(set) var isEmpty = true
  /// The content's height, for the composer's own layout.
  var preferredHeight: CGFloat { isEmpty ? 0 : ceil(stack.fittingSize.height) }
  /// A click on a checked row: reopen it.
  var onReopen: ((String) -> Void)?
  /// A click on Add "…": add the typed text as a new row.
  var onAdd: (() -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitChecklistSuggestionsView is code-only") }

  /// Rebuilds for `title` in `project`; nil clears the block.
  func reload(project: String?, title: String, in context: ModelContext) {
    let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let project, !typed.isEmpty else {
      apply([], typed: "")
      return
    }
    apply(ProjectChecklist.suggestions(project: project, query: typed, in: context), typed: typed)
  }

  private func apply(_ suggestions: [ProjectChecklist.Suggestion], typed: String) {
    let key = suggestions.map(\.label) + [typed]
    guard key != shown else { return }
    shown = key
    isEmpty = typed.isEmpty
    var views: [NSView] = suggestions.map { suggestion in
      if suggestion.isChecked {
        let id = suggestion.task.id
        return KitReferenceChipButton(title: suggestion.label, symbol: "arrow.uturn.backward", isDashed: false,
                                      label: suggestion.label) { [weak self] in self?.onReopen?(id) }
      }
      let label = NSTextField(labelWithString: suggestion.label)
      label.font = SeptaskKitTheme.chip
      label.textColor = SeptaskKitTheme.inkSecondary
      return label
    }
    if !typed.isEmpty {
      let add = RegistrySurfaces.checklistAddTyped(title: typed)
      views.append(KitReferenceChipButton(title: add, symbol: "plus", isDashed: true,
                                          label: add) { [weak self] in self?.onAdd?() })
    }
    stack.kitReplaceArrangedSubviews(with: views, fillsWidth: false)
    setAccessibilityLabel(RegistrySurfaces.checklistAddItem)
    isHidden = isEmpty
  }
}
#endif
