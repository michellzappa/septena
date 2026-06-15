import SwiftUI
import SwiftData
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
      ReportPreviewSheet(preview: p) { bundles = ReportStore.load() }
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
    let link = (b.linkURL?.isEmpty == false) ? " · 🔗 shared" : ""
    return "\(sects) · \(win)\(mcp)\(link)"
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
    let weightUnit = store.serverSettings?.units?.weight ?? "kg"
    Task {
      let built = await MirrorReader.shared.read { ctx in
        ReportPayloadBuilder.build(bundle: bundle, meta: meta, owner: owner, weightUnit: weightUnit, context: ctx)
      }
      await MainActor.run {
        var payload = built
        // Goal progress is evaluated on the main actor (it dispatches through
        // section plugins), so merge it here rather than in the off-main builder.
        if bundle.showsGoals {
          let gmap = goalsForReport(bundle.sectionKeys)
          payload.sections = payload.sections.map { s in
            var s = s; s.goals = gmap[s.key] ?? []; return s
          }
        }
        let html = ReportHTMLRenderer.html(for: payload)
        preview = ReportPreview(bundle: bundle, payload: payload, html: html)
        renderingID = nil
      }
    }
  }

  // Related goals + live progress per section, evaluated on the main actor.
  private func goalsForReport(_ keys: [String]) -> [String: [ReportGoal]] {
    let ctx = LocalStore.shared.container.mainContext
    let entities = (try? ctx.fetch(FetchDescriptor<GoalEntity>())) ?? []
    let goals = entities.map { Goal($0) }
    var out: [String: [ReportGoal]] = [:]
    for key in keys {
      let related = goals.filter { $0.sections.contains(key) }
      let rg: [ReportGoal] = related.map { g in
        guard let p = GoalMetricEvaluator.evaluate(goal: g, context: ctx) else {
          return ReportGoal(text: g.text, detail: "", fraction: nil, hit: false)
        }
        let cur = fmtNum(p.current), tgt = fmtNum(p.target), u = p.unitLabel
        let detail: String
        switch p.comparator {
        case "lte":   detail = "\(cur) / ≤\(tgt) \(u)"
        case "range": detail = "\(cur) \(u) (target \(tgt)–\(fmtNum(p.targetUpper ?? p.target)))"
        default:      detail = "\(cur) / \(tgt) \(u)"
        }
        return ReportGoal(text: g.text, detail: detail, fraction: p.fraction, hit: p.hit)
      }
      if !rg.isEmpty { out[key] = rg }
    }
    return out
  }

  private func fmtNum(_ d: Double) -> String {
    d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
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
  let payload: ReportPayload
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

        SwiftUI.Section("Link expiry") {
          Picker("Link expires", selection: expiryBinding) {
            Text("30 days").tag(30)
            Text("90 days").tag(90)
            Text("12 months").tag(365)
            Text("Never").tag(0)
          }
          .pickerStyle(.segmented)
        }

        SwiftUI.Section {
          Toggle(isOn: Binding(get: { draft.showsGoals },
                               set: { draft.includeGoals = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Include related goals")
              Text("Show each section's goals and live progress toward target (read-only).")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
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

  // Maps the optional linkExpiryDays to the picker (0 = never).
  private var expiryBinding: Binding<Int> {
    Binding(get: { draft.linkExpiryDays ?? 0 },
            set: { draft.linkExpiryDays = $0 == 0 ? nil : $0 })
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
  /// Called after the link is created/refreshed so the hub list can refresh.
  var onUpdate: () -> Void = {}

  @State private var linkURL: String?
  @State private var creating = false
  @State private var errorMessage: String?

  init(preview: ReportPreview, onUpdate: @escaping () -> Void = {}) {
    self.preview = preview
    self.onUpdate = onUpdate
    _linkURL = State(initialValue: preview.bundle.linkURL)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let url = linkURL, !url.isEmpty {
          linkBanner(url)
        }
        ReportWebView(html: preview.html)
      }
      .navigationTitle(preview.bundle.title.isEmpty ? "Report" : preview.bundle.title)
      .toolbar {
        #if os(macOS)
        ToolbarItemGroup {
          linkButton
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
      .alert("Couldn't create link", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
        Button("OK", role: .cancel) {}
      } message: { Text(errorMessage ?? "") }
    }
    #if os(macOS)
    .frame(minWidth: 760, minHeight: 640)
    #endif
  }

  // MARK: Link UI

  @ViewBuilder
  private var linkButton: some View {
    if creating {
      ProgressView().controlSize(.small)
    } else if linkURL?.isEmpty == false {
      Button { copyLink() } label: { Label("Copy Link", systemImage: "link") }
      Button(role: .destructive) { revokeLink() } label: { Label("Revoke", systemImage: "trash") }
    } else {
      Button { createLink() } label: { Label("Create Link", systemImage: "link.badge.plus") }
    }
  }

  @ViewBuilder
  private func linkBanner(_ url: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Image(systemName: "link").foregroundStyle(.secondary)
        Text(url).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("Copy") { copyLink() }.buttonStyle(.borderless)
      }
      Text(expiryCaption).font(.caption).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
    .background(.thinMaterial)
  }

  private var expiryCaption: String {
    if let d = preview.bundle.linkExpiryDays {
      return "Expires \(d == 365 ? "in 12 months" : "in \(d) days") · anyone with the link can view · Revoke to kill it now"
    }
    return "Never expires · anyone with the link can view · Revoke to kill it now"
  }

  // MARK: Link actions — pushes live aggregates to the Worker (user-initiated)

  private func createLink() {
    creating = true
    var bundle = preview.bundle
    let token = bundle.token ?? ReportEndpoint.newToken()
    let payload = preview.payload
    let html = preview.html
    let expiresAt = ReportPublisher.expiry(daysFromNow: bundle.linkExpiryDays)
    Task {
      do {
        let url = try await ReportPublisher.push(payload: payload, html: html, token: token,
                                                 expiresAt: expiresAt, baseURL: ReportEndpoint.baseURL)
        bundle.token = token
        bundle.linkURL = url.absoluteString
        ReportStore.upsert(bundle)
        await MainActor.run {
          linkURL = url.absoluteString
          creating = false
          copyLink()
          onUpdate()
        }
      } catch {
        await MainActor.run {
          creating = false
          errorMessage = "\(error)"
        }
      }
    }
  }

  private func revokeLink() {
    guard let token = preview.bundle.token else { linkURL = nil; return }
    creating = true
    var bundle = preview.bundle
    Task {
      try? await ReportPublisher.revoke(token: token, baseURL: ReportEndpoint.baseURL)
      bundle.linkURL = nil
      bundle.token = nil
      ReportStore.upsert(bundle)
      await MainActor.run {
        linkURL = nil
        creating = false
        onUpdate()
      }
    }
  }

  private func copyLink() {
    guard let url = linkURL, !url.isEmpty else { return }
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url, forType: .string)
    #else
    UIPasteboard.general.string = url
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
