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
  @State private var contentHeight: CGFloat = 28

  private let minHeight: CGFloat = 28
  private let maxHeight: CGFloat = 360

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

  private var visibleHeight: CGFloat {
    min(max(contentHeight, minHeight), maxHeight)
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
        contentHeight: $contentHeight,
        fontSize: bodyFontSize,
        maxHeight: maxHeight
      )
      .frame(height: visibleHeight)

      if text.isEmpty {
        Text("Notes")
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkSecondary)
          .allowsHitTesting(false)
      }
    }
    .frame(minHeight: minHeight, alignment: .topLeading)
  }
}

#if os(iOS)
private struct PlatformMarkdownNotesTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  @Binding var contentHeight: CGFloat
  let fontSize: CGFloat
  let maxHeight: CGFloat

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.delegate = context.coordinator
    view.backgroundColor = .clear
    view.isOpaque = false
    view.isScrollEnabled = false
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.adjustsFontForContentSizeCategory = false
    view.textDragInteraction?.isEnabled = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    view.attributedText = MarkdownNotesStyle.attributed(text, fontSize: fontSize)
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.parent = self
    view.isScrollEnabled = contentHeight >= maxHeight - 1
    view.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)

    if view.text != text {
      context.coordinator.replaceText(in: view, with: text)
    } else if context.coordinator.lastFontSize != fontSize {
      context.coordinator.applyStyle(to: view)
    }

    if isFocused, !view.isFirstResponder {
      view.becomeFirstResponder()
    } else if !isFocused, view.isFirstResponder {
      view.resignFirstResponder()
    }

    context.coordinator.updateHeight(for: view)
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: PlatformMarkdownNotesTextView
    var lastFontSize: CGFloat = 0
    private var applying = false

    init(parent: PlatformMarkdownNotesTextView) {
      self.parent = parent
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
      parent.isFocused = true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      parent.isFocused = false
    }

    func textViewDidChange(_ textView: UITextView) {
      guard !applying else { return }
      parent.text = textView.text
      applyStyle(to: textView)
      updateHeight(for: textView)
    }

    func replaceText(in textView: UITextView, with text: String) {
      applying = true
      let selected = textView.selectedRange
      textView.attributedText = MarkdownNotesStyle.attributed(text, fontSize: parent.fontSize)
      textView.selectedRange = clamped(selected, length: textView.textStorage.length)
      textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: parent.fontSize)
      lastFontSize = parent.fontSize
      applying = false
      updateHeight(for: textView)
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

    func updateHeight(for textView: UITextView) {
      guard textView.bounds.width > 0 else { return }
      let size = textView.sizeThatFits(
        CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
      )
      let next = max(28, ceil(size.height))
      DispatchQueue.main.async {
        if abs(self.parent.contentHeight - next) > 0.5 {
          self.parent.contentHeight = next
        }
      }
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
  @Binding var contentHeight: CGFloat
  let fontSize: CGFloat
  let maxHeight: CGFloat

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true

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
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = context.coordinator.textView else { return }

    scrollView.hasVerticalScroller = contentHeight >= maxHeight - 1
    textView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    textView.textContainer?.containerSize = CGSize(width: max(scrollView.bounds.width, 1),
                                                   height: .greatestFiniteMagnitude)

    if textView.string != text {
      context.coordinator.replaceText(in: textView, with: text)
    } else if context.coordinator.lastFontSize != fontSize {
      context.coordinator.applyStyle(to: textView)
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

    context.coordinator.updateHeight(for: scrollView)
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: PlatformMarkdownNotesTextView
    weak var textView: NSTextView?
    var lastFontSize: CGFloat = 0
    private var applying = false

    init(parent: PlatformMarkdownNotesTextView) {
      self.parent = parent
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
        updateHeight(for: scrollView)
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
        updateHeight(for: scrollView)
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

    func updateHeight(for scrollView: NSScrollView) {
      guard let textView else { return }
      let width = max(scrollView.bounds.width, 1)
      textView.textContainer?.containerSize = CGSize(width: width,
                                                     height: .greatestFiniteMagnitude)
      textView.frame.size.width = width
      if let manager = textView.layoutManager, let container = textView.textContainer {
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let next = max(28, ceil(used.height + textView.textContainerInset.height))
        DispatchQueue.main.async {
          if abs(self.parent.contentHeight - next) > 0.5 {
            self.parent.contentHeight = next
          }
          textView.frame.size.height = next
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
