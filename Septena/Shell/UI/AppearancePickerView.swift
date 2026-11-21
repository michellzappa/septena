import SwiftUI

/// Unified Appearance customization UI for Settings on iOS, iPadOS, and macOS
/// (ADR 0019 / `docs/CUSTOMIZATION_SPEC.md`).
///
/// Covers:
///   • Mode (`System` / `Light` / `Dark`, device-local) + `Sync across devices`
///   • Accent Color (`Colorful` default + 7 exotic fruits, restrained reach)
///   • Header Texture (`Pure Canvas` default + 6 procedural Header Wash styles)
///   • Texture Intensity (`Subtle` / `Balanced` / `Bold`) + `Slow drift` motion
struct AppearancePickerView: View {
  private let appearance = AppearancePreferences.shared
  @Environment(DayClock.self) private var dayClock
  @Environment(\.colorScheme) private var colorScheme
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  private var isDark: Bool { colorScheme == .dark }

  private var accentColumns: [GridItem] {
    #if os(iOS)
    let count = hSize == .compact ? 2 : 4
    #else
    let count = 4
    #endif
    return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
  }

  private var textureColumns: [GridItem] {
    #if os(iOS)
    let count = hSize == .compact ? 2 : 4
    #else
    let count = 4
    #endif
    return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
  }

  private var intensityBucket: Int {
    if appearance.textureIntensity < 45 { return 35 }
    if appearance.textureIntensity < 68 { return 55 }
    return 80
  }

  var body: some View {
    @Bindable var prefs = appearance
    let dailySeed = AppearancePreferences.dailySeed(for: dayClock.today)
    let activeAccentRGB = appearance.accentRGB(isDark: isDark)

    VStack(alignment: .leading, spacing: 14) {
      // 1. Appearance Mode (device-local)
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Appearance")
            .font(.subheadline.weight(.medium))
          Spacer()
          Picker("Appearance", selection: $prefs.appearanceMode) {
            ForEach(AppearanceMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 210)
        }

        Toggle(isOn: $prefs.syncTheme) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Sync theme across devices")
              .font(.subheadline)
            Text("Keep accent and header texture in sync; Light/Dark stays per device.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Divider()

      // 2. Accent Color (Colorful + 7 fruits)
      VStack(alignment: .leading, spacing: 8) {
        Text("Accent")
          .font(.subheadline.weight(.medium))

        LazyVGrid(columns: accentColumns, spacing: 8) {
          ForEach(RegistryTokens.fruitAccents) { fruit in
            let isCurrent = appearance.accentColorID == fruit.id
            AccentTileButton(
              fruit: fruit,
              isDark: isDark,
              isCurrent: isCurrent
            ) {
              a11yAnimate(Theme.Motion.quick) {
                appearance.accentColorID = fruit.id
              }
            }
          }
        }
      }

      Divider()

      // 3. Header Wash Texture (Pure Canvas + 6 procedural surfaces)
      VStack(alignment: .leading, spacing: 8) {
        Text("Header Texture")
          .font(.subheadline.weight(.medium))

        LazyVGrid(columns: textureColumns, spacing: 8) {
          ForEach(HeaderTextureStyle.allCases) { style in
            let isCurrent = appearance.canvasTexture == style
            TextureTileButton(
              style: style,
              isDark: isDark,
              accent: activeAccentRGB,
              intensity: appearance.textureIntensity,
              seed: dailySeed,
              isCurrent: isCurrent
            ) {
              a11yAnimate(Theme.Motion.quick) {
                appearance.canvasTexture = style
              }
            }
          }
        }
      }

      // 4. Texture Intensity & Motion (only when a texture is active)
      if appearance.hasActiveTexture {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("Intensity")
              .font(.subheadline)
            Spacer()
            Picker("Intensity", selection: Binding(
              get: { intensityBucket },
              set: { appearance.textureIntensity = $0 }
            )) {
              Text("Subtle").tag(35)
              Text("Balanced").tag(55)
              Text("Bold").tag(80)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
          }

          Toggle(isOn: Binding(
            get: { appearance.textureMotion == .slowDrift },
            set: { appearance.textureMotion = $0 ? .slowDrift : .still }
          )) {
            VStack(alignment: .leading, spacing: 1) {
              Text("Slow drift")
                .font(.subheadline)
              Text("Refreshes daily · pauses under Reduce Motion and Low Power.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(.top, 2)
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Accent Card

private struct AccentTileButton: View {
  let fruit: RegistryFruitAccent
  let isDark: Bool
  let isCurrent: Bool
  let action: () -> Void

  private var swatchColor: Color {
    RGBTriple.fromHex(isDark ? fruit.darkHex : fruit.lightHex).swiftUIColor
  }

  private var checkColor: Color {
    RGBTriple.fromHex(isDark ? fruit.checkDarkHex : fruit.checkLightHex).swiftUIColor
  }

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          swatchBadge
          Text(fruit.name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        // Mini-row accent preview: wash + done check + title bar
        HStack(spacing: 5) {
          ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .fill(swatchColor)
              .frame(width: 11, height: 11)
            Image(systemName: "checkmark")
              .font(.system(size: 7, weight: .bold))
              .foregroundStyle(checkColor)
          }
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.primary.opacity(0.28))
            .frame(height: 4)
            .frame(maxWidth: .infinity)
          if fruit.multicolor {
            Circle()
              .fill(Theme.todayAccent)
              .frame(width: 6, height: 6)
          }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(swatchColor.opacity(isDark ? 0.24 : 0.14))
        )
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Theme.cardSurface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(
            isCurrent ? swatchColor : Theme.border.opacity(0.7),
            lineWidth: isCurrent ? 2 : 0.75
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(fruit.name)
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }

  @ViewBuilder
  private var swatchBadge: some View {
    if fruit.multicolor {
      Circle()
        .fill(
          AngularGradient(
            colors: [
              Color(red: 0.96, green: 0.78, blue: 0.13),
              Color(red: 0.0, green: 0.48, blue: 1.0),
              Color(red: 0.84, green: 0.20, blue: 0.25),
              Color(red: 0.36, green: 0.55, blue: 0.0),
              Color(red: 0.40, green: 0.27, blue: 0.84),
              Color(red: 0.96, green: 0.78, blue: 0.13),
            ],
            center: .center
          )
        )
        .frame(width: 18, height: 18)
        .overlay(
          Circle()
            .fill(Theme.cardSurface)
            .frame(width: 7, height: 7)
        )
    } else {
      Circle()
        .fill(swatchColor)
        .frame(width: 18, height: 18)
        .overlay(
          Circle()
            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
    }
  }
}

// MARK: - Texture Card

private struct TextureTileButton: View {
  let style: HeaderTextureStyle
  let isDark: Bool
  let accent: RGBTriple
  let intensity: Int
  let seed: UInt32
  let isCurrent: Bool
  let action: () -> Void

  private var accentColor: Color { accent.swiftUIColor }

  var body: some View {
    let info = style.descriptor
    Button(action: action) {
      VStack(alignment: .leading, spacing: 5) {
        ZStack(alignment: .bottomLeading) {
          Theme.groupedBackground
          HeaderWashPreviewCanvas(
            style: style,
            isDark: isDark,
            accent: accent,
            intensity: intensity,
            seed: seed
          )
          // Subtle glass card hint at the bottom of the thumbnail
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Theme.cardSurface.opacity(style == .none ? 1.0 : (isDark ? 0.62 : 0.72)))
            .overlay(
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .frame(height: 12)
            .padding(.horizontal, 6)
            .padding(.bottom, 5)
        }
        .frame(height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Theme.border.opacity(0.45), lineWidth: 0.5)
        )

        VStack(alignment: .leading, spacing: 1) {
          Text(info.name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          Text(info.tag)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Theme.cardSurface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(
            isCurrent ? accentColor : Theme.border.opacity(0.7),
            lineWidth: isCurrent ? 2 : 0.75
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(info.name), \(info.tag)")
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }
}
