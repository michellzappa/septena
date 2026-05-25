import SwiftUI

// AddMoodPage — single-screen circumplex picker.
//
// All 36 emotions are arrayed on one 6×6 grid that matches Russell's
// affect circumplex: X axis = valence (left unpleasant → right pleasant),
// Y axis = arousal (top high-energy → bottom low-energy). Quadrants are
// colored regions of the same canvas (HAN red top-left, HAP yellow
// top-right, LAN blue bottom-left, LAP green bottom-right). One tap
// commits; drag scrubs across the canvas with a haptic on each change
// of the highlighted emotion.
//
// Replaces an earlier 2-step picker (quadrant card → emotion grid) that
// added a tap and split the model across two screens. The single canvas
// also doubles as a visual explanation of the underlying model — users
// see the layout instead of navigating through it.

struct AddMoodPage: View {
  @Environment(\.dismiss) private var dismiss

  var anchorTime: Date = Date()
  var date: String = SeptenaDate.today
  var onLogged: () -> Void = {}

  @State private var selected: MoodEmotion? = nil
  @State private var time: Date
  @State private var note: String = ""
  @State private var editingTime = false

  init(anchorTime: Date = Date(),
       date: String = SeptenaDate.today,
       onLogged: @escaping () -> Void = {}) {
    self.anchorTime = anchorTime
    self.date = date
    self.onLogged = onLogged
    _time = State(initialValue: anchorTime)
  }

  /// All 36 cells in canonical row-major order, top-to-bottom = arousal
  /// 3→1 within HIGH quadrants, then arousal 3→1 within LOW quadrants.
  /// Left-to-right = valence 1→3 within UNPLEASANT quadrants, then
  /// valence 1→3 within PLEASANT quadrants. Computed once.
  private static let cells: [MoodEmotion] = {
    let han = MoodCatalog.grid(for: .han)
    let hap = MoodCatalog.grid(for: .hap)
    let lan = MoodCatalog.grid(for: .lan)
    let lap = MoodCatalog.grid(for: .lap)
    // Row maps for fast assembly:
    func rows(_ q: [MoodEmotion]) -> [[MoodEmotion]] {
      [Array(q[0..<3]), Array(q[3..<6]), Array(q[6..<9])]
    }
    let hanR = rows(han), hapR = rows(hap)
    let lanR = rows(lan), lapR = rows(lap)
    var out: [MoodEmotion] = []
    // Top half — arousal 3 → 1 of HIGH quadrants.
    for r in 0..<3 { out += hanR[r] + hapR[r] }
    // Bottom half — arousal 3 → 1 of LOW quadrants (toward the bottom = quietest).
    for r in 0..<3 { out += lanR[r] + lapR[r] }
    return out
  }()

  private static let cols = 6
  private static let rows = 6

  /// Quadrant at the (col, row) coordinate. Pure geometry — no lookup
  /// through the cells array, so background regions paint correctly
  /// even before a selection is made.
  private func quadrant(col: Int, row: Int) -> MoodQuadrant {
    let leftHalf = col < 3
    let topHalf  = row < 3
    switch (topHalf, leftHalf) {
    case (true,  true):  return .han
    case (true,  false): return .hap
    case (false, true):  return .lan
    case (false, false): return .lap
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          header
          canvas
          detailsForm
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
      }
      .background(Theme.groupedBackground)
      .navigationTitle("How do you feel?")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Log") { save() }
            .disabled(selected == nil)
        }
      }
      .tint(selected?.quadrant.color ?? .accentColor)
    }
  }

  // MARK: - Header (selected emotion preview)

  @ViewBuilder
  private var header: some View {
    if let s = selected {
      VStack(spacing: 4) {
        Text("I'm feeling")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text(s.word)
          .font(.system(.largeTitle, design: .rounded).weight(.bold))
          .foregroundStyle(s.quadrant.color)
        Text(s.quadrant.title)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 4)
      .transition(.opacity)
    } else {
      Text("Tap or drag to pick how you feel")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
  }

  // MARK: - Canvas (circumplex)

  private var canvas: some View {
    GeometryReader { geo in
      let pad: CGFloat = 6
      let cellW = (geo.size.width  - pad * CGFloat(Self.cols + 1)) / CGFloat(Self.cols)
      let cellH = (geo.size.height - pad * CGFloat(Self.rows + 1)) / CGFloat(Self.rows)
      let cellSide = min(cellW, cellH)
      let canvasW = pad + (cellSide + pad) * CGFloat(Self.cols)
      let canvasH = pad + (cellSide + pad) * CGFloat(Self.rows)
      let originX = (geo.size.width  - canvasW) / 2
      let originY = (geo.size.height - canvasH) / 2

      ZStack {
        // Background quadrant regions — soft tint behind their 3×3 area.
        quadrantBackdrop(originX: originX, originY: originY,
                         canvasW: canvasW, canvasH: canvasH)

        // Emotion cells.
        ForEach(Array(Self.cells.enumerated()), id: \.element.id) { idx, emotion in
          let col = idx % Self.cols
          let row = idx / Self.cols
          let x = originX + pad + cellSide / 2 + CGFloat(col) * (cellSide + pad)
          let y = originY + pad + cellSide / 2 + CGFloat(row) * (cellSide + pad)
          EmotionDot(emotion: emotion,
                     isSelected: emotion == selected,
                     side: cellSide)
            .position(x: x, y: y)
        }

        // Axis labels — tiny, on the canvas edges.
        axisLabels(originX: originX, originY: originY,
                   canvasW: canvasW, canvasH: canvasH)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            updateSelection(at: value.location,
                            originX: originX, originY: originY,
                            cellSide: cellSide, pad: pad)
          }
      )
    }
    .aspectRatio(1, contentMode: .fit)
    .frame(maxWidth: 500)
    .animation(.snappy(duration: 0.18), value: selected)
  }

  /// Soft quadrant backdrop — a 2×2 of translucent rounded rectangles
  /// sized to cover the 3×3 cell block of each quadrant. Reinforces the
  /// circumplex model without competing with the emotion dots.
  private func quadrantBackdrop(originX: CGFloat, originY: CGFloat,
                                canvasW: CGFloat, canvasH: CGFloat) -> some View {
    let halfW = canvasW / 2
    let halfH = canvasH / 2
    return ZStack {
      backdropRect(MoodQuadrant.han, x: originX,         y: originY,         w: halfW, h: halfH)
      backdropRect(MoodQuadrant.hap, x: originX + halfW, y: originY,         w: halfW, h: halfH)
      backdropRect(MoodQuadrant.lan, x: originX,         y: originY + halfH, w: halfW, h: halfH)
      backdropRect(MoodQuadrant.lap, x: originX + halfW, y: originY + halfH, w: halfW, h: halfH)
    }
  }

  private func backdropRect(_ q: MoodQuadrant,
                            x: CGFloat, y: CGFloat,
                            w: CGFloat, h: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 14)
      .fill(q.color.opacity(0.12))
      .frame(width: w - 2, height: h - 2)
      .position(x: x + w / 2, y: y + h / 2)
  }

  private func axisLabels(originX: CGFloat, originY: CGFloat,
                          canvasW: CGFloat, canvasH: CGFloat) -> some View {
    ZStack {
      Text("HIGH ENERGY")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .position(x: originX + canvasW / 2, y: originY - 2)
      Text("LOW ENERGY")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .position(x: originX + canvasW / 2, y: originY + canvasH + 2)
      Text("UNPLEASANT")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .rotationEffect(.degrees(-90))
        .position(x: originX - 4, y: originY + canvasH / 2)
      Text("PLEASANT")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .rotationEffect(.degrees(90))
        .position(x: originX + canvasW + 4, y: originY + canvasH / 2)
    }
  }

  /// Hit-test the drag location against the grid. Maps the point into
  /// (col, row) by quantizing — that's the cell whose center is closest
  /// for any point inside the canvas. Points outside the canvas leave
  /// the current selection alone (so a slip off the edge doesn't blank
  /// out the highlight).
  private func updateSelection(at point: CGPoint,
                               originX: CGFloat, originY: CGFloat,
                               cellSide: CGFloat, pad: CGFloat) {
    let relX = point.x - originX
    let relY = point.y - originY
    guard relX >= 0, relY >= 0 else { return }
    let stride = cellSide + pad
    let col = Int(relX / stride)
    let row = Int(relY / stride)
    guard (0..<Self.cols).contains(col), (0..<Self.rows).contains(row) else { return }
    let idx = row * Self.cols + col
    guard idx < Self.cells.count else { return }
    let candidate = Self.cells[idx]
    if candidate != selected {
      selected = candidate
      Haptics.tick()
    }
  }

  // MARK: - Details (time + note)

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

  private var mood: MoodMutator { SeptenaServices.shared.moodMutator }

  private func save() {
    guard let s = selected else { return }
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
    dismiss()
  }
}

// MARK: - Emotion dot

private struct EmotionDot: View {
  let emotion: MoodEmotion
  let isSelected: Bool
  let side: CGFloat

  var body: some View {
    ZStack {
      Circle()
        .fill(emotion.quadrant.color.opacity(isSelected ? 0.95 : 0.78))
        .overlay(
          Circle().strokeBorder(
            isSelected ? Color.white : Color.clear,
            lineWidth: isSelected ? 2.5 : 0
          )
        )
        .shadow(color: isSelected ? .black.opacity(0.25) : .clear,
                radius: isSelected ? 4 : 0)
      Text(emotion.word)
        .font(.system(size: dynamicFontSize, design: .rounded).weight(.semibold))
        .foregroundStyle(.black.opacity(0.88))
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.6)
        .lineLimit(2)
        .padding(.horizontal, 3)
    }
    .frame(width: side, height: side)
    .scaleEffect(isSelected ? 1.18 : 1.0)
    // Don't intercept hits — the canvas DragGesture handles selection.
    .allowsHitTesting(false)
  }

  private var dynamicFontSize: CGFloat {
    // 36 emotion words; longest is "Disappointed" / "Discouraged" /
    // "Despondent" at 12 chars. Scale font with cell side so the canvas
    // legibly accommodates small phones and iPad alike.
    max(8, min(13, side * 0.22))
  }
}
