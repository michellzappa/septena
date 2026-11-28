@preconcurrency import AVFoundation
import SwiftUI

/// Scans the QR form of a sign-in code (ADR 0016). The other device shows the
/// QR next to its 8-character code: the Claude authorize page in a browser, or
/// a new Android device. The QR holds `https://api.septena.app/pair/<CODE>`
/// (backend `src/shadow/pairQr.ts`).
///
/// A scan only fills in the code. `SeptaskApproveSignInFlow` then looks it up
/// and shows "Sign in on <device>?" exactly as for a typed code, so scanning
/// never approves anything on its own. The app registers no handler for the
/// URL: a link in an email or a chat cannot open a prefilled approval.
///
/// One implementation for iPhone, iPad and Mac: `AVCaptureMetadataOutput`
/// reads QR codes on both. A Mac scans with its built-in or Continuity camera
/// (for example the QR on an Android phone).
struct SeptaskSignInCodeScanner: View {
  /// Gets the normalized 8-character code once, then the sheet closes.
  var onCode: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var camera = SignInCodeCamera()
  private static let prompt = RegistryPrompts.fixed[.scanSignInCode]
  private static let unavailable = RegistryPrompts.fixed[.cameraUnavailable]

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        switch camera.state {
        case .starting, .running:
          CameraPreview(session: camera.session, device: camera.device)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
              if camera.state == .starting { ProgressView() }
            }
          Text(Self.prompt?.message ?? "")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        case .unavailable:
          Image(systemName: "video.slash")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text(Self.unavailable?.title ?? "")
            .font(.headline)
            .multilineTextAlignment(.center)
          Text(Self.unavailable?.message ?? "")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }
      .frame(maxWidth: 420)
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(Self.prompt?.title ?? "")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
      }
    }
    #if os(macOS)
    .frame(minWidth: 420, minHeight: 480)
    #endif
    .task {
      camera.onPayload = { payload in
        guard let code = Self.code(from: payload) else { return false }
        Haptics.success()
        onCode(code)
        dismiss()
        return true
      }
      await camera.start()
    }
    .onDisappear { camera.stop() }
  }

  /// The code in a scanned QR: `<backend>/pair/<CODE>` on the task backend's
  /// own host, or a bare code. Anything else is not a Septena sign-in code
  /// and the scanner keeps looking.
  static func code(from payload: String) -> String? {
    let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: text), let scheme = url.scheme {
      guard scheme == "https",
            url.host?.lowercased() == TaskBackendClient.baseURL.host?.lowercased() else { return nil }
      let parts = url.path.split(separator: "/")
      guard parts.count == 2, parts[0] == "pair" else { return nil }
      return SeptaskApproveSignInFlow.normalized(String(parts[1]))
    }
    return SeptaskApproveSignInFlow.normalized(text)
  }
}

/// The "Scan Code" button next to a code field. Hidden on a device with no
/// camera (most Macs without one attached), where the field is the only way.
struct SeptaskScanCodeButton: View {
  var onCode: (String) -> Void
  @State private var scanning = false
  private static let prompt = RegistryPrompts.fixed[.scanSignInCode]

  var body: some View {
    if SignInCodeCamera.hasCamera {
      Button {
        scanning = true
      } label: {
        Label(Self.prompt?.confirmTitle ?? "",
              systemImage: RegistryIcons.sfSymbols["auth.scan_code"] ?? "qrcode.viewfinder")
      }
      .sheet(isPresented: $scanning) {
        SeptaskSignInCodeScanner(onCode: onCode)
      }
    }
  }
}

// MARK: - Camera

/// The capture session behind the scanner. Session start and stop run on a
/// private serial queue (they block); the metadata callback runs on the main
/// queue, where `onPayload` decides whether the payload is a code.
@MainActor @Observable
final class SignInCodeCamera {
  enum State: Equatable { case starting, running, unavailable }

  private(set) var state: State = .starting
  /// Returns true when the payload was a code; the camera then stops reading.
  var onPayload: ((String) -> Bool)?

  @ObservationIgnored let session = AVCaptureSession()
  @ObservationIgnored private let queue = DispatchQueue(label: "app.septena.signin-scanner")
  @ObservationIgnored private let reader = MetadataReader()
  @ObservationIgnored private var configured = false
  /// The camera in use, once `start` picked one (the iOS preview rotates by it).
  @ObservationIgnored private(set) var device: AVCaptureDevice?

  static var hasCamera: Bool { captureDevice() != nil }

  private static func captureDevice() -> AVCaptureDevice? {
    #if os(iOS)
    AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
      ?? AVCaptureDevice.default(for: .video)
    #else
    AVCaptureDevice.default(for: .video)
    #endif
  }

  func start() async {
    guard await Self.authorized(), let device = Self.captureDevice() else {
      state = .unavailable
      return
    }
    if !configured {
      guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
        state = .unavailable
        return
      }
      let output = AVCaptureMetadataOutput()
      session.beginConfiguration()
      session.addInput(input)
      guard session.canAddOutput(output) else {
        session.commitConfiguration()
        state = .unavailable
        return
      }
      session.addOutput(output)
      // The QR type is only available once the output joined the session.
      guard output.availableMetadataObjectTypes.contains(.qr) else {
        session.commitConfiguration()
        state = .unavailable
        return
      }
      output.metadataObjectTypes = [.qr]
      session.commitConfiguration()
      reader.onPayload = { [weak self] payload in
        MainActor.assumeIsolated {
          guard let self, let onPayload = self.onPayload else { return false }
          if onPayload(payload) {
            self.onPayload = nil
            self.stop()
            return true
          }
          return false
        }
      }
      output.setMetadataObjectsDelegate(reader, queue: .main)
      self.device = device
      configured = true
    }
    let session = self.session
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      queue.async {
        session.startRunning()
        done.resume()
      }
    }
    state = session.isRunning ? .running : .unavailable
  }

  func stop() {
    let session = self.session
    queue.async {
      if session.isRunning { session.stopRunning() }
    }
  }

  private static func authorized() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
    default: return false
    }
  }
}

/// The metadata delegate. A separate object so the `@MainActor` camera does
/// not have to conform to a nonisolated delegate protocol.
private final class MetadataReader: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
  /// Called on the main queue (the delegate queue). True ends the reading.
  var onPayload: ((String) -> Bool)?
  private var done = false

  func metadataOutput(_ output: AVCaptureMetadataOutput,
                      didOutput metadataObjects: [AVMetadataObject],
                      from connection: AVCaptureConnection) {
    guard !done else { return }
    for object in metadataObjects {
      guard let qr = object as? AVMetadataMachineReadableCodeObject,
            let payload = qr.stringValue else { continue }
      if onPayload?(payload) == true {
        done = true
        return
      }
    }
  }
}

// MARK: - Preview

#if os(iOS)
private struct CameraPreview: UIViewRepresentable {
  let session: AVCaptureSession
  let device: AVCaptureDevice?

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspectFill
    return view
  }

  func updateUIView(_ view: PreviewView, context: Context) {
    view.follow(device)
  }

  /// Keeps the preview upright when an iPad turns (the system's rotation
  /// coordinator; QR reading itself does not depend on it).
  final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?

    func follow(_ device: AVCaptureDevice?) {
      guard let device, coordinator?.device != device else { return }
      let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
      self.coordinator = coordinator
      apply(coordinator.videoRotationAngleForHorizonLevelPreview)
      observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, change in
        guard let angle = change.newValue else { return }
        DispatchQueue.main.async { self?.apply(angle) }
      }
    }

    private func apply(_ angle: CGFloat) {
      guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
      connection.videoRotationAngle = angle
    }
  }
}
#else
private struct CameraPreview: NSViewRepresentable {
  let session: AVCaptureSession
  let device: AVCaptureDevice?

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspectFill
    view.layer = layer
    view.wantsLayer = true
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}
#endif
