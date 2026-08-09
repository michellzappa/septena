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
    case .small:  return "Small"
    case .normal: return "Medium"
    case .large:  return "Large"
    case .xLarge: return "Largest"
    }
  }

  static func resolve(_ raw: Int) -> TextSizeStep {
    TextSizeStep(rawValue: max(-2, min(2, raw))) ?? .normal
  }

  /// macOS has no Dynamic Type, so there the step maps to an explicit font
  /// multiplier applied to the `.septena*` tokens (see `SeptenaTypeScale`).
  /// iOS ignores this and uses the `rawValue` as a `DynamicTypeSize` offset.
  var macFactor: CGFloat {
    switch self {
    case .xSmall: return 0.85
    case .small:  return 0.92
    case .normal: return 1.0
    case .large:  return 1.10
    case .xLarge: return 1.20
    }
  }
}

#if os(macOS)
import AppKit

extension Notification.Name {
  /// Posted after the macOS text-size factor changes so native AppKit shells
  /// can refresh already-visible cells (SwiftUI gets this through observation).
  static let septenaTextSizeDidChange = Notification.Name("septena.textSizeDidChange")
}

/// macOS text-scale backing. macOS doesn't support Dynamic Type, so the
/// app-wide Text Size setting is delivered by scaling the `.septena*` font
/// tokens directly. This is `@Observable` and read from *inside* those token
/// getters, so SwiftUI tracks the dependency and re-renders exactly the text
/// views when the factor changes — no `.id()` rebuild, no lost navigation or
/// scroll state. A singleton (not environment-injected) so it can't trip the
/// missing-`@Environment` launch crash CLAUDE.md warns about.
@Observable
final class FontScale {
  static let shared = FontScale()
  var factor: CGFloat = TextSizeStep.resolve(
    UserDefaults.standard.integer(forKey: SettingsKey.textSizeStep)).macFactor

  private init() {}

  func setStep(_ step: Int) {
    let next = TextSizeStep.resolve(step).macFactor
    guard next != factor else { return }
    factor = next
    NotificationCenter.default.post(name: .septenaTextSizeDidChange, object: self)
  }
}

/// A text style's base point size (from AppKit, so it tracks the system) times
/// the current macOS text-scale factor. At factor 1.0 this equals the size the
/// matching `Font.system(<style>)` rendered before, so nothing shifts at the
/// default step.
enum SeptenaTypeScale {
  static func size(_ style: NSFont.TextStyle) -> CGFloat {
    NSFont.preferredFont(forTextStyle: style).pointSize * FontScale.shared.factor
  }
}
#endif

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

  #if os(macOS)
  // macOS: no Dynamic Type. Keep the shared FontScale in sync with the setting;
  // the `.septena*` tokens read it, and SwiftUI observation re-renders the
  // affected text (state-preserving — the setting can even live in a sheet that
  // stays put while you drag).
  func body(content: Content) -> some View {
    content
      .onAppear { FontScale.shared.setStep(step) }
      .onChange(of: step) { _, newStep in FontScale.shared.setStep(newStep) }
  }
  #else
  // iOS / watch: offset the OS Dynamic Type size rather than replacing it, so an
  // accessibility text size set system-wide is respected and merely nudged.
  @Environment(\.dynamicTypeSize) private var systemSize

  func body(content: Content) -> some View {
    content.dynamicTypeSize(systemSize.shifted(by: TextSizeStep.resolve(step).rawValue))
  }
  #endif
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
        #if os(macOS)
        Text("Adjusts text size everywhere in the app. This is a per-device preference — it doesn’t change your other Septena devices.")
        #else
        Text("Adjusts text size everywhere in the app. This nudges your device’s system text size — it doesn’t replace it, so any accessibility text size you’ve set is respected. Set your device’s base size in Settings ▸ Accessibility ▸ Display & Text Size.")
        #endif
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
