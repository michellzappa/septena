import SwiftData
import SwiftUI

struct IkigaiFlowView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context

  let onFinish: ([DraftGoal]) -> Void

  @State private var model = IkigaiViewModel()
  @State private var step = 0
  @State private var showReview = false
  @State private var availableSections: [SectionConfig] = []

  private var quadrantSteps: [IkigaiQuadrant] { IkigaiQuadrant.allCases }
  private var totalSteps: Int { quadrantSteps.count + 2 }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ProgressView(value: Double(step + 1), total: Double(totalSteps))
          .tint(IkigaiMiniApp.accent)
          .padding(.horizontal)
          .padding(.top)

        content

        if step > 0 {
          navigationControls
        }
      }
      .navigationTitle("Purpose")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            onFinish([])
          }
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
          showReview = true
        }
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if step == 0 {
      intro
    } else if step <= quadrantSteps.count {
      let quadrant = quadrantSteps[step - 1]
      IkigaiQuadrantStep(
        quadrant: quadrant,
        suggestions: model.suggestions[quadrant.key] ?? [],
        selectedItems: binding(for: quadrant),
        onAddCustom: { model.addCustom($0, to: quadrant) },
        onSuggestMore: { await model.refreshSuggestions(for: quadrant) }
      )
    } else {
      overview
    }
  }

  private var intro: some View {
    VStack(alignment: .leading, spacing: 18) {
      Spacer(minLength: 20)

      Image(systemName: IkigaiMiniApp.systemImage)
        .font(.largeTitle.weight(.semibold))
        .foregroundStyle(IkigaiMiniApp.accent)
        .frame(width: 64, height: 64)
        .background(IkigaiMiniApp.accent.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

      VStack(alignment: .leading, spacing: 10) {
        Text("Turn a reflection into goals")
          .font(.largeTitle.weight(.bold))
        Text("Fill four short quadrants. Septena uses the on-device model to draft a north-star goal and commitments you can save into Goals.")
          .font(.body)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        step = 1
        Haptics.tick()
      } label: {
        Text("Begin")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(IkigaiMiniApp.accent)
    }
    .padding()
  }

  private var overview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Review your inputs")
            .font(.title2.weight(.semibold))
          Text("Generation starts only after each quadrant has at least one selection.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
          ForEach(IkigaiQuadrant.allCases) { quadrant in
            overviewCard(for: quadrant)
          }
        }

        if case .generating = model.phase {
          Label("Generating purpose and commitments on device...", systemImage: "sparkles")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if case let .failed(message) = model.phase {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Button {
          Haptics.aiGeneration()
          Task { await model.generateDrafts(availableSections: availableSections) }
        } label: {
          if case .generating = model.phase {
            ProgressView()
              .frame(maxWidth: .infinity)
          } else {
            Text(model.drafts.isEmpty ? "Generate Goals" : "Regenerate Goals")
              .frame(maxWidth: .infinity)
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(IkigaiMiniApp.accent)
        .disabled(!model.canGenerate || isGenerating)

        if !model.drafts.isEmpty {
          Button {
            showReview = true
          } label: {
            Text("Review Existing Drafts")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.large)
        }
      }
      .padding()
    }
  }

  private var navigationControls: some View {
    HStack(spacing: 12) {
      Button("Back") {
        step = max(0, step - 1)
        Haptics.tick()
      }
      .buttonStyle(.bordered)
      .disabled(isGenerating)

      if step <= quadrantSteps.count {
        Button {
          step = min(totalSteps - 1, step + 1)
          Haptics.tick()
        } label: {
          Text(step == quadrantSteps.count ? "Review Inputs" : "Next")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(IkigaiMiniApp.accent)
      }
    }
    .padding()
    .background(.bar)
  }

  private func overviewCard(for quadrant: IkigaiQuadrant) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(quadrant.title, systemImage: quadrant.symbol)
        .font(.headline)
        .foregroundStyle(quadrant.accent)

      let selections = Array(selection(for: quadrant)).sorted()
      if selections.isEmpty {
        Text("No selections yet")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        FlowLayout(spacing: 6) {
          ForEach(selections, id: \.self) { item in
            Text(item)
              .font(.caption.weight(.medium))
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(quadrant.accent.opacity(0.14))
              .foregroundStyle(quadrant.accent)
              .clipShape(Capsule())
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.secondaryGroupedBackground)
    )
  }

  private var isGenerating: Bool {
    if case .generating = model.phase { return true }
    return false
  }

  private func isRecoverableFailure(_ phase: IkigaiViewModel.Phase) -> Bool {
    if case .failed = phase, !model.drafts.isEmpty { return true }
    return false
  }

  private func selection(for quadrant: IkigaiQuadrant) -> Set<String> {
    switch quadrant {
    case .love:
      return model.love
    case .identity:
      return model.identity
    case .value:
      return model.value
    case .world:
      return model.world
    }
  }

  private func binding(for quadrant: IkigaiQuadrant) -> Binding<Set<String>> {
    Binding(
      get: { selection(for: quadrant) },
      set: { newValue in
        switch quadrant {
        case .love:
          model.love = newValue
        case .identity:
          model.identity = newValue
        case .value:
          model.value = newValue
        case .world:
          model.world = newValue
        }
      }
    )
  }
}
