import SeptenaSharedCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    Task { @MainActor in mount(await Self.extractDraft(from: extensionContext?.inputItems ?? [])) }
  }

  private func mount(_ draft: SharedTaskCapture) {
    let root = ShareCaptureView(initialCapture: draft, onCancel: { [weak self] in
      self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }, onSave: { [weak self] capture in
      do {
        try SharedTaskCaptureQueue.enqueue(capture, for: .septask)
        self?.extensionContext?.completeRequest(returningItems: nil)
      } catch { self?.extensionContext?.cancelRequest(withError: error) }
    })
    let host = UIHostingController(rootView: root)
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
  }

  private static func extractDraft(from inputItems: [Any]) async -> SharedTaskCapture {
    let providers = inputItems.compactMap { ($0 as? NSExtensionItem)?.attachments }.flatMap { $0 }
    var sharedURL: URL?
    var sharedText: String?
    for provider in providers {
      if sharedURL == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
         let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
        sharedURL = item as? URL
      }
      if sharedText == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
         let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
        sharedText = item as? String
      }
    }
    let text = (sharedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = text.split(whereSeparator: \Character.isNewline).map(String.init)
    let title = lines.first ?? sharedURL?.host ?? sharedURL?.absoluteString ?? ""
    var noteParts = Array(lines.dropFirst())
    if let sharedURL { noteParts.append(sharedURL.absoluteString) }
    return SharedTaskCapture(title: title, notes: noteParts.joined(separator: "\n"),
                             sourceURL: sharedURL)
  }
}

/// The open tasks that point at what is shared: its URL, else the links of its
/// text. The key grammar is the shared core's.
private struct ExistingTasks {
  let heading: String
  let titles: [String]

  /// More would push the form off the sheet.
  private static let maxTitles = 3

  init?(_ capture: SharedTaskCapture) {
    let text = [capture.title, capture.notes].joined(separator: "\n")
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let found = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))
      .compactMap { $0.url?.absoluteString } ?? []
    let links = capture.sourceURL.map { [$0.absoluteString] } ?? found
    let keys = Set(links.compactMap { try? parseRef(input: $0).key })
    guard !keys.isEmpty, let index = SharedTaskCaptureQueue.linkIndex(for: .septask) else { return nil }
    let titles = index.entries.filter { !keys.isDisjoint(with: $0.keys) }.map(\.title)
    guard !titles.isEmpty else { return nil }
    heading = index.heading
    self.titles = Array(titles.prefix(Self.maxTitles))
  }
}

private struct ShareCaptureView: View {
  @State private var capture: SharedTaskCapture
  private let existing: ExistingTasks?
  let onCancel: () -> Void
  let onSave: (SharedTaskCapture) -> Void

  init(initialCapture: SharedTaskCapture, onCancel: @escaping () -> Void,
       onSave: @escaping (SharedTaskCapture) -> Void) {
    _capture = State(initialValue: initialCapture)
    existing = ExistingTasks(initialCapture)
    self.onCancel = onCancel
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
        if let existing {
          // A share extension cannot open the app, so these rows only tell.
          Section(existing.heading) {
            ForEach(Array(existing.titles.enumerated()), id: \.offset) { _, title in
              Label(title, systemImage: "circle").lineLimit(2)
            }
          }
        }
        TextField("Task", text: $capture.title, axis: .vertical).lineLimit(1...3)
        TextField("Notes", text: $capture.notes, axis: .vertical).lineLimit(3...8)
        Toggle("Today", isOn: $capture.today)
      }
      .navigationTitle("New Task")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") { onSave(capture) }
            .disabled(capture.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }
}
