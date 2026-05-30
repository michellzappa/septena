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
  private var reviewStep: Int { quadrantSteps.count + 1 }
  private var resultStep: Int { quadrantSteps.count + 2 }
  private var totalSteps: Int { quadrantSteps.count + 3 }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        DiscoveryStepPills(current: step, total: totalSteps, accent: IkigaiMiniApp.accent)
          .padding(.top, 12)

        content
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if step > 0 { navigationControls }
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
          step = resultStep
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
    } else if step == reviewStep {
      overview
    } else {
      result
    }
  }

  private var intro: some View {
    VStack(alignment: .leading, spacing: 18) {
      Spacer(minLength: 20)

      IkigaiSplashGraphic()
        .frame(maxWidth: .infinity)

      VStack(alignment: .leading, spacing: 10) {
        Text("Turn a reflection into goals")
          .font(.largeTitle.weight(.bold))
        Text("Fill four short quadrants. Septena uses the on-device model to draft a north-star goal and commitments you can save into Goals.")
          .font(.body)
          .foregroundStyle(.secondary)
      }

      Spacer()

      DiscoveryPrimaryAction(title: "Begin",
                             systemImage: "arrow.right",
                             accent: IkigaiMiniApp.accent) {
        step = 1
        Haptics.tick()
      }
    }
    .padding()
  }

  private struct IkigaiSplashGraphic: View {
    var body: some View {
      ZStack {
        circle(color: .pink)
          .offset(y: -58)
        circle(color: .blue)
          .offset(x: 58)
        circle(color: .orange)
          .offset(x: -58)
        circle(color: .green)
          .offset(y: 58)

        symbol("heart.fill", color: .pink)
          .offset(y: -128)
        symbol("hammer.fill", color: .blue)
          .offset(x: 128)
        symbol("globe.europe.africa", color: .orange)
          .offset(x: -128)
        symbol("banknote", color: .green)
          .offset(y: 128)

        Image(systemName: "flame.fill")
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(IkigaiMiniApp.accent)
      }
      .frame(height: 300)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Four-part purpose map")
    }

    private func circle(color: Color) -> some View {
      Circle()
        .stroke(color.opacity(0.72), lineWidth: 2)
        .frame(width: 190, height: 190)
    }

    private func symbol(_ name: String, color: Color) -> some View {
      Image(systemName: name)
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(color)
    }
  }

  private var overview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Synthesize your map")
            .font(.title2.weight(.semibold))
          Text("These four groups are the raw material for the north-star and commitments.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
          ForEach(IkigaiQuadrant.allCases) { quadrant in
            overviewCard(for: quadrant)
          }
        }

        if case .generating = model.phase {
          Label(model.generationMessage ?? "Generating on device...", systemImage: "wand.and.stars")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if case let .failed(message) = model.phase {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        DiscoveryPrimaryAction(
          title: model.drafts.isEmpty ? "Generate Goals" : "Regenerate Goals",
          systemImage: "wand.and.stars",
          accent: IkigaiMiniApp.accent,
          disabled: !model.canGenerate || isGenerating
        ) {
          Haptics.aiGeneration()
          Task { await model.generateDrafts(availableSections: availableSections) }
        }

        if !model.drafts.isEmpty {
          DiscoverySecondaryAction(title: "Review Existing Drafts",
                                   systemImage: "doc.text.magnifyingglass",
                                   accent: IkigaiMiniApp.accent) {
            showReview = true
          }
        }
      }
      .padding()
    }
  }

  private var result: some View {
    DiscoveryResultView(
      title: "Purpose Drafted",
      subtitle: "Here is the synthesis before it becomes saved Goals.",
      drafts: model.drafts,
      accent: IkigaiMiniApp.accent,
      onReview: { showReview = true },
      onRegenerate: {
        step = reviewStep
        Haptics.aiGeneration()
        Task { await model.generateDrafts(availableSections: availableSections) }
      }
    )
  }

  private var navigationControls: some View {
    DiscoveryBottomBar(
      accent: IkigaiMiniApp.accent,
      primaryTitle: step <= quadrantSteps.count ? (step == quadrantSteps.count ? "Synthesize Map" : "Keep These") : nil,
      primarySystemImage: step == quadrantSteps.count ? "checkmark" : "chevron.right",
      primaryDisabled: step <= quadrantSteps.count && selection(for: quadrantSteps[step - 1]).isEmpty,
      backDisabled: isGenerating,
      onBack: {
        step = max(0, step - 1)
        Haptics.tick()
      },
      onPrimary: {
        if step <= quadrantSteps.count {
          step = min(resultStep, step + 1)
          Haptics.tick()
        }
      }
    )
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
