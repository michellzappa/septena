import Foundation
import Darwin
import Network

// Who may reach the local MCP server. The server binds all interfaces but
// admits a connection only when its *source address* passes the active scope —
// a source-IP allowlist rather than an interface restriction, because
// Network.framework can't name a VPN interface (Tailscale shows up as an
// anonymous utun) and the tailnet IP can change. Loopback is always allowed so
// a Claude Code on this same Mac keeps working in every scope.
//
// The bearer token is still required on top of this — the scope decides *which
// networks can knock*, the token decides *who gets in*.

public enum MCPAccessScope: String, CaseIterable, Sendable {
  /// Loopback only. A Claude Code running on this Mac. (Default.)
  case thisMac = "local"
  /// Loopback + this machine's Tailscale tailnet. Other devices you own can
  /// connect over WireGuard; the public internet and local Wi-Fi cannot.
  case tailnet = "tailnet"

  public var label: String {
    switch self {
    case .thisMac: return "This Mac only"
    case .tailnet: return "My tailnet"
    }
  }

  static var current: MCPAccessScope {
    MCPAccessScope(rawValue: UserDefaults.standard.string(forKey: MCPDefaultsKey.scope) ?? "")
      ?? .thisMac
  }
}

/// Classifies a connection's remote address against the active scope.
enum MCPAddressGuard {

  /// True when a peer at `host` may connect under `scope`.
  static func allows(host: NWHostBytes, scope: MCPAccessScope) -> Bool {
    if host.isLoopback { return true }       // same-Mac Claude Code, every scope
    switch scope {
    case .thisMac: return false
    case .tailnet: return host.isTailscale
    }
  }
}

/// The raw bytes of a peer's IP, normalized so IPv4-mapped IPv6
/// (`::ffff:a.b.c.d`, which a dual-stack listener reports) is treated as IPv4.
struct NWHostBytes {
  /// 4 bytes for IPv4, 16 for IPv6.
  let bytes: [UInt8]

  init?(_ host: NWEndpoint.Host) {
    switch host {
    case .ipv4(let a): self.bytes = [UInt8](a.rawValue)
    case .ipv6(let a):
      let b = [UInt8](a.rawValue)
      // Unwrap ::ffff:0:0/96 to the embedded IPv4.
      if b.count == 16, b[0...9].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
        self.bytes = Array(b[12...15])
      } else {
        self.bytes = b
      }
    @unknown default:
      return nil
    }
  }

  var isLoopback: Bool {
    if bytes.count == 4 { return bytes[0] == 127 }                 // 127.0.0.0/8
    if bytes.count == 16 { return bytes[0...14].allSatisfy { $0 == 0 } && bytes[15] == 1 } // ::1
    return false
  }

  /// Tailscale's address space: 100.64.0.0/10 (IPv4 CGNAT) and
  /// fd7a:115c:a1e0::/48 (its ULA prefix).
  var isTailscale: Bool {
    if bytes.count == 4 {
      return bytes[0] == 100 && (bytes[1] & 0xC0) == 0x40
    }
    if bytes.count == 16 {
      return bytes[0] == 0xfd && bytes[1] == 0x7a && bytes[2] == 0x11
          && bytes[3] == 0x5c && bytes[4] == 0xa1 && bytes[5] == 0xe0
    }
    return false
  }
}

/// Best-effort discovery of this Mac's own Tailscale IPv4, for building the
/// connect URL shown in Settings. Walks the interface list and returns the
/// first address in 100.64.0.0/10. Nil when Tailscale isn't up.
enum TailnetAddress {
  static func ipv4() -> String? {
    var ptr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ptr) == 0, let first = ptr else { return nil }
    defer { freeifaddrs(ptr) }

    var node = Optional(first)
    while let cur = node {
      defer { node = cur.pointee.ifa_next }
      guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
      var addr = sockaddr_in()
      memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
      let raw = addr.sin_addr.s_addr.bigEndian
      let b0 = UInt8((raw >> 24) & 0xff), b1 = UInt8((raw >> 16) & 0xff)
      guard b0 == 100, (b1 & 0xC0) == 0x40 else { continue }       // 100.64.0.0/10
      var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
      return String(cString: buf)
    }
    return nil
  }
}
