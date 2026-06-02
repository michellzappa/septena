import SwiftData
import SwiftUI

struct ValuesFlowView: View {
  @Environment(\.modelContext) private var context

  let onFinish: ([DraftGoal]) -> Void

  @State private var model = ValuesViewModel()
  @State private var step = 0
  @State private var showReview = false
  @State private var availableSections: [SectionConfig] = []

  private var resultStep: Int { 3 }
  private var totalSteps: Int { 4 }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        DiscoveryStepPills(current: step, total: totalSteps, accent: ValuesMiniApp.accent)
          .padding(.top, 12)

        content
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if step > 0 { navigationControls }
      }
      .navigationTitle("Values")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { onFinish([]) }
        }
      }
      .task {
        availableSections = SettingsMirror.loadSections(context: context)
          .filter { $0.key != "goals" }
      }
      .navigationDestination(isPresented: $showReview) {
        ReviewAndSaveView(
          drafts: model.drafts,
          availableSections: availableSections,
          onSave: onFinish
        )
      }
      .onChange(of: model.phase) { _, phase in
        if phase == .ready || isRecoverableFailure(phase) {
          step = resultStep
        }
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch step {
    case 0:
      intro
    case 1:
      valuesSelection
    case 2:
      reviewInputs
    default:
      result
    }
  }

  private var intro: some View {
    VStack(alignment: .leading, spacing: 18) {
      Spacer(minLength: 20)

      ValuesSplashGraphic()
        .frame(maxWidth: .infinity)

      VStack(alignment: .leading, spacing: 10) {
        Text("Turn values into goals")
          .font(.largeTitle.weight(.bold))
        Text("Choose the principles you want to live by. Septena drafts a north-star and commitments you can save into Goals.")
          .font(.body)
          .foregroundStyle(.secondary)
      }

      Spacer()

      DiscoveryPrimaryAction(title: "Begin",
                             systemImage: "arrow.right",
                             accent: ValuesMiniApp.accent) {
        step = 1
        Haptics.tick()
      }
    }
    .padding()
  }

  private var valuesSelection: some View {
    ValuesSelectionStep(selectedValues: $model.selectedValues,
                        customValues: model.customValues,
                        onAddCustom: model.addCustom)
  }

  private var reviewInputs: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Review your values")
            .font(.title2.weight(.semibold))
          Text("This is the focused set Septena will turn into a north-star and commitments.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        FlowLayout(spacing: 8) {
          ForEach(model.sortedValues, id: \.self) { value in
            Text(value)
              .font(.caption.weight(.medium))
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(ValuesMiniApp.accent.opacity(0.13))
              .foregroundStyle(ValuesMiniApp.accent)
              .clipShape(Capsule())
          }
        }

        TextField("Optional context", text: $model.note, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(3...5)

        if case .generating = model.phase {
          Label(model.generationMessage ?? "Generating on device...", systemImage: "wand.and.stars")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        if case let .failed(message) = model.phase {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        DiscoveryPrimaryAction(
          title: model.drafts.isEmpty ? "Generate Goals" : "Regenerate Goals",
          systemImage: "wand.and.stars",
          accent: ValuesMiniApp.accent,
          disabled: !model.canGenerate || isGenerating
        ) {
          Haptics.aiGeneration()
          Task { await model.generateDrafts(availableSections: availableSections) }
        }

        if !model.drafts.isEmpty {
          DiscoverySecondaryAction(title: "Review Existing Drafts",
                                   systemImage: "doc.text.magnifyingglass",
                                   accent: ValuesMiniApp.accent) {
            showReview = true
          }
        }
      }
      .padding()
    }
  }

  private var result: some View {
    DiscoveryResultView(
      title: "Values Drafted",
      subtitle: "Here is the synthesis before it becomes saved Goals.",
      drafts: model.drafts,
      accent: ValuesMiniApp.accent,
      onReview: { showReview = true },
      onRegenerate: {
        step = 2
        Haptics.aiGeneration()
        Task { await model.generateDrafts(availableSections: availableSections) }
      }
    )
  }

  private var navigationControls: some View {
    DiscoveryBottomBar(
      accent: ValuesMiniApp.accent,
      primaryTitle: step < resultStep ? (step == 1 ? "Review Values" : nil) : nil,
      primarySystemImage: "checkmark",
      primaryDisabled: model.selectedValues.count < 3,
      backDisabled: isGenerating,
      onBack: {
        step = max(0, step - 1)
        Haptics.tick()
      },
      onPrimary: {
        if step < resultStep {
          step = min(resultStep, step + 1)
          Haptics.tick()
        }
      }
    )
  }

  private var isGenerating: Bool {
    if case .generating = model.phase { return true }
    return false
  }

  private func isRecoverableFailure(_ phase: ValuesViewModel.Phase) -> Bool {
    if case .failed = phase, !model.drafts.isEmpty { return true }
    return false
  }
}

private struct ValuesSplashGraphic: View {
  var body: some View {
    ZStack {
      ForEach(0..<4) { index in
        let angle = Double(index) * 90
        Capsule()
          .fill(color(for: index).opacity(0.12))
          .frame(width: 112, height: 74)
          .overlay {
            Image(systemName: symbol(for: index))
              .scaledFont(size: 24, weight: .semibold)
              .foregroundStyle(color(for: index))
          }
          .offset(x: 72 * cos(angle * .pi / 180),
                  y: 72 * sin(angle * .pi / 180))
      }

      Image(systemName: "star.circle.fill")
        .scaledFont(size: 36, weight: .semibold, relativeTo: .largeTitle)
        .foregroundStyle(ValuesMiniApp.accent)
        .frame(width: 76, height: 76)
        .background(.regularMaterial, in: Circle())
        .overlay {
          Circle()
            .stroke(ValuesMiniApp.accent.opacity(0.25), lineWidth: 1)
        }
    }
    .frame(height: 220)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Values compass")
  }

  private func symbol(for index: Int) -> String {
    switch index {
    case 0: return "person.fill"
    case 1: return "heart.fill"
    case 2: return "leaf.fill"
    default: return "briefcase.fill"
    }
  }

  private func color(for index: Int) -> Color {
    switch index {
    case 0: return .blue
    case 1: return .pink
    case 2: return .mint
    default: return .orange
    }
  }
}
