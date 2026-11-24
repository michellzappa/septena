import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// Reusable Tier-3 glyph picker (see docs/DesignSpec.md §2). Tier-3 emoji are
// the user-owned glyphs on areas and other user-owned items. Offers a
// keyword-searchable curated grid, direct emoji entry from the system emoji
// keyboard / Character Viewer (with immediate commit), and a Remove/Clear
// action when a glyph is already set.
//
// Two pieces:
//   • `EmojiPickerContent` — the sheet/popover body (search + curated grid +
//     remove/clear). Drop it into an existing presentation when the caller
//     already owns the trigger (e.g. the Area editor's AreaIcon button).
//   • `EmojiSlotPicker` — a self-contained leading-slot button that presents
//     `EmojiPickerContent` in a popover (which adapts to a sheet on compact
//     iPhone).
//
// The binding is a plain `String`; an empty string means "no glyph" (callers
// already map "" → nil at save time). Works on iOS and macOS.

// MARK: - Slot trigger

/// A tappable leading glyph slot. Shows the chosen emoji, or a neutral
/// "tap to pick" affordance when empty (an SF Symbol — never a fallback
/// emoji, per the spec).
struct EmojiSlotPicker: View {
  @Binding var emoji: String
  /// Fired on pick or remove, in addition to mutating the binding. Optional —
  /// Form callers that read the binding at save time can ignore it; live
  /// committers (the Area editor) use it.
  var onSelect: ((String) -> Void)? = nil
  /// Affordance shown in the empty slot.
  var placeholderSymbol: String = "face.smiling"
  var width: CGFloat = 44

  @State private var showing = false

  var body: some View {
    Button {
      #if os(iOS)
      Haptics.press()
      #endif
      showing = true
    } label: {
      slot
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Emoji")
    .popover(isPresented: $showing) {
      EmojiPickerContent(emoji: $emoji, onSelect: onSelect)
    }
  }

  private var slot: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
        .fill(.quaternary)
        .frame(width: width, height: slotVisualHeight)
      if emoji.isEmpty {
        Image(systemName: placeholderSymbol)
          .font(.system(size: 18))
          .foregroundStyle(.secondary)
      } else {
        Text(emoji).font(.system(size: 22))
      }
    }
    #if os(iOS)
    .frame(minWidth: max(width, 44), minHeight: 44)
    #else
    .frame(width: width, height: 34)
    #endif
    .contentShape(Rectangle())
  }

  private var slotVisualHeight: CGFloat {
    #if os(iOS)
    36
    #else
    34
    #endif
  }
}

// MARK: - Picker body

/// The picker surface: a unified search / emoji-keyboard input field, curated
/// grouped grid, and a Remove/Clear action when an emoji is already set.
/// Self-dismisses on pick or clear via the environment `dismiss`, so it works
/// cleanly whether presented as a sheet (iPhone) or popover (iPad / Mac).
struct EmojiPickerContent: View {
  @Binding var emoji: String
  var onSelect: ((String) -> Void)? = nil
  /// Closes a presentation SwiftUI does not own — the Mac shell hosts this in
  /// an `NSPopover`, where `dismiss` reaches nothing.
  var onDismiss: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  /// Drives both keyword filtering over the curated set and direct emoji entry
  /// (typing from the iOS emoji keyboard, pasting, or macOS Character Viewer).
  @State private var query: String = ""
  @State private var hasCommitted = false
  @FocusState private var searchFocused: Bool

  #if os(iOS)
  private let columns = [GridItem(.adaptive(minimum: 46, maximum: 56), spacing: 6)]
  #else
  private let columns = [GridItem(.adaptive(minimum: 40, maximum: 46), spacing: 6)]
  #endif

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var filteredGroups: [CuratedEmoji.Group] {
    CuratedEmoji.filter(query: trimmedQuery)
  }

  var body: some View {
    #if os(iOS)
    iosBody
    #else
    macBody
    #endif
  }

  // MARK: - iOS layout (sheet on iPhone, popover on iPad)

  #if os(iOS)
  private var iosBody: some View {
    NavigationStack {
      VStack(spacing: 0) {
        iosSearchBar
        Divider()
        gridBody
      }
      .navigationTitle("Emoji")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          DrawerCloseButton { close() }
        }
        if !emoji.isEmpty {
          ToolbarItem(placement: .topBarTrailing) {
            Button(role: .destructive) {
              commit("")
            } label: {
              // iOS emoji picker remove action (#201).
              Text("Remove") // septena-lint:allow shell-copy-literal
            }
          }
        }
      }
    }
    .modifier(RegularPopoverFrame(isRegular: horizontalSizeClass == .regular))
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .septenaSheetChrome()
    .onChange(of: query) { _, value in
      handleQueryChange(value)
    }
  }

  private var iosSearchBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.septenaNotes)
        .foregroundStyle(Theme.inkSecondary)
      // iOS emoji picker search and direct emoji input placeholder (#201).
      TextField("Search or type emoji…", text: $query) // septena-lint:allow shell-copy-literal
        .textFieldStyle(.plain)
        .font(.septenaTaskTitle)
        .focused($searchFocused)
        .submitLabel(.search)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onSubmit { handleSubmit() }
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.septenaNotes)
            .foregroundStyle(Theme.inkSecondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear")
      }
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 40)
    .background(Theme.mutedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(.horizontal, 16)
    .padding(.top, 4)
    .padding(.bottom, 10)
  }
  #endif

  // MARK: - macOS layout (KitPopover / SwiftUI popover)

  #if os(macOS)
  private var macBody: some View {
    VStack(spacing: 0) {
      macHeader
      Divider()
      gridBody
    }
    .frame(idealWidth: 320, idealHeight: 380)
    .onChange(of: query) { _, value in
      handleQueryChange(value)
    }
  }

  private var macHeader: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .font(.septenaCaption)
          .foregroundStyle(Theme.inkSecondary)
        TextField("Emoji", text: $query)
          .textFieldStyle(.plain)
          .font(.septenaNotes)
          .focused($searchFocused)
          .onSubmit { handleSubmit() }
        if !query.isEmpty {
          Button { query = "" } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.septenaCaption)
              .foregroundStyle(Theme.inkSecondary)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear")
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

      // Full set, straight from macOS Character Viewer (has search + skin tones).
      Button { openMacCharacterViewer() } label: {
        Label("More…", systemImage: "face.smiling")
          .font(.septenaLabel)
      }
      .buttonStyle(.borderless)

      Button("Clear") { commit("") }
        .buttonStyle(.borderless)
        .font(.septenaLabel)
        .disabled(emoji.isEmpty)
    }
    .padding(10)
  }

  private func openMacCharacterViewer() {
    searchFocused = true
    // The Character Viewer is a non-activating panel, so the popover stays
    // put. Let focus settle first, then bring it front.
    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
  }
  #endif

  // MARK: - Grid & empty state

  private var gridBody: some View {
    ScrollView {
      let groups = filteredGroups
      if groups.isEmpty {
        emptySearchState
      } else {
        LazyVStack(alignment: .leading, spacing: sectionSpacing) {
          ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 8) {
              Text(group.title)
                .font(.septenaLabel)
                .foregroundStyle(Theme.inkSecondary)
              LazyVGrid(columns: columns, spacing: 6) {
                ForEach(group.items) { item in
                  emojiCell(item)
                }
              }
            }
          }
        }
        .padding(.horizontal, gridHorizontalPadding)
        .padding(.vertical, 12)
      }
    }
    .scrollDismissesKeyboard(.interactively)
  }

  private var emptySearchState: some View {
    VStack(spacing: 8) {
      Image(systemName: "face.smiling")
        .font(.system(size: 28))
        .foregroundStyle(Theme.iconMuted)
      // Empty search state inside the emoji picker (#201).
      Text("No matching emoji") // septena-lint:allow shell-copy-literal
        .font(.septenaCardTitle)
        .foregroundStyle(Theme.inkPrimary)
      #if os(iOS)
      // Explains direct emoji keyboard input when curated search has no hits (#201).
      Text("Type or paste any emoji from your keyboard above.") // septena-lint:allow shell-copy-literal
        .font(.septenaNotes)
        .foregroundStyle(Theme.inkSecondary)
        .multilineTextAlignment(.center)
      #else
      // Explains Character Viewer fallback when curated search has no hits (#201).
      Text("Use More… to pick any emoji from the Character Viewer.") // septena-lint:allow shell-copy-literal
        .font(.septenaNotes)
        .foregroundStyle(Theme.inkSecondary)
        .multilineTextAlignment(.center)
      #endif
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.vertical, 36)
  }

  private func emojiCell(_ item: CuratedEmoji.Item) -> some View {
    let isCurrent = emoji == item.glyph
    return Button {
      commit(item.glyph)
    } label: {
      Text(item.glyph)
        .font(.system(size: emojiGlyphSize))
        .frame(maxWidth: .infinity, minHeight: cellMinSize)
        .background {
          if isCurrent {
            RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
              .fill(Theme.listSelectionFill)
          }
        }
        .overlay {
          if isCurrent {
            RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
              .strokeBorder(Theme.selectionAccent.opacity(0.45), lineWidth: 1.5)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(item.accessibilityLabel)
  }

  private var sectionSpacing: CGFloat {
    #if os(iOS)
    18
    #else
    14
    #endif
  }

  private var gridHorizontalPadding: CGFloat {
    #if os(iOS)
    16
    #else
    12
    #endif
  }

  private var cellMinSize: CGFloat {
    #if os(iOS)
    46
    #else
    40
    #endif
  }

  private var emojiGlyphSize: CGFloat {
    #if os(iOS)
    28
    #else
    24
    #endif
  }

  // MARK: - Input handling

  private func handleQueryChange(_ value: String) {
    // Any real emoji typed from the iOS emoji keyboard, pasted from the
    // clipboard, or inserted by the macOS Character Viewer commits at once
    // without touching the bound emoji while the user is typing search words.
    if let picked = value.last(where: \.isUserEmoji) {
      commit(String(picked))
    }
  }

  private func handleSubmit() {
    let matches = filteredGroups.flatMap(\.items)
    if matches.count == 1, let only = matches.first {
      commit(only.glyph)
    } else {
      searchFocused = false
    }
  }

  private func commit(_ value: String) {
    guard !hasCommitted else { return }
    hasCommitted = true
    #if os(iOS)
    Haptics.selection()
    #endif
    emoji = value
    query = ""
    onSelect?(value)
    close()
  }

  private func close() {
    searchFocused = false
    dismiss()
    onDismiss?()
  }
}

#if os(iOS)
/// Gives iPad popovers a comfortable default footprint while leaving compact
/// iPhone sheets entirely governed by their presentation detents (so keyboard
/// transitions never fight a fixed height).
private struct RegularPopoverFrame: ViewModifier {
  let isRegular: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isRegular {
      content.frame(minWidth: 320, idealWidth: 360, minHeight: 380, idealHeight: 440)
    } else {
      content
    }
  }
}
#endif

// MARK: - Emoji detection

private extension Character {
  /// True when this grapheme cluster is an emoji (including ZWJ sequences,
  /// skin tones, flags, keycaps, and emoji-presented symbols), while excluding
  /// bare ASCII digits (`0`–`9`), `#`, and `*` that Unicode flags `isEmoji`
  /// only as keycap bases.
  var isUserEmoji: Bool {
    guard let first = unicodeScalars.first else { return false }
    if first.isASCII {
      return first.properties.isEmoji && unicodeScalars.contains { $0.value == 0x20E3 }
    }
    return unicodeScalars.contains { scalar in
      scalar.properties.isEmojiPresentation || scalar.properties.isEmoji
    }
  }
}

// MARK: - Curated catalog

/// The curated glyph set the picker offers, with search keywords per item.
/// Every starter glyph appears in one group below (no cross-group duplicates),
/// supplemented with common Area/Project glyphs.
enum CuratedEmoji {
  struct Item: Identifiable, Hashable {
    let glyph: String
    let keywords: String
    var id: String { glyph }

    var accessibilityLabel: String {
      if let first = keywords.split(separator: " ").first {
        return "\(glyph) \(first)"
      }
      return glyph
    }
  }

  struct Group: Identifiable {
    let id: String
    let title: String
    let items: [Item]
  }

  static let groups: [Group] = [
    Group(id: "focus", title: "Work & focus", items: [
      Item(glyph: "💻", keywords: "work laptop computer code tech mac dev"),
      Item(glyph: "💼", keywords: "work business briefcase job career office"),
      Item(glyph: "🚀", keywords: "launch rocket startup project ship space"),
      Item(glyph: "🎯", keywords: "goal target focus aim priority"),
      Item(glyph: "💡", keywords: "idea light bulb insight creative think"),
      Item(glyph: "📚", keywords: "books study learn reading library school"),
      Item(glyph: "📅", keywords: "calendar schedule date plan event"),
      Item(glyph: "⏰", keywords: "alarm clock time reminder morning"),
      Item(glyph: "📌", keywords: "pin note important bookmark"),
      Item(glyph: "🗂️", keywords: "files folder organize archive admin"),
      Item(glyph: "💰", keywords: "money finance budget bank cash savings"),
      Item(glyph: "🧮", keywords: "math numbers accounting tax finance"),
      Item(glyph: "📊", keywords: "chart analytics metrics data report"),
      Item(glyph: "🔬", keywords: "science research lab experiment"),
      Item(glyph: "🎓", keywords: "education graduation degree study school"),
      Item(glyph: "📞", keywords: "phone call contact meeting"),
      Item(glyph: "✉️", keywords: "mail email inbox letter message"),
      Item(glyph: "🔔", keywords: "bell alert notification reminder"),
      Item(glyph: "🏷️", keywords: "tag label price category"),
      Item(glyph: "🎨", keywords: "art design paint draw creative craft"),
      Item(glyph: "🎵", keywords: "music audio song instrument playlist"),
      Item(glyph: "✈️", keywords: "travel flight airplane trip vacation"),
    ]),
    Group(id: "routine", title: "Routine", items: [
      Item(glyph: "💧", keywords: "water drink hydrate drop"),
      Item(glyph: "🏃", keywords: "run running jog cardio sprint exercise"),
      Item(glyph: "🚶", keywords: "walk walking steps stroll"),
      Item(glyph: "🧘", keywords: "meditate meditation yoga mindfulness calm"),
      Item(glyph: "🤸", keywords: "stretch flexibility gymnastics mobility"),
      Item(glyph: "🛌", keywords: "sleep bed rest nap night"),
      Item(glyph: "🚿", keywords: "shower bath wash morning"),
      Item(glyph: "🪥", keywords: "brush teeth dental hygiene"),
      Item(glyph: "📖", keywords: "read book reading study journal"),
      Item(glyph: "✍️", keywords: "write writing journal notes essay"),
      Item(glyph: "📝", keywords: "memo notes list draft journal"),
      Item(glyph: "🗣️", keywords: "speak language practice voice talk"),
      Item(glyph: "📵", keywords: "no phone detox offline screen break"),
      Item(glyph: "☕", keywords: "coffee cafe espresso tea morning"),
      Item(glyph: "🎧", keywords: "headphones podcast music focus listen"),
      Item(glyph: "🙏", keywords: "gratitude pray thanks calm"),
    ]),
    Group(id: "home", title: "Home & chores", items: [
      Item(glyph: "🏠", keywords: "home house family living personal"),
      Item(glyph: "🛒", keywords: "shop shopping groceries cart errands"),
      Item(glyph: "📦", keywords: "package box delivery shipping move"),
      Item(glyph: "🚗", keywords: "car drive auto vehicle commute"),
      Item(glyph: "🍽️", keywords: "dishes dinner kitchen plate meal"),
      Item(glyph: "🗑️", keywords: "trash garbage bin clean tidy"),
      Item(glyph: "🧺", keywords: "laundry clothes basket wash"),
      Item(glyph: "🧹", keywords: "broom sweep clean floor chores"),
      Item(glyph: "🧽", keywords: "sponge scrub wash dishes clean"),
      Item(glyph: "🧼", keywords: "soap wash clean hygiene"),
      Item(glyph: "🧻", keywords: "paper bathroom supplies"),
      Item(glyph: "🛁", keywords: "bath tub relax soak clean"),
      Item(glyph: "🛏️", keywords: "bed bedroom sheets sleep"),
      Item(glyph: "🪣", keywords: "bucket mop clean water"),
      Item(glyph: "🧊", keywords: "ice fridge cold freezer"),
      Item(glyph: "🪟", keywords: "window glass clean view"),
      Item(glyph: "🪴", keywords: "plant pot water indoor garden"),
      Item(glyph: "🛋️", keywords: "couch sofa living room furniture"),
      Item(glyph: "🚪", keywords: "door entry room home"),
      Item(glyph: "🔧", keywords: "wrench fix repair tool maintenance"),
      Item(glyph: "🪛", keywords: "screwdriver fix repair diy tool"),
      Item(glyph: "⚙️", keywords: "gear settings system config maintenance"),
      Item(glyph: "🧯", keywords: "safety fire extinguisher emergency"),
      Item(glyph: "🔌", keywords: "plug power electric cable charge"),
    ]),
    Group(id: "health", title: "Health & body", items: [
      Item(glyph: "💊", keywords: "pill medicine vitamin supplement health"),
      Item(glyph: "💉", keywords: "vaccine injection shot doctor medical"),
      Item(glyph: "🩹", keywords: "bandage injury heal care first aid"),
      Item(glyph: "🩺", keywords: "doctor checkup clinic medical health"),
      Item(glyph: "🌡️", keywords: "temperature fever sick thermometer"),
      Item(glyph: "💪", keywords: "strength muscle gym workout fitness"),
      Item(glyph: "🧠", keywords: "brain mind mental focus memory"),
      Item(glyph: "🫀", keywords: "heart organ cardio health pulse"),
      Item(glyph: "🫁", keywords: "lungs breath breathing cardio"),
      Item(glyph: "🦴", keywords: "bone joint skeleton"),
      Item(glyph: "🦵", keywords: "leg knee run walk"),
      Item(glyph: "🦷", keywords: "tooth dentist dental"),
      Item(glyph: "👁️", keywords: "eye vision optometrist"),
      Item(glyph: "👂", keywords: "ear hearing listen"),
      Item(glyph: "👃", keywords: "nose smell allergy"),
      Item(glyph: "🩸", keywords: "blood test lab donation"),
      Item(glyph: "🦠", keywords: "germ virus cold flu sick"),
      Item(glyph: "🧬", keywords: "dna genetics biology health"),
      Item(glyph: "🤕", keywords: "headache pain hurt sick"),
      Item(glyph: "🤢", keywords: "nausea stomach sick"),
      Item(glyph: "🤧", keywords: "sneeze allergy cold tissue"),
      Item(glyph: "😷", keywords: "mask sick flu doctor"),
      Item(glyph: "🪫", keywords: "low battery tired fatigue energy"),
      Item(glyph: "🩻", keywords: "xray scan medical doctor"),
    ]),
    Group(id: "food", title: "Food & drink", items: [
      Item(glyph: "🍎", keywords: "apple fruit snack healthy"),
      Item(glyph: "🍌", keywords: "banana fruit potassium snack"),
      Item(glyph: "🍓", keywords: "strawberry berry fruit sweet"),
      Item(glyph: "🥑", keywords: "avocado healthy fat brunch"),
      Item(glyph: "🥦", keywords: "broccoli vegetable greens healthy"),
      Item(glyph: "🥕", keywords: "carrot vegetable snack cook"),
      Item(glyph: "🥗", keywords: "salad lunch greens healthy meal"),
      Item(glyph: "🍞", keywords: "bread toast bakery carbs"),
      Item(glyph: "🍚", keywords: "rice grain bowl dinner"),
      Item(glyph: "🍗", keywords: "chicken protein meat dinner"),
      Item(glyph: "🥩", keywords: "steak beef protein meat"),
      Item(glyph: "🥚", keywords: "egg breakfast protein"),
      Item(glyph: "🐟", keywords: "fish salmon seafood omega protein"),
      Item(glyph: "🥛", keywords: "milk dairy calcium drink"),
      Item(glyph: "🧀", keywords: "cheese dairy snack"),
      Item(glyph: "🥜", keywords: "nuts peanuts protein snack"),
      Item(glyph: "🍳", keywords: "cook cooking frying pan breakfast"),
      Item(glyph: "🍵", keywords: "tea matcha green hot drink"),
      Item(glyph: "🧃", keywords: "juice drink box"),
      Item(glyph: "🍫", keywords: "chocolate sweet dessert treat"),
      Item(glyph: "🍯", keywords: "honey sweet natural"),
      Item(glyph: "🧂", keywords: "salt seasoning electrolytes"),
      Item(glyph: "🌾", keywords: "grain wheat oats fiber"),
    ]),
    Group(id: "activity", title: "Activity & sport", items: [
      Item(glyph: "🏋️", keywords: "gym weights lift workout strength"),
      Item(glyph: "🚴", keywords: "bike cycling bicycle ride cardio"),
      Item(glyph: "🏊", keywords: "swim swimming pool laps water"),
      Item(glyph: "🧗", keywords: "climb climbing boulder outdoor"),
      Item(glyph: "⛹️", keywords: "basketball bounce sport play"),
      Item(glyph: "🤾", keywords: "handball sport play active"),
      Item(glyph: "🥊", keywords: "boxing sparring workout punch"),
      Item(glyph: "⚽", keywords: "soccer football ball sport"),
      Item(glyph: "🏀", keywords: "basketball hoops ball sport"),
      Item(glyph: "🎾", keywords: "tennis racket court sport"),
      Item(glyph: "🏆", keywords: "trophy win award achievement"),
      Item(glyph: "🥾", keywords: "hike hiking trail boot outdoor"),
      Item(glyph: "🏅", keywords: "medal race finish award"),
    ]),
    Group(id: "nature", title: "Nature & life", items: [
      Item(glyph: "☀️", keywords: "sun sunny day morning summer bright"),
      Item(glyph: "🌙", keywords: "moon night evening sleep"),
      Item(glyph: "⭐", keywords: "star favorite top highlight"),
      Item(glyph: "🔥", keywords: "fire flame streak hot urgent"),
      Item(glyph: "💨", keywords: "wind fast air breeze"),
      Item(glyph: "🌀", keywords: "spiral cyclone dizzy storm"),
      Item(glyph: "🌫️", keywords: "fog mist weather cloud"),
      Item(glyph: "🌧️", keywords: "rain weather umbrella storm"),
      Item(glyph: "❄️", keywords: "snow winter cold ice"),
      Item(glyph: "🌊", keywords: "ocean wave beach sea surf"),
      Item(glyph: "🌱", keywords: "seedling grow growth sprout garden"),
      Item(glyph: "🌿", keywords: "herb leaf nature green plant"),
      Item(glyph: "🌸", keywords: "flower blossom spring pink"),
      Item(glyph: "🍂", keywords: "autumn fall leaf season"),
      Item(glyph: "🌲", keywords: "tree forest pine camping nature"),
      Item(glyph: "⛰️", keywords: "mountain hike peak outdoor"),
      Item(glyph: "🪨", keywords: "rock stone solid ground"),
      Item(glyph: "🐾", keywords: "pet dog cat animal paw"),
      Item(glyph: "🎈", keywords: "balloon party birthday fun"),
    ]),
    Group(id: "symbols", title: "Symbols & mood", items: [
      Item(glyph: "❤️", keywords: "heart love red favorite care family"),
      Item(glyph: "🧡", keywords: "heart orange love warm"),
      Item(glyph: "💛", keywords: "heart yellow love happy"),
      Item(glyph: "💚", keywords: "heart green love health"),
      Item(glyph: "💙", keywords: "heart blue love calm"),
      Item(glyph: "💜", keywords: "heart purple love"),
      Item(glyph: "✨", keywords: "sparkles magic clean shine new"),
      Item(glyph: "🎉", keywords: "party celebrate celebration confetti"),
      Item(glyph: "✅", keywords: "check done complete green ok"),
      Item(glyph: "⚠️", keywords: "warning caution alert important"),
      Item(glyph: "♻️", keywords: "recycle green eco repeat"),
      Item(glyph: "➕", keywords: "plus add more positive"),
      Item(glyph: "🔁", keywords: "repeat loop recurring routine"),
      Item(glyph: "❓", keywords: "question help unknown ask"),
      Item(glyph: "🔆", keywords: "bright sun light high"),
      Item(glyph: "🌟", keywords: "glowing star sparkle special"),
      Item(glyph: "🏁", keywords: "finish flag goal race done"),
    ]),
  ]

  /// Pre-folded search haystack per glyph: curated keywords + group title +
  /// Unicode character name (so both everyday words and official Unicode names
  /// match without recomputing `applyingTransform` per keystroke).
  private static let searchIndex: [String: String] = {
    var table: [String: String] = [:]
    for group in groups {
      for item in group.items {
        let unicodeName = item.glyph.applyingTransform(.toUnicodeName, reverse: false)?
          .replacingOccurrences(of: "\\N{", with: " ")
          .replacingOccurrences(of: "}", with: " ") ?? ""
        table[item.glyph] = "\(item.keywords) \(group.title) \(unicodeName)"
          .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      }
    }
    return table
  }()

  static func filter(query: String) -> [Group] {
    guard !query.isEmpty else { return groups }
    let tokens = query
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard !tokens.isEmpty else { return groups }

    return groups.compactMap { group in
      let matches = group.items.filter { item in
        let haystack = searchIndex[item.glyph] ?? ""
        return tokens.allSatisfy { haystack.contains($0) }
      }
      return matches.isEmpty ? nil : Group(id: group.id, title: group.title, items: matches)
    }
  }
}
