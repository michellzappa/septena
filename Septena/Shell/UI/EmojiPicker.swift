import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// Reusable Tier-3 glyph picker (see docs/DesignSpec.md §2). Tier-3 emoji are
// the user-owned glyphs on habits, supplements, chores, symptoms, meals, and
// areas. Every editor used to hand the user a bare one-character TextField —
// this replaces that with a curated grid (the fast, glanceable path), a
// free-form field, a clear option, and a "More…" handoff to the OS's own emoji
// picker for the full set. It renders into the row's leading glyph slot.
//
// Why hand off to the OS for "all emoji": Apple ships no clean API to
// enumerate every emoji (the Unicode scalar properties miss every ZWJ
// sequence — families, professions, flags, skin tones), so the only way to a
// genuinely complete, always-current set with search is the system picker —
// the macOS Character Viewer and the iOS emoji keyboard. We surface those
// instead of bundling (and forever maintaining) a Unicode table.
//
// Two pieces:
//   • `EmojiPickerContent` — the popover/sheet body (curated grid + free-form
//     field + clear). Drop it into an existing presentation when the caller
//     already owns the trigger (e.g. the Area editor's AreaIcon button).
//   • `EmojiSlotPicker` — a self-contained leading-slot button that presents
//     `EmojiPickerContent` in a popover. The default for Form rows.
//
// The binding is a plain `String`; an empty string means "no glyph" (callers
// already map "" → nil at save time). Works on iOS and macOS.

// MARK: - Slot trigger

/// A tappable leading glyph slot. Shows the chosen emoji, or a neutral
/// "tap to pick" affordance when empty (an SF Symbol — never a fallback
/// emoji, per the spec). Sized to drop into the spot the old 44-pt emoji
/// TextField occupied.
struct EmojiSlotPicker: View {
  @Binding var emoji: String
  /// Fired on pick / clear / free-form edit, in addition to mutating the
  /// binding. Optional — Form callers that read the binding at save time can
  /// ignore it; live committers (the Area editor) use it.
  var onSelect: ((String) -> Void)? = nil
  /// Affordance shown in the empty slot. The iOS keyboard's own emoji glyph.
  var placeholderSymbol: String = "face.smiling"
  var width: CGFloat = 44

  @State private var showing = false

  var body: some View {
    Button { showing = true } label: { slot }
      .buttonStyle(.plain)
      .accessibilityLabel("Emoji")
      .popover(isPresented: $showing) {
        EmojiPickerContent(emoji: $emoji, onSelect: onSelect)
      }
  }

  private var slot: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8).fill(.quaternary)
      if emoji.isEmpty {
        Image(systemName: placeholderSymbol)
          .font(.system(size: 18))
          .foregroundStyle(.secondary)
      } else {
        Text(emoji).font(.system(size: 22))
      }
    }
    .frame(width: width, height: 34)
    .contentShape(RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Picker body

/// The picker surface: a free-form fallback field + Clear, then the curated
/// grid. Self-dismisses on pick or clear via the environment `dismiss`, so it
/// works the same whether presented as a popover (iPad / Mac) or an adapted
/// sheet (iPhone).
struct EmojiPickerContent: View {
  @Binding var emoji: String
  var onSelect: ((String) -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  /// Mirrors `emoji` so the free-form field can clamp to a single grapheme
  /// without fighting the grid.
  @State private var freeform: String = ""
  /// Drives focus into the free-form field — both so the OS emoji keyboard
  /// (iOS) appears and so the Character Viewer (macOS) inserts into it.
  @FocusState private var freeformFocused: Bool

  private let columns = [GridItem(.adaptive(minimum: 40, maximum: 46), spacing: 6)]

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      grid
    }
    .frame(idealWidth: 320, idealHeight: 380)
    .presentationDetents([.medium, .large])
    .onAppear { freeform = emoji }
  }

  private var header: some View {
    HStack(spacing: 10) {
      TextField("Emoji", text: $freeform)
        .textFieldStyle(.plain)
        .multilineTextAlignment(.center)
        .font(.system(size: 24))
        .frame(width: 56, height: 40)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .focused($freeformFocused)
        #if os(iOS)
        .autocorrectionDisabled()
        #endif
        .onChange(of: freeform) { _, value in
          // Hold a single grapheme. Reassigning re-fires onChange, which then
          // commits the stable value once. A grapheme cluster keeps ZWJ
          // emoji (families, skin tones) intact. Live-updates the binding so
          // the typed glyph shows immediately; dismissal waits for submit.
          let clamped = String(value.suffix(1))
          if clamped != value { freeform = clamped; return }
          emoji = clamped
          onSelect?(clamped)
        }
        .onSubmit { dismiss() }
      // Full set, straight from the OS: macOS Character Viewer, iOS emoji
      // keyboard (both have search + skin tones, and stay current with the OS).
      Button { openSystemPicker() } label: {
        Label("More…", systemImage: "face.smiling")
      }
      Spacer()
      Button("Clear") { commit("") }
        .disabled(emoji.isEmpty)
    }
    .padding(12)
  }

  private func openSystemPicker() {
    // Focus the free-form field so the OS picker's selection lands in it; the
    // onChange above then clamps + commits the chosen glyph.
    freeformFocused = true
    #if os(macOS)
    // The Character Viewer is a non-activating panel, so the popover stays
    // put. Let focus settle first, then bring it front.
    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
    #endif
  }

  private var grid: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        ForEach(CuratedEmoji.groups) { group in
          VStack(alignment: .leading, spacing: 6) {
            Text(group.title)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 6) {
              ForEach(group.emoji, id: \.self) { e in
                Button { commit(e) } label: {
                  Text(e)
                    .font(.system(size: 24))
                    .frame(width: 40, height: 40)
                    .background {
                      if emoji == e {
                        RoundedRectangle(cornerRadius: 8)
                          .fill(Color.accentColor.opacity(0.18))
                      }
                    }
                }
                .buttonStyle(.plain)
              }
            }
          }
        }
      }
      .padding(12)
    }
  }

  private func commit(_ value: String) {
    emoji = value
    freeform = value
    onSelect?(value)
    dismiss()
  }
}

// MARK: - Curated catalog

/// The curated glyph set the picker offers. Seeded from the section starter
/// sets (`HabitStarter` / `SupplementStarter` / `ChoreStarter` /
/// `SymptomStarter` in the plugin files) — every starter glyph appears in one
/// of the groups below — then rounded out so the grid is useful across every
/// section that owns a Tier-3 glyph. Kept in sync by hand; the plugin starter
/// sets remain the source of truth for onboarding suggestions.
enum CuratedEmoji {
  struct Group: Identifiable {
    let id: String
    let title: String
    let emoji: [String]
  }

  static let groups: [Group] = [
    Group(id: "routine", title: "Routine", emoji: [
      "💧", "🏃", "🚶", "🧘", "🤸", "🛌", "🚿", "🪥", "📖", "✍️",
      "📝", "🗣️", "📵", "☕", "🎧", "🙏",
    ]),
    Group(id: "health", title: "Health & body", emoji: [
      "💊", "💉", "🩹", "🩺", "🌡️", "💪", "🧠", "🫀", "🫁", "🦴",
      "🦵", "🦷", "👁️", "👂", "👃", "🩸", "🦠", "🧬", "🤕", "🤢",
      "🤧", "😷", "🪫", "🩻",
    ]),
    Group(id: "food", title: "Food & drink", emoji: [
      "🍎", "🍌", "🍓", "🥑", "🥦", "🥕", "🥗", "🍞", "🍚", "🍗",
      "🥩", "🥚", "🐟", "🥛", "🧀", "🥜", "🍳", "🍵", "🧃", "🍫",
      "🍯", "🧂", "🌾",
    ]),
    Group(id: "home", title: "Home & chores", emoji: [
      "🍽️", "🗑️", "🧺", "🧹", "🧽", "🧼", "🧻", "🛁", "🛏️", "🪣",
      "🧊", "🪟", "🪴", "🛋️", "🚪", "🔧", "🪛", "⚙️", "🧯", "🔌",
    ]),
    Group(id: "activity", title: "Activity & sport", emoji: [
      "🏋️", "🚴", "🏊", "🧗", "⛹️", "🤾", "🥊", "🎯", "⚽", "🏀",
      "🎾", "🏆", "🥾", "🏅",
    ]),
    Group(id: "nature", title: "Nature & weather", emoji: [
      "☀️", "🌙", "⭐", "🔥", "💨", "🌀", "🌫️", "🌧️", "❄️", "🌊",
      "🌱", "🌿", "🌸", "🍂", "🌲", "⛰️", "🪨", "🎈",
    ]),
    Group(id: "focus", title: "Work & focus", emoji: [
      "💻", "📚", "📅", "⏰", "💡", "🎯", "📌", "🗂️", "🧮", "🔬",
      "🎓", "📞", "✉️", "🔔", "🏷️", "💼",
    ]),
    Group(id: "symbols", title: "Symbols & mood", emoji: [
      "❤️", "🧡", "💛", "💚", "💙", "💜", "⭐", "✅", "⚠️", "♻️",
      "➕", "🔁", "❓", "🔆", "🌟", "🏁",
    ]),
  ]
}
