import SwiftData
import SwiftUI

// Examined Week — the third Discovery mini app. Unlike Ikigai / Values
// (which generate goals from what you self-report), this one runs
// backward: it reads the last 7 days of LOGGED data and reflects it
// against the four cardinal virtues. Read-only by design — it produces no
// DraftGoals, so `onFinish` is always called with `[]`.

enum VirtueMiniApp: DiscoveryMiniApp {
  static let id = "virtue"
  static let title = "Examined Week"
  static let blurb = "See your last 7 days reflected against temperance, wisdom, courage, and justice."
  static let systemImage = "building.columns"
  static let accent = Color.indigo

  static func makeView(onFinish: @escaping ([DraftGoal]) -> Void) -> AnyView {
    AnyView(VirtueFlowView(onFinish: onFinish))
  }
}

@MainActor
@Observable
final class VirtueViewModel {
  enum Phase: Equatable {
    case intro
    case gathering
    case generating
    case ready
    case failed(String)
  }

  var phase: Phase = .intro
  var summary: VirtueWeekSummary?
  var readings: [VirtueReading] = []

  private let service = VirtuePromptService()

  func run(context: ModelContext) async {
    phase = .gathering
    let summary = VirtueSummarizer.summarize(context: context)
    self.summary = summary

    guard OnDeviceAI.isAvailable else {
      readings = service.fallbackReadings(summary: summary)
      phase = .ready
      return
    }

    phase = .generating
    do {
      readings = try await service.generateReadings(summary: summary)
      phase = .ready
      Haptics.success()
    } catch {
      readings = service.fallbackReadings(summary: summary)
      phase = .failed("The on-device model couldn't finish, so here's the plain summary.")
      Haptics.warning()
    }
  }
}

struct VirtueFlowView: View {
  @Environment(\.modelContext) private var context

  let onFinish: ([DraftGoal]) -> Void

  @State private var model = VirtueViewModel()
  @State private var step = 0   // 0 = intro, 1 = reflection

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        DiscoveryStepPills(current: step, total: 2, accent: VirtueMiniApp.accent)
          .padding(.top, 12)
        content
      }
      .navigationTitle("Examined Week")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { onFinish([]) }
        }
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if step == 0 {
      intro
    } else {
      reflection
    }
  }

  // MARK: - Intro

  private var intro: some View {
    VStack(alignment: .leading, spacing: 18) {
      Spacer(minLength: 20)

      Image(systemName: "building.columns")
        .scaledFont(size: 54, weight: .semibold, relativeTo: .largeTitle)
        .foregroundStyle(VirtueMiniApp.accent)
        .frame(maxWidth: .infinity)

      VStack(alignment: .leading, spacing: 10) {
        Text("Hold the week up to the light")
          .font(.largeTitle.weight(.bold))
        Text("Septena summarizes your last 7 days of logs (on device, nothing leaves your phone) and reflects them against four cardinal virtues. A mirror, not a scorecard.")
          .font(.body)
          .foregroundStyle(.secondary)
      }

      Spacer()

      DiscoveryPrimaryAction(title: "Examine my week",
                             systemImage: "sparkle.magnifyingglass",
                             accent: VirtueMiniApp.accent) {
        step = 1
        Haptics.aiGeneration()
        Task { await model.run(context: context) }
      }
    }
    .padding()
  }

  // MARK: - Reflection

  private var reflection: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let summary = model.summary {
          Text(summary.rangeLabel)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        }

        switch model.phase {
        case .gathering:
          progressRow("Gathering your week…")
        case .generating:
          progressRow("Reflecting on device…")
        case .failed(let message):
          Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.secondary)
        default:
          EmptyView()
        }

        ForEach(model.readings) { reading in
          card(for: reading)
        }

        if let summary = model.summary, model.phase == .ready || isFailed {
          footer(for: summary)
        }
      }
      .padding()
    }
  }

  private func progressRow(_ label: String) -> some View {
    HStack(spacing: 10) {
      ProgressView()
      Text(label)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }

  private func card(for reading: VirtueReading) -> some View {
    let signals = model.summary?.bundle(for: reading.virtue).signals ?? []
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(reading.virtue.title, systemImage: reading.virtue.systemImage)
          .font(.headline)
          .foregroundStyle(VirtueMiniApp.accent)
        Spacer()
        Text(reading.status.label)
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 9)
          .padding(.vertical, 4)
          .background(reading.status.color.opacity(0.16), in: Capsule())
          .foregroundStyle(reading.status.color)
      }

      Text(reading.virtue.gloss)
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(reading.read)
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)

      if reading.tension != "—" {
        VStack(alignment: .leading, spacing: 2) {
          Text("Tension")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
          Text(reading.tension)
            .font(.subheadline)
            .italic()
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if !signals.isEmpty {
        DisclosureGroup {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(signals, id: \.text) { signal in
              HStack(alignment: .top, spacing: 8) {
                Circle()
                  .fill(valenceColor(signal.valence))
                  .frame(width: 6, height: 6)
                  .padding(.top, 6)
                Text(signal.text)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          .padding(.top, 6)
        } label: {
          Text("Based on \(signals.count) signals")
            .font(.caption.weight(.medium))
            .foregroundStyle(VirtueMiniApp.accent)
        }
        .tint(VirtueMiniApp.accent)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.secondaryGroupedBackground,
                in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
  }

  private func footer(for summary: VirtueWeekSummary) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("Local and on-device. Nothing left your phone.", systemImage: "lock.fill")
      Text("Summarized from \(summary.sectionsWithData.count) sections.")
      if !summary.sectionsMissing.isEmpty {
        Text("No data this run: \(summary.sectionsMissing.joined(separator: ", ")).")
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 4)
  }

  private var isFailed: Bool {
    if case .failed = model.phase { return true }
    return false
  }

  private func valenceColor(_ valence: Valence) -> Color {
    switch valence {
    case .good:    return .green
    case .strain:  return .red
    case .neutral: return .secondary
    }
  }
}
