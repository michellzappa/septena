import LocalAuthentication

/// SF Symbol matching the device's enrolled biometry — `faceid` / `touchid` /
/// `opticid`, or a neutral lock when none is enrolled. Split out of `AppLock`
/// (Septena/Shell/Security, not part of Septask's source list) so surfaces
/// that just want to gesture at "verify it's you" — like `ClaudeReconnectCue`,
/// shared with Septask — don't need to pull in the whole-app lock feature.
enum BiometrySymbol {
  static var systemName: String {
    let context = LAContext()
    _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) // populates biometryType
    switch context.biometryType {
    case .faceID:  return "faceid"
    case .touchID: return "touchid"
    case .opticID: return "opticid"
    default:       return "lock.fill"
    }
  }
}
