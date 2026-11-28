import PhotosUI
import SwiftUI

// The avatar editor (#857): one sheet, three segments in the registry order
// (`avatar.kinds`: Photo, Emoji, Initials), a live preview on top. Opens from
// the avatar in Settings ▸ Account on every device. Saving hands the edit to
// `AvatarStore`, which shows it at once and sends it when online.

struct AvatarEditorSheet: View {
  let name: String
  let isPlus: Bool

  @Environment(\.dismiss) private var dismiss

  @State private var kind: AccountAvatar.Kind
  @State private var color: String?
  @State private var initials: String
  @State private var emoji: String
  @State private var pickedItem: PhotosPickerItem?
  /// The picked image while the crop step is on screen.
  @State private var cropSource: CGImage?
  /// The cropped photo, ready to save.
  @State private var croppedPhoto: CGImage?
  @State private var croppedJPEG: Data?
  @State private var removesPhoto = false
  @State private var problem: AvatarStore.PhotoProblem?

  init(name: String, isPlus: Bool) {
    self.name = name
    self.isPlus = isPlus
    let current = AvatarStore.shared.avatar
    _kind = State(initialValue: current?.kind ?? .initials)
    _color = State(initialValue: RegistryAvatarColor.resolve(current?.color).id)
    _initials = State(initialValue: current?.initials ?? "")
    _emoji = State(initialValue: current?.kind == .emoji ? (current?.emoji ?? "") : "")
    _problem = State(initialValue: AvatarStore.shared.photoProblem)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let cropSource {
          AvatarCropView(image: cropSource, onUse: usePhoto, onCancel: { self.cropSource = nil })
        } else {
          form
        }
      }
      .navigationTitle(RegistryAvatar.title)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(RegistryAvatar.cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(RegistryAvatar.save, action: save)
            .disabled(!canSave)
        }
      }
    }
    // A Mac sheet takes the size of its content; give the form room.
    #if os(macOS)
    .frame(minWidth: 440, minHeight: 560)
    #endif
    .onChange(of: pickedItem) { _, item in
      guard let item else { return }
      Task { await loadPicked(item) }
    }
  }

  // MARK: - Form

  private var form: some View {
    Form {
      Section {
        HStack {
          Spacer(minLength: 0)
          ProfileAvatar(name: name, isPlus: isPlus, size: 96, preview: draft)
          Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        Picker(RegistryAvatar.title, selection: $kind) {
          ForEach(AccountAvatar.Kind.allCases, id: \.self) { kind in
            Text(Self.label(kind)).tag(kind)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      switch kind {
      case .photo: photoSection
      case .emoji: emojiSection
      case .initials: initialsSection
      }
      if kind != .photo { colorSection }
      if let problem {
        Section {
          Text(problem.message)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var photoSection: some View {
    Section {
      PhotosPicker(selection: $pickedItem, matching: .images) {
        Text(RegistryAvatar.choosePhoto)
      }
      if showsRemove {
        Button(RegistryAvatar.removePhoto, role: .destructive) {
          a11yAnimate {
            croppedJPEG = nil
            croppedPhoto = nil
            removesPhoto = true
          }
          Haptics.commit()
        }
      }
    }
  }

  private var emojiSection: some View {
    Section {
      TextField(RegistryAvatar.emoji, text: $emoji, prompt: Text(RegistryAvatar.emojiHint))
        .autocorrectionDisabled()
        .onChange(of: emoji) { _, value in
          let one = Self.lastEmoji(in: value)
          if one != value { emoji = one }
        }
    } footer: {
      Text(RegistryAvatar.emojiHint)
    }
  }

  private var initialsSection: some View {
    Section {
      TextField(RegistryAvatar.initials, text: $initials, prompt: Text(RegistryAvatar.initialsHint))
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.characters)
        #endif
        .onChange(of: initials) { _, value in
          let clean = Self.cleanInitials(value)
          if clean != value { initials = clean }
        }
    }
  }

  private var colorSection: some View {
    Section(RegistryAvatar.color) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 10)], spacing: 10) {
        ForEach(RegistryTokens.avatarColors) { swatch in
          AvatarSwatch(swatch: swatch, isSelected: color == swatch.id) {
            a11yAnimate { color = swatch.id }
            Haptics.selection()
          }
        }
      }
      .padding(.vertical, 4)
    }
  }

  // MARK: - Draft

  private var showsRemove: Bool {
    croppedPhoto != nil || (AvatarStore.shared.hasPhoto && !removesPhoto)
  }

  /// What the preview draws.
  private var draft: AvatarPreview {
    let store = AvatarStore.shared
    let typed = store.avatar?.initials
    switch kind {
    case .photo:
      if let croppedPhoto {
        return AvatarPreview(avatar: AccountAvatar(kind: .photo, color: color, initials: typed, photoId: "draft"),
                             photo: croppedPhoto)
      }
      if removesPhoto || !store.hasPhoto {
        return AvatarPreview(avatar: AccountAvatar(kind: .initials, color: color, initials: typed), photo: nil)
      }
      return AvatarPreview(avatar: store.avatar ?? AccountAvatar(kind: .initials, color: color),
                           photo: store.displayPhoto)
    case .emoji:
      return AvatarPreview(avatar: AccountAvatar(kind: .emoji, color: color, initials: typed,
                                                 emoji: emoji.isEmpty ? nil : emoji),
                           photo: nil)
    case .initials:
      return AvatarPreview(avatar: AccountAvatar(kind: .initials, color: color,
                                                 initials: initials.isEmpty ? nil : initials),
                           photo: nil)
    }
  }

  private var canSave: Bool {
    guard cropSource == nil else { return false }
    switch kind {
    case .photo: return croppedJPEG != nil || removesPhoto
    case .emoji: return !emoji.isEmpty
    case .initials: return true
    }
  }

  // MARK: - Actions

  private func loadPicked(_ item: PhotosPickerItem) async {
    defer { pickedItem = nil }
    guard let data = try? await item.loadTransferable(type: Data.self),
          // Large enough to zoom in; the crop writes `photoSize` pixels.
          let image = AvatarStore.decode(data, maxPixels: RegistryAvatar.photoSize * 4) else {
      problem = .failed
      return
    }
    problem = nil
    cropSource = image
  }

  private func usePhoto(_ jpeg: Data, _ image: CGImage) {
    cropSource = nil
    guard jpeg.count <= RegistryAvatar.maxPhotoBytes else {
      problem = .tooLarge
      Haptics.warning()
      return
    }
    a11yAnimate {
      croppedJPEG = jpeg
      croppedPhoto = image
      removesPhoto = false
      problem = nil
    }
  }

  private func save() {
    let store = AvatarStore.shared
    switch kind {
    case .photo:
      if let croppedJPEG {
        guard store.savePhoto(croppedJPEG) else {
          problem = store.photoProblem
          Haptics.warning()
          return
        }
      } else if removesPhoto {
        store.removePhoto()
      }
    case .emoji:
      store.save(kind: .emoji, color: color, initials: nil, emoji: emoji)
    case .initials:
      // "" clears typed initials: the name gives them again.
      store.save(kind: .initials, color: color, initials: initials, emoji: nil)
    }
    Haptics.success()
    dismiss()
  }

  // MARK: - Text rules (the server checks the same: backend/src/store/avatar.ts)

  static func label(_ kind: AccountAvatar.Kind) -> String {
    switch kind {
    case .photo: return RegistryAvatar.photo
    case .emoji: return RegistryAvatar.emoji
    case .initials: return RegistryAvatar.initials
    }
  }

  /// The last emoji typed, alone. A digit or a letter is not an emoji.
  static func lastEmoji(in text: String) -> String {
    text.last(where: isEmoji).map(String.init) ?? ""
  }

  static func isEmoji(_ c: Character) -> Bool {
    let scalars = c.unicodeScalars
    if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
    return scalars.count > 1 && scalars.contains(where: { $0.properties.isEmoji })
  }

  /// Letters and digits only, uppercased, at most `maxInitials`.
  static func cleanInitials(_ text: String) -> String {
    let kept = String(text.filter { $0.isLetter || $0.isNumber }).uppercased()
    return String(kept.prefix(RegistryAvatar.maxInitials))
  }
}

/// One color in the avatar palette. Selected: a ring in the swatch's own
/// color, the treatment the accent picker uses (AppearancePickerView).
private struct AvatarSwatch: View {
  let swatch: RegistryAvatarColor
  let isSelected: Bool
  let action: () -> Void

  private var fill: Color { AdaptiveColor.dual(light: swatch.lightHex, dark: swatch.darkHex) }

  var body: some View {
    Button(action: action) {
      Circle()
        .fill(fill)
        .frame(width: 28, height: 28)
        .padding(4)
        .overlay(
          Circle().strokeBorder(isSelected ? fill : Color.clear, lineWidth: 2)
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(swatch.name)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

// MARK: - Crop

/// The crop step: the picked image under a circle, drag to move, pinch or
/// the slider to zoom (the slider is the zoom control for a mouse). "Use
/// Photo" writes a square JPEG of `RegistryAvatar.photoSize` pixels.
struct AvatarCropView: View {
  let image: CGImage
  let onUse: (Data, CGImage) -> Void
  let onCancel: () -> Void

  @State private var zoom: CGFloat = 1
  @State private var zoomAtStart: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var offsetAtStart: CGSize = .zero

  private let side: CGFloat = 280
  private static let maxZoom: CGFloat = 4

  private var pixelWidth: CGFloat { CGFloat(image.width) }
  private var pixelHeight: CGFloat { CGFloat(image.height) }
  /// Points per pixel at zoom 1: the short edge fills the square.
  private var fillScale: CGFloat { side / max(min(pixelWidth, pixelHeight), 1) }
  private var shownWidth: CGFloat { pixelWidth * fillScale * zoom }
  private var shownHeight: CGFloat { pixelHeight * fillScale * zoom }

  var body: some View {
    VStack(spacing: 20) {
      Spacer(minLength: 0)
      ZStack {
        Image(decorative: image, scale: 1)
          .resizable()
          .frame(width: shownWidth, height: shownHeight)
          .offset(offset)
        Path { path in
          let square = CGRect(x: 0, y: 0, width: side, height: side)
          path.addRect(square)
          path.addEllipse(in: square.insetBy(dx: 2, dy: 2))
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
        Circle()
          .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
          .padding(2)
          .allowsHitTesting(false)
      }
      .frame(width: side, height: side)
      .clipped()
      .contentShape(Rectangle())
      .gesture(drag)
      .simultaneousGesture(magnify)

      Slider(value: zoomBinding, in: 1...Self.maxZoom)
        .frame(maxWidth: side)
        .accessibilityLabel(RegistryAvatar.cropHint)

      Text(RegistryAvatar.cropHint)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      HStack {
        Button(RegistryAvatar.cancel, action: onCancel)
        Spacer()
        Button(RegistryAvatar.usePhoto, action: render)
          .buttonStyle(.borderedProminent)
      }
      .frame(maxWidth: side)
      Spacer(minLength: 0)
    }
    .padding()
    .frame(maxWidth: .infinity)
  }

  private var drag: some Gesture {
    DragGesture()
      .onChanged { value in
        offset = clamped(CGSize(width: offsetAtStart.width + value.translation.width,
                                height: offsetAtStart.height + value.translation.height))
      }
      .onEnded { _ in offsetAtStart = offset }
  }

  private var magnify: some Gesture {
    MagnifyGesture()
      .onChanged { value in setZoom(zoomAtStart * value.magnification) }
      .onEnded { _ in zoomAtStart = zoom }
  }

  private var zoomBinding: Binding<CGFloat> {
    Binding(
      get: { zoom },
      set: { value in
        setZoom(value)
        zoomAtStart = zoom
      }
    )
  }

  private func setZoom(_ value: CGFloat) {
    zoom = min(max(value, 1), Self.maxZoom)
    offset = clamped(offset)
    offsetAtStart = offset
  }

  /// Keeps the image over the whole square.
  private func clamped(_ value: CGSize) -> CGSize {
    let maxX = max(0, (shownWidth - side) / 2)
    let maxY = max(0, (shownHeight - side) / 2)
    return CGSize(width: min(max(value.width, -maxX), maxX),
                  height: min(max(value.height, -maxY), maxY))
  }

  private func render() {
    let pixelsPerPoint = 1 / (fillScale * zoom)
    let cropSide = side * pixelsPerPoint
    let centerX = pixelWidth / 2 - offset.width * pixelsPerPoint
    let centerY = pixelHeight / 2 - offset.height * pixelsPerPoint
    let bounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
    let rect = CGRect(x: centerX - cropSide / 2, y: centerY - cropSide / 2, width: cropSide, height: cropSide)
      .integral
      .intersection(bounds)
    let out = RegistryAvatar.photoSize
    guard !rect.isEmpty,
          let cropped = image.cropping(to: rect),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      onCancel()
      return
    }
    context.interpolationQuality = .high
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: out, height: out))
    guard let square = context.makeImage() else { onCancel(); return }
    var quality = 0.85
    var data = AvatarStore.jpeg(square, quality: quality)
    while let bytes = data, bytes.count > RegistryAvatar.maxPhotoBytes, quality > 0.4 {
      quality -= 0.15
      data = AvatarStore.jpeg(square, quality: quality)
    }
    guard let data else { onCancel(); return }
    onUse(data, square)
  }
}
