// Curated accent palette + the shared swatch picker (button + popover
// grid). Extracted from SectionsSettingsPane.swift into Shell/UI so
// every target with settings-adjacent UI (Septena, Septask) draws from
// the one palette — see docs/SEPTASK.md.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PaletteSwatch: Identifiable {
  let id: String
  let label: String
  let hex: String
}

let sectionPalette: [PaletteSwatch] = [
  // Bright row — Tailwind 500
  .init(id: "red",        label: String(localized: "Red", comment: "Accent color"),        hex: "#ef4444"),
  .init(id: "orange",     label: String(localized: "Orange", comment: "Accent color"),     hex: "#f97316"),
  .init(id: "amber",      label: String(localized: "Amber", comment: "Accent color"),      hex: "#f59e0b"),
  .init(id: "yellow",     label: String(localized: "Yellow", comment: "Accent color"),     hex: "#eab308"),
  .init(id: "lime",       label: String(localized: "Lime", comment: "Accent color"),       hex: "#84cc16"),
  .init(id: "green",      label: String(localized: "Green", comment: "Accent color"),      hex: "#22c55e"),
  .init(id: "emerald",    label: String(localized: "Emerald", comment: "Accent color"),    hex: "#10b981"),
  .init(id: "teal",       label: String(localized: "Teal", comment: "Accent color"),       hex: "#14b8a6"),
  .init(id: "cyan",       label: String(localized: "Cyan", comment: "Accent color"),       hex: "#06b6d4"),
  .init(id: "sky",        label: String(localized: "Sky", comment: "Accent color"),        hex: "#0ea5e9"),
  .init(id: "blue",       label: String(localized: "Blue", comment: "Accent color"),       hex: "#3b82f6"),
  .init(id: "indigo",     label: String(localized: "Indigo", comment: "Accent color"),     hex: "#6366f1"),
  .init(id: "violet",     label: String(localized: "Violet", comment: "Accent color"),     hex: "#8b5cf6"),
  .init(id: "purple",     label: String(localized: "Purple", comment: "Accent color"),     hex: "#a855f7"),
  .init(id: "pink",       label: String(localized: "Pink", comment: "Accent color"),       hex: "#ec4899"),
  .init(id: "rose",       label: String(localized: "Rose", comment: "Accent color"),       hex: "#f43f5e"),
  // Earth row — Tailwind 700/800 warm hues
  .init(id: "terracotta", label: "Terracotta", hex: "#9a3412"),
  .init(id: "brown",      label: "Brown",      hex: "#b45309"),
  .init(id: "mustard",    label: "Mustard",    hex: "#854d0e"),
  .init(id: "olive",      label: "Olive",      hex: "#3f6212"),
  .init(id: "taupe",      label: "Taupe",      hex: "#78716c"),
  .init(id: "espresso",   label: "Espresso",   hex: "#44403c"),
]

struct PaletteSwatchGrid: View {
  let selectedHex: String
  let onSelect: (String) -> Void

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(sectionPalette) { swatch in
        let color = parseHexColor(swatch.hex)
        let isSelected = selectedHex.lowercased() == swatch.hex.lowercased()
        Button {
          onSelect(swatch.hex)
        } label: {
          Circle()
            .fill(color)
            .frame(width: 28, height: 28)
            .overlay(
              Circle()
                .strokeBorder(Color.primary.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                .padding(isSelected ? -3 : 0)
            )
            .overlay(
              Circle()
              #if canImport(UIKit)
                .strokeBorder(Color(UIColor.systemBackground), lineWidth: isSelected ? 2 : 0)
              #else
                .strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: isSelected ? 2 : 0)
              #endif
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.label)
      }
    }
    .padding(.vertical, 4)
  }
}

/// Compact "tap to change the color" affordance: the current color in a circle
/// wrapped in the conic rainbow ring iOS's system `ColorPicker` well uses,
/// opening a popover with the curated `PaletteSwatchGrid`. The single component
/// every color selector uses (section identity, intake trackers, macro tiles) so
/// they read identically and draw from the one curated palette rather than an
/// inline full grid or the OS full-spectrum well.
struct PaletteSwatchButton: View {
  let selectedHex: String
  var arrowEdge: Edge = .trailing
  let onSelect: (String) -> Void

  @State private var showingPicker = false

  /// Gap color between the rainbow ring and the colored center, so the ring
  /// stays visually detached from the row background on both platforms.
  private var ringGap: Color {
    #if canImport(UIKit)
    Color(uiColor: .secondarySystemGroupedBackground)
    #else
    Color(nsColor: .windowBackgroundColor)
    #endif
  }

  var body: some View {
    Button {
      showingPicker.toggle()
    } label: {
      ZStack {
        Circle()
          .fill(AngularGradient(
            gradient: Gradient(colors: [.red, .orange, .yellow, .green,
                                        .cyan, .blue, .purple, .red]),
            center: .center))
        Circle().fill(ringGap).padding(2)
        Circle().fill(parseHexColor(selectedHex)).padding(4)
      }
      .frame(width: 26, height: 26)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Color")
    .popover(isPresented: $showingPicker, arrowEdge: arrowEdge) {
      PaletteSwatchGrid(selectedHex: selectedHex) { hex in
        onSelect(hex)
        showingPicker = false
      }
      .padding(12)
      .presentationCompactAdaptation(.popover)
    }
  }
}
