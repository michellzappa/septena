import Foundation
import Photos
#if os(iOS)
import UIKit
import SwiftUI
#endif

// Camera capture for photo-first meal logging.
//
// A captured frame isn't in the photo library, but meal entries render their
// thumbnail from a PHAsset `photoAssetID` (see `MealPhotoThumbnail`). So we save
// the JPEG to Photos to mint a stable identifier, then hand the same bytes to
// `MealPhotoAnalyzer`. Camera is iOS-only (no `UIImagePickerController` on macOS
// / the Simulator has no camera), so `MealCamera.isAvailable` is false there and
// callers fall back to the photo-library picker.

enum MealCamera {
  static var isAvailable: Bool {
    #if os(iOS)
    return UIImagePickerController.isSourceTypeAvailable(.camera)
    #else
    return false
    #endif
  }
}

enum MealPhotoLibrary {
  /// Save JPEG data as a new photo asset and return its localIdentifier for use
  /// as a meal `photoAssetID`. nil if the save fails or access is denied — the
  /// caller still analyzes the bytes, it just won't have a thumbnail.
  static func save(_ data: Data) async -> String? {
    var localID: String?
    do {
      try await PHPhotoLibrary.shared().performChanges {
        let req = PHAssetCreationRequest.forAsset()
        req.addResource(with: .photo, data: data, options: nil)
        localID = req.placeholderForCreatedAsset?.localIdentifier
      }
    } catch {
      return nil
    }
    return localID
  }
}

#if os(iOS)
/// Thin `UIImagePickerController` wrapper in camera mode. Calls `onCapture` with
/// the photo (or nil if the user cancels); dismissal is the caller's job.
struct MealCameraPicker: UIViewControllerRepresentable {
  let onCapture: (UIImage?) -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.cameraCaptureMode = .photo
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let onCapture: (UIImage?) -> Void
    init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }

    func imagePickerController(_ picker: UIImagePickerController,
                              didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
      onCapture(info[.originalImage] as? UIImage)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      onCapture(nil)
    }
  }
}
#endif
