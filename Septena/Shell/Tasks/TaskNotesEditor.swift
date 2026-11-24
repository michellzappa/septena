import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// The task composer's notes field: a plain-text editor with a lightweight
// Markdown awareness layer, plus the platform text views and the styling rules
// behind it. Split out of TaskComposer.swift, which had grown to hold nine
// types — most of this file is NSRegularExpression styling that has nothing to
// do with composing a task.
//
// `TaskMarkdownNotesEditor` is the only entry point; everything below it is
// private to this file.

// MARK: - Markdown-aware task notes editor

/// Plain-text task notes with lightweight Markdown styling while editing.
///
/// This intentionally keeps the raw Markdown markers editable. Styling is only
/// an awareness layer: headings, list/check markers, emphasis, inline code, and
/// links get typographic cues as the user types, while `draft.notes` remains a
/// normal String for persistence and sync.
struct TaskMarkdownNotesEditor: View {
  @Binding var text: String
  @FocusState.Binding var focus: TaskEditFocus?
  /// iOS: shows a keyboard accessory bar with Done, which runs this. SwiftUI's
  /// `.keyboard` toolbar does not reach this UIKit text view, so the bar is
  /// the text view's own `inputAccessoryView`. Nil shows no bar. Ignored on
  /// macOS (no on-screen keyboard).
  var onDone: (() -> Void)? = nil
  /// The smallest height of the field. The task page passes a taller value so
  /// the notes read as a text area and the whole box takes a tap.
  var minHeight: CGFloat = 28
  /// The tallest the field grows before capping and scrolling inside. Inline
  /// cards pass a compact cap so long notes don't take over the card; the task
  /// page passes a taller cap.
  var maxHeight: CGFloat = 360
  /// True when the note overflows `maxHeight` and isn't scrolled to the bottom,
  /// driving a soft bottom fade so truncation is visible without slicing a line.
  @State private var showBottomFade = false

  #if os(iOS)
  @ScaledMetric(relativeTo: .body) private var scaledBodySize: CGFloat = 17
  #endif

  private var bodyFontSize: CGFloat {
    #if os(macOS)
    return SeptenaTypeScale.size(.body)
    #else
    return scaledBodySize
    #endif
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      PlatformMarkdownNotesTextView(
        text: $text,
        isFocused: Binding(
          get: { focus == .notes },
          set: { focused in
            if focused { focus = .notes }
            else if focus == .notes { focus = nil }
          }
        ),
        showBottomFade: $showBottomFade,
        fontSize: bodyFontSize,
        minHeight: minHeight,
        maxHeight: maxHeight,
        onDone: onDone
      )
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .clipped()
      .mask {
        VStack(spacing: 0) {
          Color.black
          LinearGradient(
            colors: [.black, .black.opacity(showBottomFade ? 0 : 1)],
            startPoint: .top,
            endPoint: .bottom
          )
          .frame(height: 24)
        }
      }

      if text.isEmpty {
        Text(verbatim: RegistrySurfaces.taskAttribute("notes").label)
          .font(.septenaTaskTitle)
          .foregroundStyle(.tertiary)
          .allowsHitTesting(false)
      }
    }
    .frame(minHeight: minHeight, alignment: .topLeading)
  }
}

#if os(iOS)
private final class NotesTextView: UITextView {
  var minVisibleHeight: CGFloat = 28
  var maxVisibleHeight: CGFloat = 360
  var onScrollMetricsChange: ((_ isOverflowing: Bool, _ isAtBottom: Bool) -> Void)?
  private var lastMeasuredHeight: CGFloat = 28

  override func layoutSubviews() {
    super.layoutSubviews()
    syncScrollState()
  }

  func measuredHeight(forWidth width: CGFloat) -> CGFloat {
    guard width > 0 else { return minVisibleHeight }
    let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return max(minVisibleHeight, ceil(fitted.height))
  }

  func syncScrollState() {
    guard bounds.width > 0 else { return }
    let measured = measuredHeight(forWidth: bounds.width)
    lastMeasuredHeight = measured
    let overflows = measured > maxVisibleHeight + 0.5
    if isScrollEnabled != overflows {
      let previousOffset = contentOffset
      isScrollEnabled = overflows
      if !overflows {
        contentOffset = .zero
      } else if isFirstResponder {
        contentOffset = previousOffset
        scrollRangeToVisible(selectedRange)
      } else {
        contentOffset = .zero
      }
    }
    reportScrollPosition(isOverflowing: overflows)
  }

  func reportScrollPosition(isOverflowing: Bool? = nil) {
    let overflows = isOverflowing ?? isScrollEnabled
    let atBottom: Bool
    if !overflows {
      atBottom = true
    } else {
      let effectiveContentHeight = max(contentSize.height, lastMeasuredHeight)
      let maxOffsetY = max(0, effectiveContentHeight - bounds.height)
      atBottom = contentOffset.y >= maxOffsetY - 4
    }
    onScrollMetricsChange?(overflows, atBottom)
  }
}

private struct PlatformMarkdownNotesTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  @Binding var showBottomFade: Bool
  let fontSize: CGFloat
  let minHeight: CGFloat
  let maxHeight: CGFloat
  var onDone: (() -> Void)? = nil

  func makeUIView(context: Context) -> NotesTextView {
    let view = NotesTextView()
    view.delegate = context.coordinator
    view.backgroundColor = .clear
    view.isOpaque = false
    view.clipsToBounds = true
    view.isScrollEnabled = false
    view.alwaysBounceVertical = false
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.adjustsFontForContentSizeCategory = false
    view.textDragInteraction?.isEnabled = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.minVisibleHeight = minHeight
    view.maxVisibleHeight = maxHeight
    view.onScrollMetricsChange = { [weak coordinator = context.coordinator] overflows, atBottom in
      coordinator?.handleScrollMetrics(isOverflowing: overflows, isAtBottom: atBottom)
    }
    view.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    view.attributedText = MarkdownNotesStyle.attributed(text, fontSize: fontSize)
    if onDone != nil {
      // A standard accessory toolbar: flexible space, then Done. The action
      // reads the coordinator's CURRENT parent, so it always runs the latest
      // closure SwiftUI handed us, never the one captured at creation.
      let coordinator = context.coordinator
      let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
      bar.items = [
        UIBarButtonItem(systemItem: .flexibleSpace),
        UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in
          coordinator.parent.onDone?()
        })
      ]
      bar.sizeToFit()
      view.inputAccessoryView = bar
    }
    return view
  }

  func updateUIView(_ view: NotesTextView, context: Context) {
    context.coordinator.parent = self
    let limitsChanged = view.minVisibleHeight != minHeight || view.maxVisibleHeight != maxHeight
    view.minVisibleHeight = minHeight
    view.maxVisibleHeight = maxHeight
    view.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)

    if view.text != text {
      context.coordinator.replaceText(in: view, with: text)
    } else if context.coordinator.lastFontSize != fontSize {
      context.coordinator.applyStyle(to: view)
      view.invalidateIntrinsicContentSize()
    } else if limitsChanged {
      view.invalidateIntrinsicContentSize()
    }

    // Act on a CHANGE of the requested focus only. Nothing in SwiftUI is
    // `.focused(_, equals: .notes)`, so SwiftUI can drop `.notes` back to nil
    // right after a tap begins editing. Resigning on that echo closed the
    // keyboard as soon as it opened. A request that turns on raises the
    // keyboard; one that turns off (another field took focus) lowers it.
    let coordinator = context.coordinator
    if isFocused != coordinator.lastRequestedFocus {
      if isFocused, !view.isFirstResponder {
        view.becomeFirstResponder()
      } else if !isFocused, view.isFirstResponder, !coordinator.isEditing {
        view.resignFirstResponder()
      }
      coordinator.lastRequestedFocus = isFocused
    }

    view.syncScrollState()
  }

  func sizeThatFits(_ proposal: ProposedViewSize,
                    uiView: NotesTextView,
                    context: Context) -> CGSize? {
    let width = proposal.width ?? uiView.bounds.width
    guard width > 0 else { return nil }
    let measured = uiView.measuredHeight(forWidth: width)
    return CGSize(width: width, height: min(measured, maxHeight))
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: PlatformMarkdownNotesTextView
    var lastFontSize: CGFloat = 0
    /// The last focus request seen in `updateUIView`.
    var lastRequestedFocus = false
    /// True while UIKit has the text view editing (a tap, not a request).
    var isEditing = false
    private var lastShowBottomFade = false
    private var applying = false

    init(parent: PlatformMarkdownNotesTextView) {
      self.parent = parent
    }

    func handleScrollMetrics(isOverflowing: Bool, isAtBottom: Bool) {
      let nextFade = isOverflowing && !isAtBottom
      guard nextFade != lastShowBottomFade else { return }
      lastShowBottomFade = nextFade
      DispatchQueue.main.async {
        if self.parent.showBottomFade != nextFade {
          self.parent.showBottomFade = nextFade
        }
      }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      guard let notesView = scrollView as? NotesTextView else { return }
      notesView.reportScrollPosition()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
      isEditing = true
      lastRequestedFocus = true
      parent.isFocused = true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      isEditing = false
      lastRequestedFocus = false
      parent.isFocused = false
    }

    func textViewDidChange(_ textView: UITextView) {
      guard !applying else { return }
      parent.text = textView.text
      applyStyle(to: textView)
      textView.invalidateIntrinsicContentSize()
      (textView as? NotesTextView)?.syncScrollState()
    }

    func replaceText(in textView: NotesTextView, with text: String) {
      applying = true
      let selected = textView.selectedRange
      textView.attributedText = MarkdownNotesStyle.attributed(text, fontSize: parent.fontSize)
      textView.selectedRange = clamped(selected, length: textView.textStorage.length)
      textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: parent.fontSize)
      lastFontSize = parent.fontSize
      applying = false
      textView.invalidateIntrinsicContentSize()
      textView.syncScrollState()
    }

    func applyStyle(to textView: UITextView) {
      guard textView.markedTextRange == nil else { return }
      applying = true
      let selected = textView.selectedRange
      MarkdownNotesStyle.apply(to: textView.textStorage,
                               raw: textView.text,
                               fontSize: parent.fontSize)
      textView.selectedRange = clamped(selected, length: textView.textStorage.length)
      textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: parent.fontSize)
      lastFontSize = parent.fontSize
      applying = false
    }

    private func clamped(_ range: NSRange, length: Int) -> NSRange {
      NSRange(location: min(range.location, length),
              length: min(range.length, max(0, length - min(range.location, length))))
    }
  }
}
#elseif os(macOS)
private struct PlatformMarkdownNotesTextView: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  @Binding var showBottomFade: Bool
  let fontSize: CGFloat
  let minHeight: CGFloat
  let maxHeight: CGFloat
  var onDone: (() -> Void)? = nil

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.contentView.postsBoundsChangedNotifications = true

    let textView = NSTextView()
    textView.delegate = context.coordinator
    textView.drawsBackground = false
    textView.isRichText = true
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = CGSize(width: scrollView.bounds.width,
                                                   height: .greatestFiniteMagnitude)
    textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    textView.textStorage?.setAttributedString(MarkdownNotesStyle.attributed(text, fontSize: fontSize))

    scrollView.documentView = textView
    context.coordinator.textView = textView
    context.coordinator.observeScroll(of: scrollView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = context.coordinator.textView else { return }

    textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    textView.textContainer?.containerSize = CGSize(width: max(scrollView.bounds.width, 1),
                                                   height: .greatestFiniteMagnitude)

    if textView.string != text {
      context.coordinator.replaceText(in: textView, with: text)
    } else if context.coordinator.lastFontSize != fontSize {
      context.coordinator.applyStyle(to: textView)
      scrollView.invalidateIntrinsicContentSize()
    }

    if isFocused, textView.window?.firstResponder !== textView {
      if let window = textView.window {
        window.makeFirstResponder(textView)
      } else {
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
      }
    } else if !isFocused, textView.window?.firstResponder === textView {
      textView.window?.makeFirstResponder(nil)
    }

    context.coordinator.syncLayout(for: scrollView)
  }

  func sizeThatFits(_ proposal: ProposedViewSize,
                    nsView scrollView: NSScrollView,
                    context: Context) -> CGSize? {
    guard let textView = context.coordinator.textView else { return nil }
    let width = proposal.width ?? scrollView.bounds.width
    guard width > 0 else { return nil }
    let measured = context.coordinator.measuredHeight(for: textView, width: width)
    return CGSize(width: width, height: min(measured, maxHeight))
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: PlatformMarkdownNotesTextView
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?
    var lastFontSize: CGFloat = 0
    private var lastLayoutWidth: CGFloat = 0
    private var lastMeasuredHeight: CGFloat = 28
    private var lastShowBottomFade = false
    private var applying = false

    init(parent: PlatformMarkdownNotesTextView) {
      self.parent = parent
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    func observeScroll(of scrollView: NSScrollView) {
      self.scrollView = scrollView
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(clipViewBoundsDidChange(_:)),
        name: NSView.boundsDidChangeNotification,
        object: scrollView.contentView
      )
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
      guard let scrollView else { return }
      if abs(scrollView.bounds.width - lastLayoutWidth) > 0.5 {
        syncLayout(for: scrollView)
      } else {
        reportScrollPosition(for: scrollView)
      }
    }

    func textDidBeginEditing(_ notification: Notification) {
      parent.isFocused = true
    }

    func textDidEndEditing(_ notification: Notification) {
      parent.isFocused = false
    }

    func textDidChange(_ notification: Notification) {
      guard !applying, let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
      applyStyle(to: textView)
      if let scrollView = textView.enclosingScrollView {
        scrollView.invalidateIntrinsicContentSize()
        syncLayout(for: scrollView)
      }
    }

    func replaceText(in textView: NSTextView, with text: String) {
      applying = true
      let selected = textView.selectedRange()
      textView.textStorage?.setAttributedString(MarkdownNotesStyle.attributed(text, fontSize: parent.fontSize))
      textView.setSelectedRange(clamped(selected, length: textView.string.utf16.count))
      textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: parent.fontSize)
      lastFontSize = parent.fontSize
      applying = false
      if let scrollView = textView.enclosingScrollView {
        scrollView.invalidateIntrinsicContentSize()
        syncLayout(for: scrollView)
      }
    }

    func applyStyle(to textView: NSTextView) {
      applying = true
      let selected = textView.selectedRange()
      if let storage = textView.textStorage {
        MarkdownNotesStyle.apply(to: storage,
                                 raw: textView.string,
                                 fontSize: parent.fontSize)
      }
      textView.setSelectedRange(clamped(selected, length: textView.string.utf16.count))
      textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: parent.fontSize)
      lastFontSize = parent.fontSize
      applying = false
    }

    func measuredHeight(for textView: NSTextView, width: CGFloat) -> CGFloat {
      let safeWidth = max(width, 1)
      textView.textContainer?.containerSize = CGSize(width: safeWidth,
                                                     height: .greatestFiniteMagnitude)
      if let manager = textView.layoutManager, let container = textView.textContainer {
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return max(parent.minHeight, ceil(used.height + textView.textContainerInset.height))
      }
      return parent.minHeight
    }

    func syncLayout(for scrollView: NSScrollView) {
      guard let textView, scrollView.bounds.width > 0 else { return }
      let width = scrollView.bounds.width
      lastLayoutWidth = width
      let measured = measuredHeight(for: textView, width: width)
      lastMeasuredHeight = measured
      textView.frame.size = CGSize(width: width, height: measured)
      let overflows = measured > parent.maxHeight + 0.5
      scrollView.hasVerticalScroller = overflows
      reportScrollPosition(for: scrollView, isOverflowing: overflows)
    }

    private func reportScrollPosition(for scrollView: NSScrollView, isOverflowing: Bool? = nil) {
      let overflows = isOverflowing ?? scrollView.hasVerticalScroller
      let atBottom: Bool
      if !overflows {
        atBottom = true
      } else {
        let visibleBottom = scrollView.contentView.bounds.maxY
        let docHeight = max(scrollView.documentView?.frame.height ?? 0, lastMeasuredHeight)
        atBottom = visibleBottom >= docHeight - 4
      }
      let nextFade = overflows && !atBottom
      guard nextFade != lastShowBottomFade else { return }
      lastShowBottomFade = nextFade
      DispatchQueue.main.async {
        if self.parent.showBottomFade != nextFade {
          self.parent.showBottomFade = nextFade
        }
      }
    }

    private func clamped(_ range: NSRange, length: Int) -> NSRange {
      NSRange(location: min(range.location, length),
              length: min(range.length, max(0, length - min(range.location, length))))
    }
  }
}
#endif

/// Lightweight Markdown awareness for task notes. Shared by the SwiftUI
/// composer (`TaskMarkdownNotesEditor`) and the AppKit SeptaskKit notes
/// fields — markers stay in the string; only typography changes.
enum MarkdownNotesStyle {
  static func attributed(_ raw: String, fontSize: CGFloat) -> NSAttributedString {
    let attributed = NSMutableAttributedString(string: raw)
    apply(to: attributed, raw: raw, fontSize: fontSize)
    return attributed
  }

  static func apply(to attributed: NSMutableAttributedString,
                    raw: String,
                    fontSize: CGFloat) {
    let full = NSRange(location: 0, length: attributed.length)
    guard full.length > 0 else { return }

    attributed.setAttributes(baseAttributes(fontSize: fontSize), range: full)

    applyLineStyle(#"(?m)^(#{1,3})[ \t]+(.+)$"#, raw: raw, to: attributed) { match in
      let level = max(1, min(3, match.range(at: 1).length))
      let size = fontSize + CGFloat(4 - level)
      attributed.addAttributes([
        .font: platformFont(size: size, weight: .semibold),
        .foregroundColor: primaryColor
      ], range: match.range(at: 2))
      attributed.addAttributes([
        .foregroundColor: secondaryColor,
        .font: platformFont(size: fontSize, weight: .semibold)
      ], range: match.range(at: 1))
    }

    applyLineStyle(#"(?m)^(\s*(?:[-*+]|\d+\.)(?:\s+\[[ xX]\])?\s+)"#, raw: raw, to: attributed) { match in
      attributed.addAttributes([
        .foregroundColor: secondaryColor,
        .font: platformFont(size: fontSize, weight: .semibold)
      ], range: match.range(at: 1))
    }

    applyDelimited(#"(?<!\*)\*\*([^\n*]+?)\*\*(?!\*)"#,
                   delimiterLength: 2,
                   raw: raw,
                   to: attributed) { range in
      attributed.addAttributes([.font: platformFont(size: fontSize, weight: .semibold)],
                               range: range)
    }

    applyDelimited(#"(?<!_)__([^\n_]+?)__(?!_)"#,
                   delimiterLength: 2,
                   raw: raw,
                   to: attributed) { range in
      attributed.addAttributes([.font: platformFont(size: fontSize, weight: .semibold)],
                               range: range)
    }

    applyDelimited(#"(?<!\*)\*([^\n*]+?)\*(?!\*)"#,
                   delimiterLength: 1,
                   raw: raw,
                   to: attributed) { range in
      attributed.addAttributes([.font: italicFont(size: fontSize)], range: range)
    }

    applyDelimited(#"(?<!_)_([^\n_]+?)_(?!_)"#,
                   delimiterLength: 1,
                   raw: raw,
                   to: attributed) { range in
      attributed.addAttributes([.font: italicFont(size: fontSize)], range: range)
    }

    applyDelimited(#"`([^`\n]+?)`"#,
                   delimiterLength: 1,
                   raw: raw,
                   to: attributed) { range in
      attributed.addAttributes([
        .font: monoFont(size: fontSize * 0.92),
        .backgroundColor: codeBackgroundColor
      ], range: range)
    }

    for match in matches(#"\[([^\]\n]+)\]\(([^\)\n]+)\)"#, raw: raw) {
      let label = match.range(at: 1)
      let target = match.range(at: 2)
      guard label.location != NSNotFound, target.location != NSNotFound else { continue }
      attributed.addAttributes([
        .font: platformFont(size: fontSize, weight: .semibold),
        .underlineStyle: NSUnderlineStyle.single.rawValue
      ], range: label)
      attributed.addAttributes([.foregroundColor: secondaryColor], range: target)
    }
  }

  static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 2
    paragraph.paragraphSpacing = 3
    return [
      .font: platformFont(size: fontSize, weight: .regular),
      .foregroundColor: primaryColor,
      .paragraphStyle: paragraph
    ]
  }

  #if os(macOS)
  /// Restyle an AppKit notes view in place, preserving selection and typing
  /// attributes. Call after any external string load and from `textDidChange`.
  static func restyle(_ textView: NSTextView, fontSize: CGFloat) {
    guard let storage = textView.textStorage else { return }
    let selected = textView.selectedRange()
    apply(to: storage, raw: textView.string, fontSize: fontSize)
    let length = textView.string.utf16.count
    let location = min(selected.location, length)
    let lengthLeft = min(selected.length, max(0, length - location))
    textView.setSelectedRange(NSRange(location: location, length: lengthLeft))
    textView.typingAttributes = baseAttributes(fontSize: fontSize)
  }
  #endif

  private static func applyDelimited(_ pattern: String,
                                     delimiterLength: Int,
                                     raw: String,
                                     to attributed: NSMutableAttributedString,
                                     content: (NSRange) -> Void) {
    for match in matches(pattern, raw: raw) {
      let contentRange = match.range(at: 1)
      guard contentRange.location != NSNotFound else { continue }
      content(contentRange)

      let opening = NSRange(location: match.range.location, length: delimiterLength)
      let closing = NSRange(location: match.range.location + match.range.length - delimiterLength,
                            length: delimiterLength)
      attributed.addAttributes([.foregroundColor: secondaryColor], range: opening)
      attributed.addAttributes([.foregroundColor: secondaryColor], range: closing)
    }
  }

  private static func applyLineStyle(_ pattern: String,
                                     raw: String,
                                     to attributed: NSMutableAttributedString,
                                     style: (NSTextCheckingResult) -> Void) {
    for match in matches(pattern, raw: raw) {
      style(match)
    }
  }

  private static func matches(_ pattern: String, raw: String) -> [NSTextCheckingResult] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
    return regex.matches(in: raw, range: range)
  }

  #if os(iOS)
  private static var primaryColor: UIColor { .label }
  private static var secondaryColor: UIColor { .secondaryLabel }
  private static var codeBackgroundColor: UIColor { .tertiarySystemFill }

  private static func platformFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
    .systemFont(ofSize: size, weight: weight)
  }

  private static func italicFont(size: CGFloat) -> UIFont {
    .italicSystemFont(ofSize: size)
  }

  private static func monoFont(size: CGFloat) -> UIFont {
    .monospacedSystemFont(ofSize: size, weight: .regular)
  }
  #elseif os(macOS)
  private static var primaryColor: NSColor { .labelColor }
  private static var secondaryColor: NSColor { .secondaryLabelColor }
  private static var codeBackgroundColor: NSColor { .quaternaryLabelColor.withAlphaComponent(0.18) }

  private static func platformFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
  }

  private static func italicFont(size: CGFloat) -> NSFont {
    NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
  }

  private static func monoFont(size: CGFloat) -> NSFont {
    .monospacedSystemFont(ofSize: size, weight: .regular)
  }
  #endif
}
