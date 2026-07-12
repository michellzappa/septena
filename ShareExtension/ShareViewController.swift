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
        #if SHARE_DESTINATION_SEPTASK
        try SharedTaskCaptureQueue.enqueue(capture, for: .septask)
        #else
        try SharedTaskCaptureQueue.enqueue(capture, for: .septena)
        #endif
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

private struct ShareCaptureView: View {
  @State private var capture: SharedTaskCapture
  let onCancel: () -> Void
  let onSave: (SharedTaskCapture) -> Void

  init(initialCapture: SharedTaskCapture, onCancel: @escaping () -> Void,
       onSave: @escaping (SharedTaskCapture) -> Void) {
    _capture = State(initialValue: initialCapture)
    self.onCancel = onCancel
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
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
