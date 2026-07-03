import SwiftUI

// WatchSky — the wrist's time-of-day canvas, the watch echo of the phone's
// `SkyTopWash`. Same two halves the phone uses: `SolarClock.elevation`
// (time-zone geography, no permission) feeding the physical `SkyAtmosphere`
// model, both compiled straight into the watch target — so the wrist and the
// phone show the same sky overhead. Unlike the phone (a subtle top wash that
// melts into a paper page) the watch screen IS the sky, full-bleed, à la the
// Weather app: a deep blue noon, an ember dusk, a near-black night that needs
// no dimming because the atmosphere darkens on its own. The feed's rows float
// over it as Liquid-Glass cards (`watchGlassRow`) instead of the old opaque
// gray fill.

/// The full-bleed sky behind the watch feed. Renders the atmosphere off the
/// main thread and only when the sun has crossed a ~0.5° elevation bucket (the
/// same guard the phone uses), so the heavy march runs a handful of times a day,
/// not every tick.
struct WatchSkyWash: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var stops: [SkyAtmosphere.Stop] = []
  @State private var bucket: Int?

  var body: some View {
    ZStack {
      // Floor under the gradient so deep night is true OLED black (the wash's
      // own stops already fall to near-black, this just guarantees it).
      Color.black
      if !stops.isEmpty {
        LinearGradient(
          gradient: Gradient(stops: stops.map {
            .init(color: skyColor($0), location: $0.location)
          }),
          startPoint: .top, endPoint: .bottom
        )
      }
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .task { await refresh() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await refresh() } }
    }
    // The watch has no `DayClock`; the sky is presentation, not day-keyed data,
    // so reading the wall clock here is correct (same posture as the widget's
    // dial). A 5-minute poll keeps the wash current while the wrist is awake
    // without spinning the render — the bucket guard makes most ticks no-ops.
    .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
      Task { await refresh() }
    }
  }

  private func refresh() async {
    let elevation = SolarClock.elevation(now: Date())
    let b = Int((elevation / (0.5 * Double.pi / 180)).rounded())
    guard b != bucket else { return }
    let computed = await Task.detached(priority: .utility) {
      SkyAtmosphere.render(elevation: elevation)
    }.value
    bucket = b
    withAnimation(.easeInOut(duration: 1.0)) { stops = computed }
  }

  /// Tame the model's bright daytime horizon a touch so white wrist text stays
  /// legible over it; night is already near-black, so this barely touches it.
  /// The glass row backings carry the real local contrast on top.
  private func skyColor(_ s: SkyAtmosphere.Stop) -> Color {
    let dim = 0.7
    return Color(.sRGB, red: s.r * dim, green: s.g * dim, blue: s.b * dim, opacity: 1)
  }
}

extension View {
  /// Clear the *system* list-row fill so the sky shows through the gaps between
  /// rows; the row's own frosted pill (a translucent `.ultraThinMaterial` card,
  /// set in `NextItemRow.actionRow`) is what gives each row its containment —
  /// the Reminders / Things wrist pattern. (We tried bare backgroundless rows
  /// first, per the HIG note that Liquid Glass is for the functional layer; on
  /// the wrist they read as floating text with no row separation, so the pill
  /// came back — kept translucent so the dimmed sky still tints through it.)
  /// `watchSkyList()` drops the list's own fill so only the pills + sky show.
  func watchSkyRow() -> some View {
    listRowBackground(Color.clear)
  }

  /// The frosted pill every feed row floats on — the single source for that look
  /// so every page's rows read the same. A soft translucent *white* rounded card
  /// (not `.ultraThinMaterial`, which renders near-black on watchOS and reads as
  /// a dark slab fighting the sky); the dimmed sky still tints through it, giving
  /// each row containment without an opaque fill (the Reminders / Things wrist
  /// pattern). `NextItemRow` layers its press / done highlight on top via
  /// `extraHighlight`; the static summary tiles pass 0. Pair with `watchSkyRow()`,
  /// which clears the *system* row fill so only this pill + the sky show.
  func watchGlassRow(extraHighlight: Double = 0) -> some View {
    background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.white.opacity(0.16 + extraHighlight))
    )
  }

  /// Drop the system list background so the sky canvas shows through the feed.
  func watchSkyList() -> some View {
    scrollContentBackground(.hidden)
  }
}
