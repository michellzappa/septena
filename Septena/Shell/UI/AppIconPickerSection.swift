import SwiftUI

/// In-app App Icon picker for Settings ▸ Appearance (iOS).
///
/// Presents:
///   • 4 Icon Styles (`Default`, `Light`, `Framed`, `Stealth`) with live vector
///     previews matching the 31 prebaked `.appiconset` assets.
///   • Compact Icon Color selector (`Default` = follows Accent above, or choose
///     any of the 7 exotic fruits + `Mono` independently).
#if os(iOS)
struct AppIconPickerSection: View {
  private let appearance = AppearancePreferences.shared
  @Environment(\.colorScheme) private var colorScheme

  private var isDark: Bool { colorScheme == .dark }
  private var activeAccentColor: Color { appearance.accentSwiftUIColor }

  private var summaryLabel: String {
    let eff = appearance.resolvedAppIconFinish
    let col = appearance.resolvedAppIconColor
    return "\(eff.title) · \(col.title)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("App Icon")
          .font(.subheadline.weight(.medium))
        Spacer()
        Text(summaryLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      // 1. Icon Style selector (4 finishes)
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
        spacing: 8
      ) {
        ForEach(AppIconFinish.allCases) { finish in
          let previewColor = AppIconCatalog.resolvedColor(
            finish: finish,
            colorOverride: appearance.appIconColorOverride,
            accentColorID: appearance.accentColorID
          )
          let isCurrent = appearance.appIconFinish == finish
          IconStyleTileButton(
            finish: finish,
            color: previewColor,
            isDarkOS: isDark,
            selectionAccent: activeAccentColor,
            isCurrent: isCurrent
          ) {
            a11yAnimate(Theme.Motion.quick) {
              appearance.appIconFinish = finish
            }
          }
        }
      }

      // 2. Icon Color selector (Default = Match Accent, or explicit override)
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Icon Color")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          Spacer()
          Text(appearance.appIconColorOverride == nil ? "Matches Accent" : (appearance.appIconColorOverride?.title ?? ""))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            // Default / Match Accent pill
            let isAuto = appearance.appIconColorOverride == nil
            Button {
              a11yAnimate(Theme.Motion.quick) {
                appearance.appIconColorOverride = nil
              }
            } label: {
              Text("Default")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isAuto ? activeAccentColor : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                  Capsule()
                    .fill(isAuto ? activeAccentColor.opacity(isDark ? 0.22 : 0.14) : Theme.cardSurface)
                )
                .overlay(
                  Capsule()
                    .strokeBorder(
                      isAuto ? activeAccentColor : Theme.border.opacity(0.7),
                      lineWidth: isAuto ? 1.5 : 0.75
                    )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Default icon color, matches app accent")
            .accessibilityAddTraits(isAuto ? .isSelected : [])

            // 8 explicit color swatches (7 fruits + Mono)
            ForEach(AppIconColor.allCases) { iconColor in
              let isPicked = appearance.appIconColorOverride == iconColor
              let swatch = RGBTriple.fromHex(isDark ? iconColor.darkHex : iconColor.baseHex).swiftUIColor
              Button {
                a11yAnimate(Theme.Motion.quick) {
                  appearance.appIconColorOverride = iconColor
                }
              } label: {
                ZStack {
                  Circle()
                    .fill(swatch)
                    .frame(width: 22, height: 22)
                    .overlay(
                      Circle()
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.75)
                    )
                  if isPicked {
                    Circle()
                      .strokeBorder(activeAccentColor, lineWidth: 2)
                      .frame(width: 28, height: 28)
                  }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("\(iconColor.title) icon color")
              .accessibilityAddTraits(isPicked ? .isSelected : [])
            }
          }
          .padding(.vertical, 2)
        }
      }
    }
  }
}

private struct IconStyleTileButton: View {
  let finish: AppIconFinish
  let color: AppIconColor
  let isDarkOS: Bool
  let selectionAccent: Color
  let isCurrent: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        SeptenaCompassIconView(
          finish: finish,
          color: color,
          isDarkOS: isDarkOS
        )
        .frame(width: 48, height: 48)
        .shadow(color: Color.black.opacity(isDarkOS ? 0.42 : 0.14), radius: 4, y: 2)

        Text(finish.title)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(isCurrent ? .primary : .secondary)
          .lineLimit(1)
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Theme.cardSurface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(
            isCurrent ? selectionAccent : Theme.border.opacity(0.7),
            lineWidth: isCurrent ? 2 : 0.75
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(finish.title) icon style")
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }
}
#endif

// MARK: - Native Vector Preview (Matches `tools/logo-builder/dial-svg.mjs`)

/// Crisp vector SwiftUI rendering of the canonical Septena Upright Compass icon,
/// shared by the Settings picker and any in-app icon preview without shipping
/// duplicate preview bitmaps.
struct SeptenaCompassIconView: View {
  let finish: AppIconFinish
  let color: AppIconColor
  let isDarkOS: Bool

  private var effFinish: AppIconFinish {
    AppIconCatalog.effectiveFinish(finish: finish, color: color)
  }

  private var isStealth: Bool { effFinish == .stealth }
  private var isWhiteShell: Bool { effFinish == .ceramic }
  private var isBlackShell: Bool { effFinish == .obsidian || isStealth }
  private var isColoredShell: Bool { effFinish == .framed }
  private var isDarkFace: Bool { isStealth ? true : isDarkOS }
  private var isMono: Bool { color.isMono }
  private var accentCheck: Bool { !isColoredShell }

  var body: some View {
    GeometryReader { geo in
      let s = min(geo.size.width, geo.size.height)
      let scale = s / 1024.0
      let corner = s * 0.2237
      let palette = resolvedColors

      ZStack {
        // 1. Outer shell
        LinearGradient(
          colors: [palette.shellTop, palette.shellMid, palette.shellBot],
          startPoint: UnitPoint(x: 0.16, y: 0.02),
          endPoint: UnitPoint(x: 0.84, y: 1.0)
        )

        // Subtle top-left sheen
        RadialGradient(
          colors: [
            Color.white.opacity(isWhiteShell ? 0.45 : (isStealth ? 0.11 : (isBlackShell ? 0.16 : 0.24))),
            Color.white.opacity(0.02),
            Color.black.opacity(isWhiteShell ? 0.06 : 0.14),
          ],
          center: UnitPoint(x: 0.28, y: 0.12),
          startRadius: 0,
          endRadius: s * 0.72
        )

        // 2. Bold recessed ring / moat (r = 416)
        Circle()
          .fill(
            LinearGradient(
              colors: [palette.wellTop, palette.wellMid, palette.wellBot],
              startPoint: UnitPoint(x: 0.2, y: 0.0),
              endPoint: UnitPoint(x: 0.8, y: 1.0)
            )
          )
          .frame(width: 832 * scale, height: 832 * scale)
          .overlay(
            Circle()
              .strokeBorder(palette.shadow.opacity(isWhiteShell ? 0.28 : 0.55), lineWidth: max(0.75, 8 * scale))
          )

        // 3. Elevated inner dial plate (r = 354)
        Circle()
          .fill(
            RadialGradient(
              colors: [palette.faceTop, palette.faceMid, palette.faceBot],
              center: UnitPoint(x: 0.42, y: 0.30),
              startRadius: 0,
              endRadius: 354 * scale * 1.44
            )
          )
          .frame(width: 708 * scale, height: 708 * scale)
          .overlay(
            Circle()
              .strokeBorder(Color.white.opacity(isStealth ? 0.14 : (isDarkFace ? 0.18 : 0.94)), lineWidth: max(0.5, 5 * scale))
          )
          .shadow(color: palette.shadow.opacity(isWhiteShell ? 0.26 : 0.42), radius: max(1, 10 * scale), y: max(0.5, 8 * scale))

        // 4. 6 machined ticks + upright North pointer + checkmark
        Canvas { ctx, size in
          let sc = min(size.width, size.height) / 1024.0
          let cx = size.width / 2
          let cy = size.height / 2
          let step = 360.0 / 7.0

          // 6 ticks at k = 1...6
          let tickStyle = StrokeStyle(lineWidth: 24 * sc, lineCap: .round)
          let tickColor = palette.mutedGlyph.opacity(isStealth ? 0.28 : (isDarkFace ? 0.34 : 0.28))
          for i in 1..<7 {
            let rad = (-90.0 + Double(i) * step) * .pi / 180.0
            var p = Path()
            p.move(to: CGPoint(x: cx + cos(rad) * 260 * sc, y: cy + sin(rad) * 260 * sc))
            p.addLine(to: CGPoint(x: cx + cos(rad) * 310 * sc, y: cy + sin(rad) * 310 * sc))
            ctx.stroke(p, with: .color(tickColor), style: tickStyle)
          }

          // Upright North compass pointer (-90°)
          let a0 = -90.0 * .pi / 180.0
          let aL = (-90.0 - 11.2) * .pi / 180.0
          let aR = (-90.0 + 11.2) * .pi / 180.0
          var north = Path()
          north.move(to: CGPoint(x: cx + cos(a0) * 336 * sc, y: cy + sin(a0) * 336 * sc))
          north.addLine(to: CGPoint(x: cx + cos(aR) * 238 * sc, y: cy + sin(aR) * 238 * sc))
          north.addLine(to: CGPoint(x: cx + cos(a0) * 260 * sc, y: cy + sin(a0) * 260 * sc))
          north.addLine(to: CGPoint(x: cx + cos(aL) * 238 * sc, y: cy + sin(aL) * 238 * sc))
          north.closeSubpath()

          let accGrad = Gradient(colors: [palette.accLight, palette.accMid, palette.accDeep])
          ctx.fill(
            north,
            with: .linearGradient(
              accGrad,
              startPoint: CGPoint(x: cx - 40 * sc, y: cy - 336 * sc),
              endPoint: CGPoint(x: cx + 40 * sc, y: cy - 238 * sc)
            )
          )

          // Sculpted checkmark aligned to 2nd tick (-38.57°): M 377 511 L 460 598 L 639 426
          var check = Path()
          check.move(to: CGPoint(x: 377 * sc, y: 511 * sc))
          check.addLine(to: CGPoint(x: 460 * sc, y: 598 * sc))
          check.addLine(to: CGPoint(x: 639 * sc, y: 426 * sc))
          let checkStyle = StrokeStyle(lineWidth: 64 * sc, lineCap: .round, lineJoin: .round)

          if accentCheck {
            ctx.stroke(
              check,
              with: .linearGradient(
                accGrad,
                startPoint: CGPoint(x: 377 * sc, y: 426 * sc),
                endPoint: CGPoint(x: 639 * sc, y: 598 * sc)
              ),
              style: checkStyle
            )
          } else {
            let inkGrad = Gradient(colors: [palette.checkInkTop, palette.checkInkBot])
            ctx.stroke(
              check,
              with: .linearGradient(
                inkGrad,
                startPoint: CGPoint(x: 420 * sc, y: 426 * sc),
                endPoint: CGPoint(x: 590 * sc, y: 598 * sc)
              ),
              style: checkStyle
            )
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: corner, style: .continuous)
          .strokeBorder(
            isWhiteShell ? Color.black.opacity(0.08) : palette.shellRim.opacity(isStealth ? 0.24 : 0.30),
            lineWidth: max(0.5, 4 * scale)
          )
      )
    }
    .aspectRatio(1, contentMode: .fit)
  }

  private struct ResolvedPalette {
    let shellTop, shellMid, shellBot, shellRim: Color
    let wellTop, wellMid, wellBot, shadow: Color
    let faceTop, faceMid, faceBot: Color
    let accLight, accMid, accDeep: Color
    let checkInkTop, checkInkBot, mutedGlyph: Color
  }

  private var resolvedColors: ResolvedPalette {
    let baseRGB = RGBTriple.fromHex(color.baseHex)
    let darkRGB = RGBTriple.fromHex(color.darkHex)
    let paperRGB = RGBTriple.fromHex(color.paperHex)

    let shellTop: Color
    let shellMid: Color
    let shellBot: Color
    let shellRim: Color
    let wellTop: Color
    let wellMid: Color
    let wellBot: Color
    let shadow: Color

    if isWhiteShell {
      shellTop = .white
      shellMid = hex("#F4F2ED")
      shellBot = hex("#E4E1D9")
      shellRim = .white
      wellTop = hex(isDarkFace ? "#AEABA2" : "#B9B5AC")
      wellMid = hex(isDarkFace ? "#C2BFB7" : "#CBC7BE")
      wellBot = hex(isDarkFace ? "#D4D1C9" : "#DBD8D0")
      shadow = hex("#6E6A61")
    } else if isStealth {
      shellTop = hex("#26272E")
      shellMid = hex("#17181D")
      shellBot = hex("#0C0D10")
      shellRim = hex("#4C4F5C")
      wellTop = hex("#040406")
      wellMid = hex("#08090C")
      wellBot = hex("#0F1015")
      shadow = hex("#020204")
    } else if isBlackShell {
      shellTop = hex("#3B3C46")
      shellMid = hex("#27272E")
      shellBot = hex("#15151A")
      shellRim = hex("#686A78")
      wellTop = hex("#07070A")
      wellMid = hex("#0F1015")
      wellBot = hex("#181920")
      shadow = hex("#040407")
    } else {
      shellTop = adjustLightness(baseRGB, delta: 0.11)
      shellMid = baseRGB.swiftUIColor
      shellBot = adjustLightness(baseRGB, delta: -0.13)
      shellRim = darkRGB.swiftUIColor
      wellTop = adjustLightness(baseRGB, delta: -0.28, minL: 0.11, maxL: 0.20)
      wellMid = adjustLightness(baseRGB, delta: -0.23, minL: 0.15, maxL: 0.25)
      wellBot = adjustLightness(baseRGB, delta: -0.17, minL: 0.20, maxL: 0.31)
      shadow = adjustLightness(baseRGB, delta: -0.36, minL: 0.03, maxL: 0.14)
    }

    let faceTop = isStealth ? hex("#212229") : (isDarkFace ? hex("#2E2F38") : .white)
    let faceMid = isStealth ? hex("#16171C") : (isDarkFace ? hex("#22232B") : paperRGB.swiftUIColor)
    let faceBot = isStealth ? hex("#0E0F13") : (isDarkFace ? hex("#17181E") : adjustLightness(paperRGB, delta: -0.05, minL: 0.86, maxL: 0.96))

    let accLight: Color
    let accMid: Color
    let accDeep: Color
    if isMono {
      accLight = hex(isDarkFace ? (isStealth ? "#C9CDD6" : "#EFEFF4") : "#525660")
      accMid   = hex(isDarkFace ? (isStealth ? "#9DA2AE" : "#D5D7E0") : "#434750")
      accDeep  = hex(isDarkFace ? (isStealth ? "#777C88" : "#B4B7C2") : "#32353C")
    } else {
      accLight = darkRGB.swiftUIColor
      accMid   = baseRGB.swiftUIColor
      accDeep  = adjustLightness(baseRGB, delta: -0.15, minL: 0.12, maxL: 0.72)
    }

    return ResolvedPalette(
      shellTop: shellTop, shellMid: shellMid, shellBot: shellBot, shellRim: shellRim,
      wellTop: wellTop, wellMid: wellMid, wellBot: wellBot, shadow: shadow,
      faceTop: faceTop, faceMid: faceMid, faceBot: faceBot,
      accLight: accLight, accMid: accMid, accDeep: accDeep,
      checkInkTop: hex(isDarkFace ? "#F6F6F8" : "#4C5058"),
      checkInkBot: hex(isDarkFace ? "#DFDFE5" : "#363940"),
      mutedGlyph: hex(isStealth ? "#9A9EA9" : (isDarkFace ? "#C7C9D4" : "#6A6770"))
    )
  }

  private func hex(_ value: String) -> Color {
    RGBTriple.fromHex(value).swiftUIColor
  }

  private func adjustLightness(_ rgb: RGBTriple, delta: Double, minL: Double = 0.06, maxL: Double = 0.85) -> Color {
    let maxC = max(rgb.r, max(rgb.g, rgb.b))
    let minC = min(rgb.r, min(rgb.g, rgb.b))
    var h = 0.0
    var s = 0.0
    let l = (maxC + minC) / 2.0
    if maxC != minC {
      let d = maxC - minC
      s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC)
      if maxC == rgb.r { h = ((rgb.g - rgb.b) / d + (rgb.g < rgb.b ? 6.0 : 0.0)) / 6.0 }
      else if maxC == rgb.g { h = ((rgb.b - rgb.r) / d + 2.0) / 6.0 }
      else { h = ((rgb.r - rgb.g) / d + 4.0) / 6.0 }
    }
    let nl = max(minL, min(maxL, l + delta))
    let c = (1.0 - abs(2.0 * nl - 1.0)) * s
    let hh = h * 6.0
    let x = c * (1.0 - abs(hh.truncatingRemainder(dividingBy: 2.0) - 1.0))
    let m = nl - c / 2.0
    let (r1, g1, b1): (Double, Double, Double) = switch Int(hh) % 6 {
    case 0: (c, x, 0)
    case 1: (x, c, 0)
    case 2: (0, c, x)
    case 3: (0, x, c)
    case 4: (x, 0, c)
    default: (c, 0, x)
    }
    return Color(red: max(0, min(1, r1 + m)), green: max(0, min(1, g1 + m)), blue: max(0, min(1, b1 + m)))
  }
}
