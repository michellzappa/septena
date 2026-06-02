import SwiftUI

// AddMoodPage — two-step check-in with native iOS bubble animation.
//
// Step 1: tap one of four quadrant bubbles arranged in a 2×2. Logging
//         is allowed here — the quadrant alone is a valid check-in for
//         users who just want to register "I feel bad" and move on.
// Step 2: the selected quadrant bubble grows via matched-geometry to
//         fill the canvas and reveal nine emotion sub-bubbles cascading
//         in from center. Pick one to attach a specific word.
//
// Animation principles in play here:
// • Per-quadrant spring physics (see MoodQuadrant.spring). HAP pops,
//   LAN settles — the animation embodies the affect.
// • Idle breath on the four bubbles, phase-offset per quadrant so they
//   never pulse in lockstep.
// • Press-shrink feedback before the expand starts.
// • Staggered emotion-chip cascade from center outward.
// • Header word pop-in when the selected emotion changes.
// • Per-quadrant Log flourish (.commitFlourish, motion from
//   MoodQuadrant.commitMotion) plays as the page dismisses.

struct AddMoodPage: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.a11yMotion) private var motion

  var anchorTime: Date = Date()
  var date: String = SeptenaDate.today
  var onLogged: () -> Void = {}

  @State private var quadrant: MoodQuadrant? = nil
  @State private var emotion: MoodEmotion? = nil
  @State private var time: Date
  @State private var note: String = ""
  @State private var editingTime = false
  /// Bumped on save to drive the `.commitFlourish` modifier. The flourish
  /// runs during the dismiss tail so the user sees the affirmation before
  /// the sheet goes away.
  @State private var commitTrigger: Int = 0
  /// Quadrant frozen at commit time so the in-flight animation outlives
  /// any state changes the dismissal triggers.
  @State private var committingQuadrant: MoodQuadrant? = nil

  init(anchorTime: Date = Date(),
       date: String = SeptenaDate.today,
       onLogged: @escaping () -> Void = {}) {
    self.anchorTime = anchorTime
    self.date = date
    self.onLogged = onLogged
    _time = State(initialValue: anchorTime)
  }

  private var emotionToLog: MoodEmotion? {
    if let emotion { return emotion }
    guard let quadrant else { return nil }
    return MoodCatalog.grid(for: quadrant).first {
      $0.arousal == 2 && $0.valence == 2
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          header
          canvas
          if quadrant != nil { detailsForm }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
      }
      .background(Theme.groupedBackground)
      .navigationTitle(quadrant == nil
                       ? "How do you feel?"
                       : (quadrant?.title ?? ""))
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if quadrant == nil {
            Button("Cancel") { dismiss() }
          } else {
            Button {
              motion.run(quadrant?.expandSpring ?? .spring) {
                emotion = nil
                quadrant = nil
              }
              A11y.screenChanged(focused: "How do you feel right now?")
            } label: {
              Label("Back", systemImage: "chevron.left")
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Log") { save() }
            .disabled(emotionToLog == nil)
        }
      }
      .tint(quadrant?.color ?? .accentColor)
      // Blocking commit flourish: plays in-sheet during the brief delay
      // before dismiss. The motion matches the logged affect — see
      // MoodQuadrant.commitMotion. Inert until commitTrigger is bumped.
      .commitFlourish(motion: committingQuadrant?.commitMotion ?? .burst,
                      accent: committingQuadrant?.color ?? .accentColor,
                      trigger: commitTrigger) {
        dismiss()
      }
    }
  }

  // MARK: - Header (selected preview, fixed-height envelope)

  private var header: some View {
    ZStack {
      if let emotion {
        VStack(spacing: 4) {
          Text("I'm feeling")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(emotion.word)
            .font(.system(.largeTitle, design: .rounded).weight(.bold))
            .foregroundStyle(emotion.quadrant.color)
            // Pop-in: scale-spring keyed by the emotion word, so each
            // pick produces a fresh bounce rather than a cross-fade.
            .id(emotion.word)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
          Text(emotion.quadrant.title)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let quadrant {
        VStack(spacing: 4) {
          Text("I'm feeling")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(quadrant.title)
            .font(.system(.title2, design: .rounded).weight(.semibold))
            .foregroundStyle(quadrant.color)
            .multilineTextAlignment(.center)
          Text("Tap a word to refine, or just Log")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
      } else {
        Text("Tap how you feel right now")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .transition(.opacity)
      }
    }
    .frame(height: 84)
    .frame(maxWidth: .infinity)
    .padding(.top, 4)
    .animation(.spring(duration: 0.32, bounce: 0.35), value: emotion)
    .animation(.snappy(duration: 0.2), value: quadrant)
  }

  // MARK: - Canvas
  //
  // One unified view tree for both steps so the transition is a true
  // transform (scale + reposition) rather than a subtree swap with
  // crossfade. The four bubbles always exist; the picked one scales
  // outward to fill the canvas while the other three shrink to the
  // canvas center. The 9 emotion chips fade in on top of the now-full
  // bubble.

  private var canvas: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      MoodCanvas(side: side,
                 quadrant: quadrant,
                 selectedEmotion: emotion,
                 onPickQuadrant: { picked in
                   motion.run(picked.expandSpring) {
                     quadrant = picked
                   }
                   Haptics.tick()
                   // VoiceOver can't see the expand transition or the
                   // emotion grid blooming in — announce the new step so
                   // the user knows refinement (or Log) is now available.
                   A11y.screenChanged(
                     focused: "\(picked.title). Choose a feeling, or Log to record the quadrant.")
                 },
                 onPickEmotion: { picked in
                   emotion = picked
                   Haptics.tick()
                   // The header updates to "I'm feeling X" visually; mirror
                   // that for VoiceOver, which can't perceive the pop-in.
                   A11y.announce("\(picked.word). Log to save.")
                 })
        .frame(width: geo.size.width, height: geo.size.height)
    }
    .aspectRatio(1, contentMode: .fit)
    .frame(maxWidth: 500)
  }

  // MARK: - Details

  @ViewBuilder
  private var detailsForm: some View {
    VStack(alignment: .leading, spacing: 10) {
      timeChip
      VStack(alignment: .leading, spacing: 6) {
        Text("Note").font(.caption).foregroundStyle(.secondary)
        TextField("What's on your mind?", text: $note, axis: .vertical)
          .lineLimit(1...4)
          .padding(10)
          .background(RoundedRectangle(cornerRadius: 10).fill(.thinMaterial))
      }
    }
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  private var timeChip: some View {
    HStack(spacing: 8) {
      Image(systemName: "clock")
        .font(.caption)
        .foregroundStyle(.secondary)
      if editingTime {
        DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
          .labelsHidden()
        Button("Done") { editingTime = false }
          .font(.caption.weight(.medium))
      } else {
        Text(prettyTime(time))
          .font(.subheadline.monospacedDigit())
        Button {
          editingTime = true
        } label: {
          Text("Edit")
            .font(.caption.weight(.medium))
        }
      }
      Spacer()
    }
    .padding(.vertical, 4)
  }

  private func prettyTime(_ d: Date) -> String {
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
    return fmt.string(from: d)
  }

  // MARK: - Save
  //
  // 1. Write to the mutator immediately so data is persisted regardless
  //    of what happens visually.
  // 2. Bump the commit trigger so MoodCommitAnimation fires.
  // 3. Wait long enough for the animation to register on the user, then
  //    dismiss. ~600ms is the sweet spot — long enough to *feel*, short
  //    enough not to delay the next interaction.

  private var mood: MoodMutator { SeptenaServices.shared.moodMutator }

  private func save() {
    guard let s = emotionToLog else { return }
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
    let hhmmss = fmt.string(from: time)
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    mood.logEntry(date: date,
                  time: hhmmss,
                  quadrant: s.quadrant.rawValue,
                  arousal: s.arousal,
                  valence: s.valence,
                  emotion: s.word,
                  note: trimmed.isEmpty ? nil : trimmed)
    Haptics.success()
    onLogged()

    // Freeze the affect and bump the trigger. The `.commitFlourish`
    // modifier plays the matching motion in-sheet, then dismisses — the
    // play-then-dismiss timing lives there, shared with every blocking
    // log site.
    committingQuadrant = s.quadrant
    commitTrigger &+= 1
  }
}

// MARK: - Unified canvas
//
// The whole picker is one DragGesture. Three flows it supports, all in
// a single continuous touch:
//
// • Tap a quadrant (short press): zooms into the 3×3, releases finger,
//   user can then tap a chip (or just hit Log for the center cell).
// • Press-and-hold a quadrant: after ~220ms the canvas zooms while the
//   user is still holding. Their finger lands on the quadrant's
//   signature pole emotion. Drag inward to pick a different cell;
//   release commits the highlighted emotion.
// • Already in step 2 from a previous tap: dragging across chips
//   updates the highlight; release commits.
//
// The hold-to-zoom + drag-to-pick path is the iOS character-picker
// pattern: one motion goes from coarse to fine.

private struct MoodCanvas: View {
  let side: CGFloat
  let quadrant: MoodQuadrant?
  let selectedEmotion: MoodEmotion?
  let onPickQuadrant: (MoodQuadrant) -> Void
  let onPickEmotion: (MoodEmotion) -> Void

  private static let quadrants: [MoodQuadrant] = [.han, .hap, .lan, .lap]

  /// How long the user has to keep their finger down before the zoom
  /// fires automatically. Short enough that a hold-and-drag feels
  /// continuous; long enough that a quick tap-release doesn't trigger
  /// the deep flow.
  private static let holdThreshold: TimeInterval = 0.22

  // Press tracking — all transient state for the active gesture.
  @State private var pressedQuadrant: MoodQuadrant? = nil
  @State private var pressStart: Date? = nil
  @State private var holdTask: Task<Void, Never>? = nil
  @State private var hoveredEmotion: MoodEmotion? = nil

  private var cellSide: CGFloat { side / 2 - 8 }
  private var fullScale: CGFloat { (side - 8) / cellSide }

  var body: some View {
    ZStack {
      ForEach(Self.quadrants, id: \.self) { q in
        QuadrantBubble(quadrant: q,
                       side: cellSide,
                       isPressed: pressedQuadrant == q && quadrant == nil,
                       breathe: quadrant == nil && pressedQuadrant != q,
                       // True while this bubble is the one zooming into
                       // the canvas. Drives the title/blurb fade so the
                       // text doesn't end up huge on the full-size bubble.
                       isExpanding: quadrant == q)
          .scaleEffect(scale(for: q))
          .opacity(opacity(for: q))
          .position(position(for: q))
          .zIndex(quadrant == q ? 1 : 0)
      }

      if let q = quadrant {
        EmotionChipsOverlay(quadrant: q,
                            side: side,
                            selected: selectedEmotion,
                            hovered: hoveredEmotion)
          .transition(.opacity)
          .zIndex(2)
      }
    }
    .frame(width: side, height: side)
    .contentShape(Rectangle())
    .gesture(canvasGesture)
    // The canvas is one custom DragGesture over hit-test-disabled visuals,
    // so VoiceOver, Voice Control, Full Keyboard Access, and Switch Control
    // would otherwise find nothing here. Replace it with a real control
    // tree — same `onPick*` callbacks, so there's no behavioral fork
    // between the touch path and the assistive-tech path.
    .accessibilityRepresentation { accessibleControls }
  }

  // MARK: - Assistive-tech representation
  //
  // Mirrors the two-step flow as standard buttons:
  //   • Step 1 → four quadrant buttons (tap zooms in, or Log records the
  //     quadrant alone — same as the touch affordance).
  //   • Step 2 → the nine emotion words as buttons, the committed one
  //     marked selected.
  // Reading order matches the on-screen layout (top-left → bottom-right).

  @ViewBuilder
  private var accessibleControls: some View {
    if let q = quadrant {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(MoodCatalog.grid(for: q)) { emotion in
          Button { onPickEmotion(emotion) } label: { Text(emotion.word) }
            .accessibilityLabel(emotion.word)
            .accessibilityHint("Feeling in \(q.title). Then Log to save.")
            .accessibilityAddTraits(emotion == selectedEmotion ? .isSelected : [])
        }
      }
      .accessibilityLabel("Refine your feeling")
    } else {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Self.quadrants) { q in
          Button { onPickQuadrant(q) } label: { Text(q.title) }
            .accessibilityLabel(q.title)
            .accessibilityHint("\(q.blurb). Opens specific feelings, or Log to record just this.")
        }
      }
      .accessibilityLabel("How do you feel right now?")
    }
  }

  // MARK: - The unified gesture

  private var canvasGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if pressStart == nil {
          // First call of this gesture instance.
          pressStart = .now
          pressedQuadrant = quadrantAt(location: value.startLocation)
          // Schedule auto-zoom for the press-and-hold path.
          if quadrant == nil, let q = pressedQuadrant {
            holdTask?.cancel()
            holdTask = Task { @MainActor in
              let nanos = UInt64(Self.holdThreshold * 1_000_000_000)
              try? await Task.sleep(nanoseconds: nanos)
              if Task.isCancelled { return }
              guard pressStart != nil, quadrant == nil,
                    pressedQuadrant == q else { return }
              withAnimation(q.expandSpring) {
                onPickQuadrant(q)
              }
              Haptics.tick()
            }
          }
        }

        // In step 2, finger position updates the highlighted emotion.
        // Works for both paths: a continuation of the hold-and-drag, and
        // a fresh drag inside step 2 reached via short tap.
        if quadrant != nil {
          let h = emotionAt(location: value.location)
          if h != hoveredEmotion {
            hoveredEmotion = h
            if h != nil { Haptics.tick() }
          }
        }
      }
      .onEnded { _ in
        holdTask?.cancel()
        let elapsed = pressStart.map { Date.now.timeIntervalSince($0) } ?? 0
        let releasedQuadrant = pressedQuadrant
        let releasedHover = hoveredEmotion

        // Reset transient state before triggering the commit so the
        // bubble's "pressed" visual lifts and the gesture is fully
        // settled before we mutate parent state.
        pressStart = nil
        pressedQuadrant = nil
        hoveredEmotion = nil

        if let h = releasedHover {
          // Held + dragged onto an emotion → commit that emotion.
          onPickEmotion(h)
        } else if quadrant == nil,
                  let q = releasedQuadrant,
                  elapsed < Self.holdThreshold {
          // Released before hold fired — fall back to tap-to-zoom.
          withAnimation(q.expandSpring) {
            onPickQuadrant(q)
          }
          Haptics.tick()
        }
      }
  }

  // MARK: - Hit-tests

  /// Which quadrant the location falls in, given the step-1 layout.
  /// Only meaningful before zoom (`quadrant == nil`).
  private func quadrantAt(location: CGPoint) -> MoodQuadrant? {
    guard quadrant == nil else { return nil }
    let leftHalf = location.x < side / 2
    let topHalf  = location.y < side / 2
    switch (topHalf, leftHalf) {
    case (true,  true):  return .han
    case (true,  false): return .hap
    case (false, true):  return .lan
    case (false, false): return .lap
    }
  }

  /// Which emotion cell the location maps to in the 3×3 of step 2.
  /// Returns nil if the finger is outside the chip grid (the user can
  /// drag back to "no selection" by leaving the inner box).
  private func emotionAt(location: CGPoint) -> MoodEmotion? {
    guard let q = quadrant else { return nil }
    let inner = side - 24
    let cellSide = (inner - 12 * 2) / 3
    let inset = (side - inner) / 2
    let pad: CGFloat = 12
    let stride = cellSide + 10
    let relX = location.x - inset - pad
    let relY = location.y - inset - pad
    guard relX >= 0, relY >= 0 else { return nil }
    let col = Int(relX / stride)
    let row = Int(relY / stride)
    guard (0..<3).contains(col), (0..<3).contains(row) else { return nil }
    return MoodCatalog.grid(for: q)[row * 3 + col]
  }

  // MARK: - Per-bubble geometry

  private func scale(for q: MoodQuadrant) -> CGFloat {
    guard let picked = quadrant else { return 1.0 }
    return picked == q ? fullScale : 0.0
  }

  private func opacity(for q: MoodQuadrant) -> Double {
    guard let picked = quadrant else { return 1.0 }
    return picked == q ? 1.0 : 0.0
  }

  private func position(for q: MoodQuadrant) -> CGPoint {
    if quadrant != nil {
      return CGPoint(x: side / 2, y: side / 2)
    }
    return cellOrigin(for: q)
  }

  private func cellOrigin(for q: MoodQuadrant) -> CGPoint {
    let half = side / 2
    let offset = cellSide / 2 + 6
    switch q {
    case .han: return CGPoint(x: half - offset, y: half - offset)
    case .hap: return CGPoint(x: half + offset, y: half - offset)
    case .lan: return CGPoint(x: half - offset, y: half + offset)
    case .lap: return CGPoint(x: half + offset, y: half + offset)
    }
  }
}

private struct QuadrantBubble: View {
  let quadrant: MoodQuadrant
  let side: CGFloat
  /// Driven by MoodCanvas's single gesture — true while the user's
  /// finger is over this bubble in step 1.
  let isPressed: Bool
  /// Idle breath only runs in step 1 and not on the bubble currently
  /// being pressed (the press-shrink takes over). MoodCanvas computes
  /// this so the bubble doesn't have to know about overall state.
  let breathe: Bool
  /// True while this bubble is scaling up to become the canvas. Drives
  /// the title/blurb fade — without it, the text would scale right
  /// along with the bubble and end up huge over the full surface.
  let isExpanding: Bool

  private var breathPhase: Double {
    switch quadrant {
    case .hap: return 0.0
    case .han: return 0.6
    case .lap: return 1.2
    case .lan: return 1.8
    }
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
      let t = ctx.date.timeIntervalSinceReferenceDate
      let phase = (t + breathPhase).truncatingRemainder(dividingBy: 2.4)
      let breath = breathe
        ? 1.0 + 0.025 * sin(phase / 2.4 * .pi * 2)
        : 1.0
      bubble
        .scaleEffect(isPressed ? 0.92 : breath)
        .animation(.spring(duration: 0.18, bounce: 0.0), value: isPressed)
    }
  }

  private var bubble: some View {
    ZStack {
      Circle()
        .fill(
          RadialGradient(colors: [quadrant.color.opacity(0.95),
                                  quadrant.color.opacity(0.55)],
                         center: .center,
                         startRadius: 0,
                         endRadius: side / 2)
        )
      VStack(spacing: 4) {
        Text(quadrant.title)
          .font(.system(.callout, design: .rounded).weight(.semibold))
          .foregroundStyle(.black.opacity(0.85))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 12)
        Text(quadrant.blurb)
          .font(.caption2)
          .foregroundStyle(.black.opacity(0.65))
      }
      // Fade out as the bubble grows into the canvas. Quicker than
      // the expand spring so the text is invisible well before the
      // bubble reaches full size — keeps the visual clean for the
      // chip cascade. Fades back in on Back / collapse.
      .opacity(isExpanding ? 0 : 1)
      .animation(.easeOut(duration: 0.22), value: isExpanding)
    }
    .frame(width: side, height: side)
    // Bubble is purely visual now; the canvas-level gesture handles
    // all input. Disabling hit testing here lets touches pass through
    // even when a bubble is positioned over another (during the zoom
    // transition).
    .allowsHitTesting(false)
  }
}

// MARK: - Step 2: 3×3 emotion chips overlay
//
// Only the chips and a soft dimming layer. The visible "bubble"
// background is provided by the scaled QuadrantBubble underneath in
// MoodCanvas — so the chip overlay is purely additive content on top.

private struct EmotionChipsOverlay: View {
  let quadrant: MoodQuadrant
  let side: CGFloat
  /// Committed selection — set on gesture release. Renders the strong
  /// "this is the picked one" treatment (white outline + shadow).
  let selected: MoodEmotion?
  /// Transient highlight — the cell currently under the user's finger
  /// during a drag. Renders a softer "you would pick this" treatment
  /// (white outline only, no shadow, slightly smaller scale bump).
  let hovered: MoodEmotion?

  private var cells: [MoodEmotion] { MoodCatalog.grid(for: quadrant) }

  var body: some View {
    let inner = side - 24
    let cellSide = (inner - 12 * 2) / 3
    ZStack {
      Circle()
        .fill(.white.opacity(0.25))
        .frame(width: side - 8, height: side - 8)

      VStack(spacing: 10) {
        ForEach(0..<3, id: \.self) { row in
          HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { col in
              let idx = row * 3 + col
              let emotion = cells[idx]
              EmotionChip(emotion: emotion,
                          side: cellSide,
                          isSelected: emotion == selected,
                          isHovered: emotion == hovered,
                          appearDelay: cascadeDelay(row: row, col: col))
            }
          }
        }
      }
      .padding(12)
    }
    .frame(width: side, height: side)
    // Chips don't intercept hits — MoodCanvas's gesture handles
    // everything via hit-testing on location.
    .allowsHitTesting(false)
  }

  /// Chip's distance from the *quadrant's pole corner* — where the
  /// user's finger is at the end of a hold-press, since the pole
  /// corner of the 3×3 always sits in the same canvas corner as the
  /// quadrant did before the zoom. So chips visibly bloom outward
  /// from under the finger.
  ///
  /// Pole corners in (row, col) coordinates of the 3×3:
  ///   HAP → (0, 2)  top-right     (Ecstatic)
  ///   HAN → (0, 0)  top-left      (Enraged)
  ///   LAN → (2, 0)  bottom-left   (Drained)
  ///   LAP → (2, 2)  bottom-right  (Tranquil)
  ///
  /// The pole chip appears first (delay 0); chips Chebyshev-distance
  /// 1 away appear at 60ms; the opposite corner at 120ms.
  private func cascadeDelay(row: Int, col: Int) -> Double {
    let (oRow, oCol): (Int, Int) = {
      switch quadrant {
      case .hap: return (0, 2)
      case .han: return (0, 0)
      case .lan: return (2, 0)
      case .lap: return (2, 2)
      }
    }()
    let dr = abs(row - oRow), dc = abs(col - oCol)
    let ring = max(dr, dc)                   // 0, 1, or 2
    return Double(ring) * 0.06
  }
}

private struct EmotionChip: View {
  let emotion: MoodEmotion
  let side: CGFloat
  /// Strong "this is picked" treatment (committed state).
  let isSelected: Bool
  /// Soft "your finger is on this one" treatment (transient, only
  /// while a drag is in progress and hasn't released yet).
  let isHovered: Bool
  let appearDelay: Double

  @State private var visible = false

  /// Chip fill ramps from white (intensity 0, near the circumplex
  /// center) to a *deep* version of the quadrant color (intensity 1,
  /// at the quadrant's signature pole). Built as three layered circles
  /// — white base, quadrant tint, black overlay — so we get both
  /// saturation *and* lightness varying across the 3×3.
  ///
  /// Why three layers: a pure white→color ramp tops out at quadrant
  /// saturation, which is still light. Adding a black layer that scales
  /// with intensity drags the pole chip into the dark-deep zone (think
  /// "burgundy" vs "tomato red"), so the gradient reads as both
  /// dark→light and saturated→pale.
  private var tintStrength: Double { 0.18 + emotion.intensity * 0.72 }
  private var darkStrength: Double { emotion.intensity * 0.40 }

  /// Text flips white at the dark end of the gradient so it stays
  /// readable against the deepened chip background. Threshold of 0.55
  /// keeps the mid-chips black-on-light (more readable) and only the
  /// truly dark pole-adjacent chips get the white treatment.
  private var textColor: Color {
    emotion.intensity > 0.55
      ? .white.opacity(0.95)
      : .black.opacity(0.85)
  }

  /// Outline + scale treatment. Selected wins over hovered if both
  /// happen to be true (e.g. user re-presses on the already-committed
  /// chip — the selected look is the canonical "you picked me" state).
  private var outlineOpacity: Double {
    if isSelected { return 0.95 }
    if isHovered  { return 0.65 }
    return 0
  }
  private var outlineWidth: CGFloat { isSelected ? 2.5 : 2.0 }
  private var bumpScale: CGFloat {
    if isSelected { return 1.10 }
    if isHovered  { return 1.06 }
    return 1.0
  }

  var body: some View {
    ZStack {
      Circle().fill(.white)
      Circle()
        .fill(emotion.quadrant.color
                .opacity(tintStrength * (isSelected ? 1.15 : 1.0)))
      Circle().fill(.black.opacity(darkStrength))
      Circle()
        .strokeBorder(.white.opacity(outlineOpacity),
                      lineWidth: outlineWidth)
      Text(emotion.word)
        .font(.system(.footnote, design: .rounded).weight(.semibold))
        .foregroundStyle(textColor)
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.7)
        .lineLimit(2)
        .padding(.horizontal, 3)
    }
    .shadow(color: isSelected ? .black.opacity(0.22) : .clear,
            radius: isSelected ? 4 : 0)
    .frame(width: side, height: side)
    .scaleEffect(visible ? bumpScale : 0.5)
    .opacity(visible ? 1 : 0)
    .animation(.snappy(duration: 0.16), value: isSelected)
    .animation(.snappy(duration: 0.12), value: isHovered)
    .onAppear {
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(appearDelay * 1_000_000_000))
        withAnimation(emotion.quadrant.spring) {
          visible = true
        }
      }
    }
  }
}
