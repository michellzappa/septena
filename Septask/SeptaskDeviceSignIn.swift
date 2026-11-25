#if os(macOS)
import AppKit
import SwiftUI

// Sign-in by device approval (ADR 0016) for a Mac build without Sign in with
// Apple (`SeptaskSignIn.appleAvailable`): this Mac shows a code and its QR, and
// a signed-in Septena approves it (Settings ▸ Account ▸ Approve a sign-in).
// Android's `DeviceSignIn.kt` is the same flow. All copy comes from
// `registry/surfaces.json` (`deviceSignIn`).

/// Opens the code sheet. Stands in for the Apple button.
struct SeptaskDeviceSignInButton: View {
  @State private var showing = false

  var body: some View {
    Button(RegistryDeviceSignIn.start) { showing = true }
      .controlSize(.large)
      .sheet(isPresented: $showing) {
        SeptaskDeviceSignInSheet { showing = false }
      }
  }
}

/// The same sheet on the AppKit shell's main window.
@MainActor
enum SeptaskDeviceSignInWindow {
  private static var sheet: NSWindow?

  static func present() {
    guard sheet == nil, let parent = SeptaskKitWindowController.existing?.window else { return }
    let host = NSHostingController(rootView: SeptaskDeviceSignInSheet { dismiss() })
    let window = NSWindow(contentViewController: host)
    window.title = RegistryDeviceSignIn.title
    window.styleMask = [.titled]
    sheet = window
    parent.beginSheet(window)
  }

  private static func dismiss() {
    guard let window = sheet else { return }
    window.sheetParent?.endSheet(window)
    sheet = nil
  }
}

private struct SeptaskDeviceSignInSheet: View {
  let onClose: () -> Void

  private enum Step: Equatable {
    case requesting
    case code(BackendDeviceCode)
    case failed(String)
  }

  @State private var step: Step = .requesting
  /// Restarts the task below for a new code.
  @State private var attempt = 0

  var body: some View {
    VStack(spacing: 16) {
      Text(RegistryDeviceSignIn.title).font(.title2.weight(.semibold))
      switch step {
      case .requesting:
        ProgressView().frame(height: 220)
      case .code(let device):
        Text(RegistryDeviceSignIn.approve)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        if let dark = device.qr?.dark, let size = device.qr?.size {
          SignInQRImage(size: size, dark: dark)
        }
        Text(device.displayCode)
          .font(.title.monospaced())
          .textSelection(.enabled)
        Text(RegistryDeviceSignIn.lifetime)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        ProgressView().controlSize(.small)
      case .failed(let message):
        Text(message).foregroundStyle(.secondary)
        Button(RegistryDeviceSignIn.retry) {
          step = .requesting
          attempt += 1
        }
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onClose)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .frame(width: 420)
    .task(id: attempt) { await run() }
  }

  private func run() async {
    let client = TaskBackendClient.shared
    let device: BackendDeviceCode
    do {
      device = try await client.startDeviceSignIn(clientName: Self.deviceName)
    } catch {
      if !Task.isCancelled { step = .failed(RegistryDeviceSignIn.unreachable) }
      return
    }
    step = .code(device)
    let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
    while Date() < deadline {
      do { try await Task.sleep(for: .seconds(max(device.interval, 2))) } catch { return }
      // A failed poll (offline for a moment) is retried until the deadline.
      guard let result = try? await client.pollDeviceSignIn(device) else { continue }
      switch result {
      case .pending:
        continue
      case .expired:
        step = .failed(RegistryDeviceSignIn.expired)
        return
      case .approved(let session):
        // Its own task: the sheet goes away when `signedIn` flips, and the
        // server hands this session over only once.
        Task { @MainActor in
          try? await TaskSyncEngine.shared.signIn(deviceSession: session)
          TaskNotices.clearSignInDismissal()
          onClose()
        }
        return
      }
    }
    step = .failed(RegistryDeviceSignIn.expired)
  }

  /// Shown to the approving app. Must match the server's client-name pattern
  /// `[\w .()-]{1,40}`, so it is ASCII. A wire value, not UI copy.
  private static var deviceName: String {
    let raw = "Mac \(Host.current().localizedName ?? "")"
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ .()-")
    let ascii = String(raw.unicodeScalars.filter(allowed.contains).prefix(40).map(Character.init))
    return ascii.trimmingCharacters(in: .whitespaces)
  }
}

/// The sign-in QR from the server's matrix: black on white with the 4-module
/// quiet zone in both appearances, because not every scanner reads an inverted
/// one. Decorative for VoiceOver: the same code is the text under it.
private struct SignInQRImage: View {
  let size: Int
  let dark: [Bool]

  var body: some View {
    Canvas { context, canvas in
      let quiet = 4
      let module = canvas.width / CGFloat(size + quiet * 2)
      context.fill(Path(CGRect(origin: .zero, size: canvas)), with: .color(.white))
      var path = Path()
      for row in 0..<size {
        for column in 0..<size where dark[row * size + column] {
          // A hair of overlap so no seam shows between neighboring modules.
          path.addRect(CGRect(x: CGFloat(column + quiet) * module, y: CGFloat(row + quiet) * module,
                              width: module + 0.5, height: module + 0.5))
        }
      }
      context.fill(path, with: .color(.black))
    }
    .frame(width: 220, height: 220)
    .accessibilityHidden(true)
  }
}
#endif
