// App-wide text-size preference.
//
// The whole typography system (Theme.swift's `.septena*` tokens) is built on
// SwiftUI system text styles, which already scale with Dynamic Type. That means
// a single lever rescales every one of the ~900 `.font(...)` call sites for
// free: `.dynamicTypeSize(...)` applied once at the app root. This file is that
// lever plus its stored preference.
//
// Deliberately RELATIVE, not absolute: instead of pinning five fixed sizes, the
// user's −2…+2 step *offsets* the OS Dynamic Type setting. So someone who set a
// large accessibility size system-wide keeps it and merely nudges from there —
// we never stomp the accessibility choice. On macOS (no OS Dynamic Type slider)
// the base is `.large`, so the same control simply gives Mac a text-size dial it
// otherwise lacks.
//
// Deliberately a self-contained ViewModifier (reads @AppStorage + the ambient
// `\.dynamicTypeSize`), NOT an injected `@Environment(X.self)` object — so a
// surface that forgets to apply it just doesn't scale, rather than crashing at
// launch (the trap called out in CLAUDE.md). Compiles into all four app targets
// via `Shell/UI`.

import SwiftUI

// MARK: - Step model

/// The five relative text-size steps exposed in Settings. Raw value is the
/// signed offset applied to the ambient `DynamicTypeSize`, and is what's
/// persisted in `SettingsKey.textSizeStep` (absent → 0 → no change).
enum TextSizeStep: Int, CaseIterable, Identifiable {
  case xSmall = -2
  case small  = -1
  case normal = 0
  case large  = 1
  case xLarge = 2

  var id: Int { rawValue }

  /// Human label for the Settings preview / accessibility.
  var label: String {
    switch self {
    case .xSmall: return "Smallest"
    case .small:  return "Smaller"
    case .normal: return "Default"
    case .large:  return "Larger"
    case .xLarge: return "Largest"
    }
  }

  static func resolve(_ raw: Int) -> TextSizeStep {
    TextSizeStep(rawValue: max(-2, min(2, raw))) ?? .normal
  }
}

// MARK: - DynamicTypeSize offset

extension DynamicTypeSize {
  /// This size shifted by `steps` positions along the Dynamic Type ladder,
  /// clamped to the valid range. `+1` = one size larger, `-1` = one smaller.
  /// `DynamicTypeSize.allCases` is ordered ascending (`.xSmall` … `.accessibility5`).
  func shifted(by steps: Int) -> DynamicTypeSize {
    guard steps != 0 else { return self }
    let all = DynamicTypeSize.allCases
    guard let idx = all.firstIndex(of: self) else { return self }
    let target = min(max(idx + steps, 0), all.count - 1)
    return all[target]
  }
}

// MARK: - Root modifier

private struct SeptenaTextSizeModifier: ViewModifier {
  // Device-local, like the sibling display prefs (homepage layout, logging
  // animations). Text size is naturally per-device — bigger on a Mac window
  // than on a phone — so it isn't part of the CloudKit-synced payload.
  @AppStorage(SettingsKey.textSizeStep) private var step: Int = 0
  // The ambient size ABOVE this modifier — i.e. what the OS resolved from the
  // system Dynamic Type setting. We offset from it rather than replacing it.
  @Environment(\.dynamicTypeSize) private var systemSize

  func body(content: Content) -> some View {
    content.dynamicTypeSize(systemSize.shifted(by: TextSizeStep.resolve(step).rawValue))
  }
}

extension View {
  /// Apply the user's app-wide text-size preference. Call ONCE at the app root
  /// (`RootTabView` / `SeptaskRootView`); it flows to every descendant —
  /// including overlays and presented sheets — via the environment.
  func septenaTextSize() -> some View {
    modifier(SeptenaTextSizeModifier())
  }
}

// MARK: - Settings pane
//
// One relative dial (−2…+2) that offsets the system Dynamic Type size across
// the whole app. This pane just writes `SettingsKey.textSizeStep`; the root
// `.septenaTextSize()` modifier does the work. The whole Settings screen
// rescales live as you drag — the truest possible preview — and the sample rows
// spell the effect out on real type tokens. Shared, so both Septena's Settings
// and Septask's own settings shell present the same pane.

struct TextSizeSettingsPane: View {
  @AppStorage(SettingsKey.textSizeStep) private var step: Int = 0

  private var sliderBinding: Binding<Double> {
    Binding(
      get: { Double(TextSizeStep.resolve(step).rawValue) },
      set: { step = Int($0.rounded()) }
    )
  }

  var body: some View {
    Form {
      Section {
        Slider(
          value: sliderBinding,
          in: -2...2,
          step: 1
        ) {
          Text("Text Size")
        } minimumValueLabel: {
          Image(systemName: "textformat.size.smaller")
            .foregroundStyle(.secondary)
        } maximumValueLabel: {
          Image(systemName: "textformat.size.larger")
            .foregroundStyle(.secondary)
        }
        .accessibilityValue(TextSizeStep.resolve(step).label)

        HStack {
          Spacer()
          Text(TextSizeStep.resolve(step).label)
            .font(.septenaLabel)
            .foregroundStyle(.secondary)
          Spacer()
        }
      } footer: {
        Text("Adjusts text size everywhere in the app. This nudges your device’s system text size — it doesn’t replace it, so any accessibility text size you’ve set is respected. Set your device’s base size in Settings ▸ Accessibility ▸ Display & Text Size.")
      }

      Section {
        VStack(alignment: .leading, spacing: 6) {
          Text("Morning run")
            .font(.septenaTaskTitle)
          Text("Tomorrow · Health")
            .font(.septenaMeta)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
      } header: {
        Text("Preview")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Text Size")
  }
}
