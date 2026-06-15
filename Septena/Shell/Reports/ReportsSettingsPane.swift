import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Reports hub
//
// Settings ▸ Reports. Build a scoped, time-bounded, read-only report of
// selected sections for a practitioner (doctor / therapist / PT / coach),
// preview it as the exact web view they'd see, and export / open the
// self-contained HTML. The shareable secure-link + scoped MCP endpoint are the
// next phase (see docs/PRACTITIONER_REPORTS_SPEC.md); this proves the builder,
// the live-data payload, and the renderer end-to-end with no infra.

struct ReportsSettingsPane: View {
  @Environment(SettingsStore.self) private var store

  @State private var bundles: [ReportBundle] = ReportStore.load()
  @State private var draft: ReportBundle?          // builder sheet
  @State private var preview: ReportPreview?       // preview sheet
  @State private var renderingID: String?

  var body: some View {
    Form {
      SwiftUI.Section {
        ForEach(ReportPreset.all) { preset in
          Button { startDraft(from: preset) } label: {
            HStack(spacing: 12) {
              ColoredGlyph(icon: preset.symbol, color: .accentColor, size: 28, glyphRatio: 0.42)
              VStack(alignment: .leading, spacing: 2) {
                Text(preset.title).font(.body)
                Text(preset.blurb).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
          }
          .buttonStyle(.plain)
        }
      } header: {
        Text("New report")
      } footer: {
        Text("Pick an audience to start — each pre-selects sensible sections you can edit. Reports share aggregate trends only, never individual entries.")
      }

      if !bundles.isEmpty {
        SwiftUI.Section("Your reports") {
          ForEach(bundles) { bundle in
            reportRow(bundle)
          }
          .onDelete { idx in
            for i in idx { ReportStore.delete(id: bundles[i].id) }
            bundles = ReportStore.load()
          }
        }
      }
    }
    .formStyle(.grouped)
    .sheet(item: $draft) { d in
      ReportBuilderSheet(draft: d, enabledSections: enabledSections) { saved in
        ReportStore.upsert(saved)
        bundles = ReportStore.load()
      }
    }
    .sheet(item: $preview) { p in
      ReportPreviewSheet(preview: p)
    }
  }

  // MARK: Row

  @ViewBuilder
  private func reportRow(_ bundle: ReportBundle) -> some View {
    Button { openPreview(bundle) } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(bundle.title.isEmpty ? "Untitled report" : bundle.title).font(.body)
          Text(subtitle(bundle)).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if renderingID == bundle.id {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "eye").font(.callout).foregroundStyle(.tertiary)
        }
      }
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button { openPreview(bundle) } label: { Label("Preview", systemImage: "eye") }
      Button { draft = bundle } label: { Label("Edit", systemImage: "pencil") }
      Button(role: .destructive) {
        ReportStore.delete(id: bundle.id); bundles = ReportStore.load()
      } label: { Label("Delete", systemImage: "trash") }
    }
  }

  private func subtitle(_ b: ReportBundle) -> String {
    let n = b.sectionKeys.count
    let sects = "\(n) section\(n == 1 ? "" : "s")"
    let win = b.windowDays == 365 ? "12 months" : "\(b.windowDays)d"
    let mcp = b.mcpEnabled ? " · MCP on" : ""
    return "\(sects) · \(win)\(mcp)"
  }

  // MARK: Actions

  private func startDraft(from preset: ReportPreset) {
    let enabledKeys = Set(enabledSections.map(\.key))
    let picked = preset.defaultSections.filter { enabledKeys.contains($0) }
    draft = ReportBundle(
      id: UUID().uuidString,
      title: preset.id == "custom" ? "" : "\(preset.title) report",
      sectionKeys: picked,
      windowDays: 90,
      createdAt: SeptenaDate.today
    )
  }

  private func openPreview(_ bundle: ReportBundle) {
    guard renderingID == nil else { return }
    renderingID = bundle.id
    let meta = metaMap(for: bundle.sectionKeys)
    let owner = store.serverSettings?.welcomeName ?? ""
    Task {
      let html = await MirrorReader.shared.read { ctx in
        ReportHTMLRenderer.html(for: ReportPayloadBuilder.build(
          bundle: bundle, meta: meta, owner: owner, context: ctx))
      }
      await MainActor.run {
        preview = ReportPreview(bundle: bundle, html: html)
        renderingID = nil
      }
    }
  }

  // Section label + accent resolved on-main and handed to the off-main builder.
  private func metaMap(for keys: [String]) -> [String: ReportSectionMeta] {
    var out: [String: ReportSectionMeta] = [:]
    for key in keys {
      let cfg = store.sections.first { $0.key == key }
      let label = SectionManifest.displayLabel(key: key, stored: cfg?.label ?? "")
      out[key] = ReportSectionMeta(label: label, colorHex: cfg?.color ?? "#3b82f6")
    }
    return out
  }

  // Enabled, log-bearing sections in the user's order. Tasks/goals are
  // omitted — they aren't shareable life-data trends.
  private var enabledSections: [SectionConfig] {
    let skip: Set<String> = ["tasks", "goals", "insights", "groceries"]
    return store.sections.filter { $0.isEnabled && !skip.contains($0.key) }
  }
}

// MARK: - Preview payload (sheet item)

struct ReportPreview: Identifiable {
  let bundle: ReportBundle
  let html: String
  var id: String { bundle.id }
}

// MARK: - Builder sheet

struct ReportBuilderSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State var draft: ReportBundle
  let enabledSections: [SectionConfig]
  let onSave: (ReportBundle) -> Void

  var body: some View {
    NavigationStack {
      Form {
        SwiftUI.Section("Title") {
          TextField("e.g. Dr. Lindqvist — Endocrinology", text: $draft.title)
          TextField("Note to recipient (optional)", text: $draft.note, axis: .vertical)
            .lineLimit(1...3)
        }

        SwiftUI.Section("Window") {
          Picker("Trailing window", selection: $draft.windowDays) {
            ForEach(ReportPreset.windowOptions, id: \.self) { d in
              Text(d == 365 ? "12 months" : "\(d) days").tag(d)
            }
          }
          .pickerStyle(.segmented)
        }

        SwiftUI.Section {
          ForEach(enabledSections, id: \.key) { cfg in
            sectionToggle(cfg)
          }
        } header: {
          Text("Sections")
        } footer: {
          Text("Checked sections appear as aggregate trends. Sections marked “no trends yet” are listed but won't chart until their pattern view ships.")
        }

        SwiftUI.Section {
          Toggle(isOn: $draft.mcpEnabled) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Enable MCP endpoint")
              Text("Let the recipient's own AI query this report (scoped, read-only). Design flag in this prototype — not yet served.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("New report")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { onSave(draft); dismiss() }
            .disabled(draft.sectionKeys.isEmpty)
        }
      }
    }
    #if os(macOS)
    .frame(width: 520, height: 560)
    #endif
  }

  @ViewBuilder
  private func sectionToggle(_ cfg: SectionConfig) -> some View {
    let isOn = Binding(
      get: { draft.sectionKeys.contains(cfg.key) },
      set: { on in
        if on { if !draft.sectionKeys.contains(cfg.key) { draft.sectionKeys.append(cfg.key) } }
        else { draft.sectionKeys.removeAll { $0 == cfg.key } }
      }
    )
    let supported = ReportPayloadBuilder.supportedKeys.contains(cfg.key)
    Toggle(isOn: isOn) {
      HStack {
        Text(SectionManifest.displayLabel(key: cfg.key, stored: cfg.label))
        if !supported {
          Text("no trends yet").font(.caption2).foregroundStyle(.tertiary)
        }
      }
    }
  }
}

// MARK: - Preview sheet (the exact web view a recipient would see)

struct ReportPreviewSheet: View {
  @Environment(\.dismiss) private var dismiss
  let preview: ReportPreview

  var body: some View {
    NavigationStack {
      ReportWebView(html: preview.html)
        .navigationTitle(preview.bundle.title.isEmpty ? "Report" : preview.bundle.title)
        .toolbar {
          #if os(macOS)
          ToolbarItemGroup {
            Button { openInBrowser() } label: { Label("Open in Browser", systemImage: "safari") }
            Button { saveHTML() } label: { Label("Save HTML…", systemImage: "square.and.arrow.down") }
            Button("Done") { dismiss() }
          }
          #else
          ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
          ToolbarItem(placement: .primaryAction) {
            ShareLink(item: exportURL()) { Image(systemName: "square.and.arrow.up") }
          }
          #endif
        }
    }
    #if os(macOS)
    .frame(minWidth: 760, minHeight: 640)
    #endif
  }

  private func filename() -> String {
    let base = preview.bundle.title.isEmpty ? "report" : preview.bundle.title
    let slug = base.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "septena-\(slug.isEmpty ? "report" : slug).html"
  }

  private func exportURL() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename())
    try? preview.html.data(using: .utf8)?.write(to: url)
    return url
  }

  #if os(macOS)
  private func openInBrowser() {
    NSWorkspace.shared.open(exportURL())
  }

  private func saveHTML() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = filename()
    panel.allowedContentTypes = [.html]
    if panel.runModal() == .OK, let url = panel.url {
      try? preview.html.data(using: .utf8)?.write(to: url)
    }
  }
  #endif
}

// MARK: - Cross-platform WKWebView wrapper

#if os(macOS)
struct ReportWebView: NSViewRepresentable {
  let html: String
  func makeNSView(context: Context) -> WKWebView { WKWebView() }
  func updateNSView(_ webView: WKWebView, context: Context) {
    webView.loadHTMLString(html, baseURL: nil)
  }
}
#else
struct ReportWebView: UIViewRepresentable {
  let html: String
  func makeUIView(context: Context) -> WKWebView { WKWebView() }
  func updateUIView(_ webView: WKWebView, context: Context) {
    webView.loadHTMLString(html, baseURL: nil)
  }
}
#endif
