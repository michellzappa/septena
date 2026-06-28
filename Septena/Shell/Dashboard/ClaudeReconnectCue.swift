import SwiftUI

// MARK: - Claude reconnect cue
//
// Subtle, non-modal cue shown only when the Claude gateway token has gone stale
// (the app never auto-pops the Apple sign-in). Tapping it is an explicit user
// action, so presenting the sign-in here is expected. Two presentations, same
// state + tap-to-re-mint logic:
//   • `.pill` — an icon-only control in the top bar's trailing corner (iOS):
//     a plain Button the SYSTEM draws as a regular Liquid Glass circle, the
//     same treatment as the "…" menu opposite it. No custom glass (that nests
//     glass-in-glass — the idiom this codebase already follows for the drawer
//     and Tasks "+"); the Claude accent rides in only via `.tint`.
//   • `.card` — the full-width inline glass card stacked above the dashboard,
//     used on macOS where the menu lives top-right, not in a leading bar.
struct ClaudeReconnectCue: View {
  //   • `.overlayCircle` — like `.pill`, but for the iPad chrome OVERLAY (not a
  //     toolbar): we draw our OWN glass circle (`.buttonStyle(.glass)` +
  //     `.buttonBorderShape(.circle)`) and frame the glyph to the same 30pt box
  //     the gear/···/+ use, so it reads as a distinct equal-sized circle beside
  //     "+" instead of an odd small shape that blends into it.
  enum Presentation { case pill, card, overlayCircle }
  let presentation: Presentation
  init(_ presentation: Presentation) { self.presentation = presentation }

  @State private var provider = ClaudeGatewayProvider.shared
  // Briefly held true after a successful re-mint so the tap closes the loop
  // with a "Reconnected" flash instead of the cue silently vanishing.
  @State private var justReconnected = false

  // A real refresh failure (network etc.) — distinct from a user-cancel,
  // which leaves `lastError` nil so the cue stays in its calm default copy.
  private var failed: Bool { provider.lastError != nil && provider.needsReauth }

  var body: some View {
    if provider.isEnabled && (provider.needsReauth || justReconnected) {
      switch presentation {
      case .pill: pillButton
      case .card: cardButton
      case .overlayCircle: overlayCircleButton
      }
    }
  }

  private func tap() {
    guard !justReconnected, !provider.isRefreshing else { return }
    Task {
      if await provider.refreshNow() {
        Haptics.success()
        withAnimation(.snappy) { justReconnected = true }
        try? await Task.sleep(for: .seconds(1.6))
        withAnimation(.snappy) { justReconnected = false }
      }
    }
  }

  // Top-bar control: a plain Button the SYSTEM draws as a regular Liquid Glass
  // circle — matching the "…" menu opposite it, no custom glass. `.tint` only
  // carries the Claude accent into the glyph. The glyph swaps per state:
  // the device's biometry mark by default (a lapsed token is an auth
  // checkpoint, not a fault — "verify it's you," not a warning), a green check
  // on the post-reconnect flash, a spinner mid-refresh, and an orange triangle
  // ONLY when a reconnect genuinely failed.
  private var pillButton: some View {
    Button(action: tap) {
      pillGlyph
        .accessibilityLabel(justReconnected ? "Reconnected" : "Reconnect Claude")
    }
    .tint(Color.claudeAccent)
    .disabled(justReconnected)
  }

  // Standalone glass circle for the iPad chrome overlay — a self-contained
  // `.glass` button (the system draws the glass; the 30pt glyph frame matches
  // the gear/···/+ so all the bar's circles are one size and read as separate
  // bubbles, never merged).
  private var overlayCircleButton: some View {
    Button(action: tap) {
      pillGlyph
        .font(.title3.weight(.semibold))
        .frame(width: 30, height: 30)
        .accessibilityLabel(justReconnected ? "Reconnected" : "Reconnect Claude")
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .tint(Color.claudeAccent)
    .disabled(justReconnected)
  }

  @ViewBuilder private var pillGlyph: some View {
    if justReconnected {
      SecuredLockGlyph()
    } else if provider.isRefreshing {
      ProgressView().controlSize(.mini)
    } else if failed {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    } else {
      // Biometry mark (Face/Touch/Optic ID), tinted Claude by the button's
      // `.tint`: the connection lapsed by design and re-authenticating is the
      // security boundary, not a problem to alarm about.
      Image(systemName: AppLock.biometrySymbolName)
    }
  }

  // Inline card (macOS): a custom full-width glass card, so it keeps `.plain`
  // and carries its own `glassCard` background.
  private var cardButton: some View {
    Button(action: tap) { cardLabel }
      .buttonStyle(.plain)
      .disabled(justReconnected)
  }

  // Full-width inline card (macOS): glyph + word + muted context line.
  private var cardLabel: some View {
    HStack(spacing: 8) {
      leadingGlyph
      title
      if let subtitle {
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(-1)
      }
      Spacer(minLength: 8)
      if provider.isRefreshing {
        ProgressView().controlSize(.small)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity)
    .glassCard(tint: Color.claudeAccent)
  }

  @ViewBuilder private var leadingGlyph: some View {
    if justReconnected {
      SecuredLockGlyph(font: .subheadline)
    } else if failed {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.subheadline)
        .foregroundStyle(.orange)
    } else {
      // Biometry mark, not an alarm dot: a lapsed token is an auth checkpoint.
      Image(systemName: AppLock.biometrySymbolName)
        .font(.subheadline)
        .foregroundStyle(Color.claudeAccent)
    }
  }

  @ViewBuilder private var title: some View {
    Text(justReconnected ? "Reconnected" : "Reconnect")
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(justReconnected ? Color.green : Color.claudeAccent)
  }

  // Muted context line (card only). Default framing is a security checkpoint,
  // not a nag: access lapses by design and you re-authenticate to restore it.
  private var subtitle: String? {
    if justReconnected { return nil }
    if failed { return "Couldn’t reconnect — tap to retry" }
    return "Verify it’s you to reconnect"
  }
}

// MARK: - Secured-lock flash
//
// The brief "you're reconnected" confirmation: a green `lock.fill` that simply
// pops in with a spring-y zoom — no glyph swap — so the flash reads as "the
// connection is secure again," echoing the biometry/lock language of the
// default cue and AppLock.
private struct SecuredLockGlyph: View {
  var font: Font?
  @State private var shown = false

  var body: some View {
    Image(systemName: "lock.fill")
      .font(font)
      .foregroundStyle(.green)
      .scaleEffect(shown ? 1 : 0.6)
      .opacity(shown ? 1 : 0)
      .onAppear {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { shown = true }
      }
  }
}
