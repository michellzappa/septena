import SwiftUI

// The per-coach voice editor. The SAME four dials for every coach; the Custom
// coach also gets a free-text note. Hosted by AdaptiveEditScaffold so it docks
// as an inspector on iPad/macOS and a sheet on iPhone. Saving writes to
// CoachVoiceStore; the next conversation re-seeds with the new tone.

struct CoachVoiceEditor: View {
  let domain: CoachDomain

  @State private var voice: CoachVoice

  init(domain: CoachDomain) {
    self.domain = domain
    // Seed from pure defaults (no actor hop); the stored voice loads in .task.
    _voice = State(initialValue: .defaults(for: domain))
  }

  var body: some View {
    AdaptiveEditScaffold(title: "Voice", accent: domain.accent, onSave: save) {
      Form {
        Section {
          VoiceDialRow(title: "Warmth", selection: $voice.warmth) { $0.label }
          VoiceDialRow(title: "Length", selection: $voice.brevity) { $0.label }
          VoiceDialRow(title: "Challenge", selection: $voice.challenge) { $0.label }
          VoiceDialRow(title: "Formality", selection: $voice.formality) { $0.label }
        } header: {
          Text("Tone")
        } footer: {
          Text("\(domain.title) will sound **\(voice.summary)**. The facts discipline — cite real numbers, never invent data — always applies.")
        }

        if domain.handPicksContext {
          Section {
            TextField("e.g. talk to me like a stoic mentor",
                      text: $voice.note, axis: .vertical)
              .lineLimit(2...4)
          } header: {
            Text("Custom instruction")
          } footer: {
            Text("Appended to how this coach talks.")
          }
        }

        Section {
          Button("Reset to default") { voice = .defaults(for: domain) }
            .disabled(voice == .defaults(for: domain))
        }
      }
      .task { voice = CoachVoiceStore.load(domain) }
    }
  }

  private func save() {
    CoachVoiceStore.save(voice, for: domain)
    Haptics.success()
  }
}

/// A labeled segmented dial. Generic over the four voice enums (each is
/// CaseIterable + Identifiable), so the four rows share one implementation.
private struct VoiceDialRow<Dial>: View
where Dial: CaseIterable & Hashable & Identifiable, Dial.AllCases: RandomAccessCollection {
  let title: String
  @Binding var selection: Dial
  let label: (Dial) -> String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Picker(title, selection: $selection) {
        ForEach(Array(Dial.allCases)) { option in
          Text(label(option)).tag(option)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
    .padding(.vertical, 2)
  }
}
