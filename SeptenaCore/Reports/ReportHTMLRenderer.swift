import Foundation

// MARK: - ReportHTMLRenderer
//
// Renders a `ReportPayload` to a single self-contained HTML document: inline
// CSS, inline SVG charts, no external assets or scripts. This is exactly what
// the in-app WKWebView preview shows and what the future Worker would serve at
// /r/<token> — one renderer, both surfaces.

public enum ReportHTMLRenderer {

  public static func html(for payload: ReportPayload) -> String {
    let owner = payload.owner.trimmingCharacters(in: .whitespaces)
    let ownerLine = owner.isEmpty ? "" : "<div class=\"owner\">\(esc(owner))</div>"
    let noteLine = payload.note.trimmingCharacters(in: .whitespaces).isEmpty
      ? "" : "<p class=\"note\">\(esc(payload.note))</p>"

    let sectionsHTML = payload.sections.map(sectionCard).joined(separator: "\n")

    return """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(esc(payload.title))</title>
    <style>\(css)</style>
    </head>
    <body>
    <main class="report">
      <header class="head">
        <a class="brand" href="https://www.septena.app">Septena</a>
        <h1>\(esc(payload.title))</h1>
        \(ownerLine)
        \(noteLine)
        <div class="meta">
          <span>Trailing \(windowLabel(payload.windowDays))</span>
          <span class="dot">·</span>
          <span>Data as of \(esc(SeptenaDate.friendlyLabel(payload.asOf))), \(esc(payload.asOf))</span>
        </div>
      </header>
      \(sectionsHTML)
      <footer class="foot">
        <p>Aggregated trends only — no individual entries are shared. Generated on the owner's device. This view can be revoked at any time.</p>
        <p class="gen">Made with <a href="https://www.septena.app">Septena</a> — one private app for everything you track. <a href="https://www.septena.app">www.septena.app</a></p>
      </footer>
    </main>
    </body>
    </html>
    """
  }

  // MARK: - Section card

  private static func sectionCard(_ s: ReportSection) -> String {
    let accent = safeColor(s.colorHex)
    let stats = s.stats.map { st -> String in
      let detail = st.detail.map { "<div class=\"sd\">\(esc($0))</div>" } ?? ""
      return """
      <div class="stat">
        <div class="sv">\(esc(st.value))</div>
        <div class="sl">\(esc(st.label))</div>
        \(detail)
      </div>
      """
    }.joined()

    let body: String
    if s.unavailable && s.charts.isEmpty && s.tables.isEmpty {
      body = "<p class=\"empty\">No data logged in this window — or this section's aggregate view isn't available yet.</p>"
    } else {
      let charts = s.charts.map { chart(_:$0, accent: accent) }.joined(separator: "\n")
      let tables = s.tables.map(table).joined(separator: "\n")
      let goalsBlock = s.goals.isEmpty ? "" : goals(s.goals, accent: accent)
      let statsBlock = stats.isEmpty ? "" : "<div class=\"stats\">\(stats)</div>"
      body = statsBlock + charts + tables + goalsBlock
    }

    return """
    <section class="card" style="--accent: \(accent)">
      <div class="ch"><span class="swatch"></span><h2>\(esc(s.label))</h2></div>
      \(body)
    </section>
    """
  }

  private static func goals(_ gs: [ReportGoal], accent: String) -> String {
    let rows = gs.map { g -> String in
      let check = g.hit ? "<span class=\"gh\">✓</span>" : ""
      let bar: String
      if let f = g.fraction {
        let pct = Int((min(1, max(0, f)) * 100).rounded())
        bar = "<div class=\"gbar\"><div class=\"gfill\" style=\"width:\(pct)%;background:\(accent)\"></div></div>"
      } else {
        bar = ""
      }
      let detail = g.detail.isEmpty ? "" : "<span class=\"gd\">\(esc(g.detail))</span>"
      return """
      <div class="goal">
        <div class="grow"><span class="gt">\(check)\(esc(g.text))</span>\(detail)</div>
        \(bar)
      </div>
      """
    }.joined()
    return "<div class=\"chart\"><div class=\"ct\">Goals</div>\(rows)</div>"
  }

  private static func table(_ t: ReportTable) -> String {
    let head = t.columns.map { "<th>\(esc($0))</th>" }.joined()
    let body = t.rows.map { row in
      "<tr>" + row.enumerated().map { i, cell in
        let cls = i == 0 ? " class=\"rl\"" : ""
        return "<td\(cls)>\(esc(cell))</td>"
      }.joined() + "</tr>"
    }.joined()
    return """
    <div class="chart">
      <div class="ct">\(esc(t.title))</div>
      <table class="tbl"><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table>
    </div>
    """
  }

  private static func chart(_ c: ReportChart, accent: String) -> String {
    guard !c.points.isEmpty else { return "" }
    let svg: String
    switch c.kind {
    case .line:    svg = lineSVG(c.points, accent: accent)
    case .bar:     svg = barSVG(c.points, accent: accent)
    case .heatmap: svg = heatmapSVG(c.points, accent: accent)
    }
    let unit = c.unit.isEmpty ? "" : " <span class=\"unit\">(\(esc(c.unit)))</span>"
    return """
    <div class="chart">
      <div class="ct">\(esc(c.title))\(unit)</div>
      \(svg)
    </div>
    """
  }

  // MARK: - SVG charts (fixed viewBox, CSS-scaled to 100% width)

  private static let W = 640.0
  private static let H = 150.0
  private static let padL = 10.0, padR = 10.0, padT = 14.0, padB = 26.0

  private static func lineSVG(_ points: [ReportPoint], accent: String) -> String {
    let vals = points.map { $0.value }
    let n = vals.count
    let (lo, hi) = bounds(vals)
    let innerW = W - padL - padR, innerH = H - padT - padB
    let baseline = padT + innerH
    func x(_ i: Int) -> Double { n <= 1 ? padL + innerW / 2 : padL + innerW * Double(i) / Double(n - 1) }
    func y(_ v: Double) -> Double { padT + innerH * (1 - (v - lo) / (hi - lo)) }

    let coords = (0..<n).map { "\(fmt(x($0))),\(fmt(y(vals[$0])))" }
    let poly = coords.joined(separator: " ")
    let area = "M \(fmt(x(0))),\(fmt(baseline)) L " + coords.joined(separator: " L ") + " L \(fmt(x(n-1))),\(fmt(baseline)) Z"
    let lastX = x(n - 1), lastY = y(vals[n - 1])

    return """
    <svg viewBox="0 0 \(fmt(W)) \(fmt(H))" preserveAspectRatio="none" class="g">
      <path d="\(area)" fill="\(accent)" fill-opacity="0.10"/>
      <polyline points="\(poly)" fill="none" stroke="\(accent)" stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round"/>
      <circle cx="\(fmt(lastX))" cy="\(fmt(lastY))" r="3.4" fill="\(accent)"/>
      \(axisLabels(points, lo: lo, hi: hi))
    </svg>
    """
  }

  private static func barSVG(_ points: [ReportPoint], accent: String) -> String {
    let vals = points.map { $0.value }
    let n = vals.count
    let hi = max(vals.max() ?? 1, 1)
    let innerW = W - padL - padR, innerH = H - padT - padB
    let baseline = padT + innerH
    let slot = innerW / Double(n)
    let bw = min(slot * 0.7, 22)
    let bars = (0..<n).map { i -> String in
      let h = innerH * (vals[i] / hi)
      let cx = padL + slot * (Double(i) + 0.5)
      let xx = cx - bw / 2
      let yy = baseline - h
      return "<rect x=\"\(fmt(xx))\" y=\"\(fmt(yy))\" width=\"\(fmt(bw))\" height=\"\(fmt(max(h, 0.5)))\" rx=\"1.5\" fill=\"\(accent)\" fill-opacity=\"0.85\"/>"
    }.joined()
    return """
    <svg viewBox="0 0 \(fmt(W)) \(fmt(H))" preserveAspectRatio="none" class="g">
      \(bars)
      \(axisLabels(points, lo: 0, hi: hi))
    </svg>
    """
  }

  private static func heatmapSVG(_ points: [ReportPoint], accent: String) -> String {
    let n = points.count
    let hi = max(points.map { $0.value }.max() ?? 1, 1)
    let innerW = W - padL - padR
    let cellGap = 1.5
    let cellW = (innerW - cellGap * Double(n - 1)) / Double(n)
    let cellH = 26.0
    let top = padT + 12
    let cells = points.enumerated().map { (i, p) -> String in
      let xx = padL + Double(i) * (cellW + cellGap)
      let intensity = 0.12 + 0.88 * (p.value / hi)
      return "<rect x=\"\(fmt(xx))\" y=\"\(fmt(top))\" width=\"\(fmt(max(cellW, 0.8)))\" height=\"\(fmt(cellH))\" rx=\"1\" fill=\"\(accent)\" fill-opacity=\"\(fmt(intensity))\"/>"
    }.joined()
    let labels = edgeDateLabels(points, y: top + cellH + 16)
    return """
    <svg viewBox="0 0 \(fmt(W)) 90" preserveAspectRatio="none" class="g">
      \(cells)
      \(labels)
    </svg>
    """
  }

  // MARK: - Axis helpers

  private static func axisLabels(_ points: [ReportPoint], lo: Double, hi: Double) -> String {
    let yTop = "<text x=\"\(fmt(W - padR))\" y=\"\(fmt(padT + 2))\" class=\"axn\" text-anchor=\"end\">\(fmt(hi))</text>"
    return yTop + edgeDateLabels(points, y: H - 8)
  }

  private static func edgeDateLabels(_ points: [ReportPoint], y: Double) -> String {
    guard let first = points.first, let last = points.last else { return "" }
    let l = "<text x=\"\(fmt(padL))\" y=\"\(fmt(y))\" class=\"axd\">\(esc(SeptenaDate.friendlyLabel(first.label)))</text>"
    let r = "<text x=\"\(fmt(W - padR))\" y=\"\(fmt(y))\" class=\"axd\" text-anchor=\"end\">\(esc(SeptenaDate.friendlyLabel(last.label)))</text>"
    return l + r
  }

  private static func bounds(_ vals: [Double]) -> (Double, Double) {
    let lo = vals.min() ?? 0, hi = vals.max() ?? 1
    if lo == hi { return (lo - 1, hi + 1) }
    let pad = (hi - lo) * 0.08
    return (lo - pad, hi + pad)
  }

  // MARK: - Formatting / safety

  private static func fmt(_ d: Double) -> String {
    if d == d.rounded() { return String(Int(d)) }
    return String(format: "%.1f", d)
  }

  private static func windowLabel(_ days: Int) -> String {
    switch days {
    case 365: return "12 months"
    case 90:  return "90 days"
    case 60:  return "60 days"
    case 30:  return "30 days"
    default:  return "\(days) days"
    }
  }

  /// Only let through CSS-safe color tokens; otherwise fall back to a neutral
  /// blue so a malformed stored color can't break the layout or inject markup.
  private static func safeColor(_ raw: String) -> String {
    let t = raw.trimmingCharacters(in: .whitespaces)
    if t.range(of: "^#[0-9A-Fa-f]{3,8}$", options: .regularExpression) != nil { return t }
    if t.range(of: "^(hsl|hsla|rgb|rgba)\\([0-9.,%\\s/]+\\)$", options: .regularExpression) != nil { return t }
    return "#3b82f6"
  }

  private static func esc(_ s: String) -> String {
    var out = s
    out = out.replacingOccurrences(of: "&", with: "&amp;")
    out = out.replacingOccurrences(of: "<", with: "&lt;")
    out = out.replacingOccurrences(of: ">", with: "&gt;")
    out = out.replacingOccurrences(of: "\"", with: "&quot;")
    out = out.replacingOccurrences(of: "'", with: "&#39;")
    return out
  }

  // MARK: - Stylesheet

  private static let css = """
  :root { color-scheme: light; }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: #f4f5f7;
    font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", system-ui, sans-serif;
    color: #1c1c1e; -webkit-font-smoothing: antialiased;
  }
  .report { max-width: 820px; margin: 0 auto; padding: 32px 20px 60px; }
  .head { padding: 8px 4px 20px; }
  .brand { display: inline-block; font-size: 12px; letter-spacing: 0.12em; text-transform: uppercase; color: #8e8e93; font-weight: 600; text-decoration: none; }
  .brand:hover { color: #636366; }
  .head h1 { font-size: 26px; line-height: 1.2; margin: 6px 0 2px; font-weight: 700; }
  .owner { font-size: 16px; color: #3a3a3c; font-weight: 500; }
  .note { margin: 12px 0 0; color: #3a3a3c; background: #fff; border-radius: 10px; padding: 12px 14px; border: 1px solid #e5e5ea; }
  .meta { margin-top: 14px; font-size: 13px; color: #8e8e93; }
  .meta .dot { margin: 0 6px; }
  .card { background: #fff; border: 1px solid #e5e5ea; border-radius: 16px; padding: 18px 18px 20px; margin: 16px 0; }
  .ch { display: flex; align-items: center; gap: 9px; margin-bottom: 14px; }
  .swatch { width: 11px; height: 11px; border-radius: 3px; background: var(--accent); display: inline-block; }
  .ch h2 { font-size: 17px; margin: 0; font-weight: 650; }
  .stats { display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 6px; }
  .stat { flex: 1 1 120px; background: #f7f7f9; border-radius: 10px; padding: 12px 14px; }
  .sv { font-size: 22px; font-weight: 700; letter-spacing: -0.01em; }
  .sl { font-size: 12px; color: #6c6c70; margin-top: 2px; }
  .sd { font-size: 11px; color: #a0a0a5; margin-top: 1px; }
  .chart { margin-top: 16px; }
  .ct { font-size: 13px; color: #6c6c70; margin-bottom: 6px; font-weight: 500; }
  .ct .unit { color: #a0a0a5; }
  svg.g { width: 100%; height: auto; display: block; }
  .axd { font-size: 10px; fill: #a0a0a5; }
  .axn { font-size: 10px; fill: #c7c7cc; }
  .tbl { width: 100%; border-collapse: collapse; font-size: 13px; }
  .tbl th { text-align: right; font-weight: 600; color: #8e8e93; padding: 6px 8px; border-bottom: 1px solid #e5e5ea; font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; }
  .tbl th:first-child { text-align: left; }
  .tbl td { text-align: right; padding: 7px 8px; border-bottom: 1px solid #f0f0f2; font-variant-numeric: tabular-nums; }
  .tbl td.rl { text-align: left; font-weight: 500; }
  .tbl tr:last-child td { border-bottom: none; }
  .goal { margin: 10px 0; }
  .grow { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; }
  .gt { font-size: 14px; font-weight: 500; }
  .gh { color: #22c55e; font-weight: 700; margin-right: 5px; }
  .gd { font-size: 12px; color: #8e8e93; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .gbar { height: 6px; background: #ececef; border-radius: 3px; margin-top: 5px; overflow: hidden; }
  .gfill { height: 100%; border-radius: 3px; }
  .empty { color: #a0a0a5; font-size: 14px; font-style: italic; margin: 4px 0 0; }
  .foot { margin-top: 28px; padding: 0 4px; color: #a0a0a5; font-size: 12px; }
  .foot p { margin: 4px 0; }
  .foot .gen { color: #c7c7cc; }
  .foot a { color: #8e8e93; text-decoration: none; }
  .foot a:hover { text-decoration: underline; }
  @media (prefers-color-scheme: dark) {
    body { background: #000; color: #f2f2f7; }
    .note, .card { background: #1c1c1e; border-color: #38383a; }
    .stat { background: #2c2c2e; }
    .sl { color: #aeaeb2; } .owner { color: #d1d1d6; } .note { color: #d1d1d6; }
  }
  """
}
