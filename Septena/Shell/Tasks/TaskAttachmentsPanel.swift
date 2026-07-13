import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct TaskAttachmentsPanel: View {
  let taskID: String
  @State private var rows: [TaskAttachmentEntity] = []
  @State private var importing = false
  @State private var errorMessage: String?

  private var store: TaskAttachmentStore { SeptenaServices.shared.taskAttachmentStore }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(rows, id: \.id) { attachment in
        HStack(spacing: 10) {
          Image(systemName: icon(for: attachment.contentType))
            .frame(width: 22)
            .foregroundStyle(.secondary)
          Button { open(attachment) } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(attachment.filename).lineLimit(1)
              Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
          Spacer()
          Button(role: .destructive) {
            store.remove(attachment)
            reload()
          } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain)
          .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(.vertical, 3)
      }

      Button { importing = true } label: {
        Label(rows.isEmpty ? "Choose File…" : "Add Another File…", systemImage: "plus")
      }
      .buttonStyle(.borderless)

      if let errorMessage {
        Text(errorMessage).font(.caption).foregroundStyle(.red)
      }
    }
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    .onAppear(perform: reload)
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in reload() }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.item],
                  allowsMultipleSelection: true) { result in
      do {
        for url in try result.get() { try store.add(taskID: taskID, sourceURL: url) }
        errorMessage = nil
        reload()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func reload() { rows = store.attachments(taskID: taskID) }

  private func icon(for type: String) -> String {
    if type.hasPrefix("image/") { return "photo" }
    if type == "application/pdf" { return "doc.richtext" }
    if type.hasPrefix("audio/") { return "waveform" }
    if type.hasPrefix("video/") { return "film" }
    return "doc"
  }

  private func open(_ attachment: TaskAttachmentEntity) {
    guard let url = TaskAttachmentFiles.url(for: attachment) else { return }
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
  }
}
