import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ImageIO
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
          if Self.isImage(attachment.contentType), let url = TaskAttachmentFiles.url(for: attachment) {
            AttachmentThumbnail(source: .file(url), key: attachment.id, side: 32)
          } else {
            Image(systemName: icon(for: attachment.contentType))
              .frame(width: 22)
              .foregroundStyle(.secondary)
          }
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

  /// `contentType` holds a UTI (`public.png`) for files added in the app and
  /// may hold a MIME type (`image/png`) for records from elsewhere.
  static func isImage(_ type: String) -> Bool {
    type.hasPrefix("image/") || UTType(type)?.conforms(to: .image) == true
  }

  private func icon(for type: String) -> String {
    if Self.isImage(type) { return "photo" }
    if type == "application/pdf" { return "doc.richtext" }
    if type.hasPrefix("audio/") { return "waveform" }
    if type.hasPrefix("video/") { return "film" }
    return "doc"
  }

  /// The file is local, or (backend task store) fetched on first open.
  private func open(_ attachment: TaskAttachmentEntity) {
    Task { @MainActor in
      do {
        guard let url = try await store.localFile(for: attachment) else { return }
        errorMessage = nil
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        await UIApplication.shared.open(url)
        #endif
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

// MARK: - Pasted images (#210)

/// An image taken from the clipboard by the new-task Paste chip, held by the
/// composer until the task exists, then written as an attachment.
struct PastedImage: Identifiable, Equatable {
  let id = UUID()
  let data: Data
  let type: UTType

  @MainActor var filename: String { TaskAttachmentFiles.pastedImageFilename(ext: type.preferredFilenameExtension ?? "png") }
  var fitsAttachmentLimit: Bool { Int64(data.count) <= TaskAttachmentFiles.maxBytes }

  static func == (a: PastedImage, b: PastedImage) -> Bool { a.id == b.id }

  /// The first image among the pasted item providers, in the type the source
  /// offered (PNG, JPEG, HEIC…). Nil when no provider carries an image.
  static func load(from providers: [NSItemProvider]) async -> PastedImage? {
    for provider in providers {
      guard let identifier = provider.registeredTypeIdentifiers.first(where: {
        UTType($0)?.conforms(to: .image) == true
      }), let type = UTType(identifier) else { continue }
      let data: Data? = await withCheckedContinuation { continuation in
        _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
          continuation.resume(returning: data)
        }
      }
      if let data { return PastedImage(data: data, type: type) }
    }
    return nil
  }

  /// The first plain text among the pasted item providers.
  static func loadText(from providers: [NSItemProvider]) async -> String? {
    for provider in providers {
      guard let identifier = provider.registeredTypeIdentifiers.first(where: {
        UTType($0)?.conforms(to: .plainText) == true
      }) else { continue }
      let data: Data? = await withCheckedContinuation { continuation in
        _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
          continuation.resume(returning: data)
        }
      }
      if let data, let text = String(data: data, encoding: .utf8) { return text }
    }
    return nil
  }

  #if os(macOS)
  /// The clipboard image on macOS, as PNG (a TIFF from a screenshot or an
  /// app is converted). Reading the Mac pasteboard shows no permission alert.
  @MainActor
  static func fromGeneralPasteboard() -> PastedImage? {
    let pb = NSPasteboard.general
    if let png = pb.data(forType: .png) { return PastedImage(data: png, type: .png) }
    if let tiff = pb.data(forType: .tiff),
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
      return PastedImage(data: png, type: .png)
    }
    return nil
  }
  #endif
}

/// A square image thumbnail, decoded and downsampled off the main thread so a
/// large photo never stalls a list or the composer.
struct AttachmentThumbnail: View {
  enum Source {
    case data(Data)
    case file(URL)
  }

  let source: Source
  /// Identity for reloading: the attachment or pasted-image id.
  let key: String
  var side: CGFloat = 56

  @Environment(\.displayScale) private var displayScale
  @State private var image: CGImage?

  var body: some View {
    RoundedRectangle(cornerRadius: side > 40 ? 8 : 5)
      .fill(.quaternary)
      .overlay {
        if let image {
          Image(decorative: image, scale: displayScale)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: "photo").foregroundStyle(.secondary)
        }
      }
      .frame(width: side, height: side)
      .clipShape(RoundedRectangle(cornerRadius: side > 40 ? 8 : 5))
      .accessibilityHidden(true)
      .task(id: key) {
        let maxPixel = side * displayScale
        let source = source
        image = await Task.detached(priority: .userInitiated) {
          Self.thumbnail(source, maxPixel: maxPixel)
        }.value
      }
  }

  nonisolated private static func thumbnail(_ source: Source, maxPixel: CGFloat) -> CGImage? {
    let imageSource: CGImageSource?
    switch source {
    case .data(let data): imageSource = CGImageSourceCreateWithData(data as CFData, nil)
    case .file(let url):  imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
    }
    guard let imageSource else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
  }
}
