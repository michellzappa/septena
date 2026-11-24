import qrcode from "qrcode-generator";
import { escapeHtml } from "../util.js";

// The QR form of a sign-in code (ADR 0016). The code is still the secret the
// user approves; the QR only carries it from one screen to the other camera,
// so nobody has to read and type eight characters.
//
// The QR holds a URL, `<API_PUBLIC_URL>/pair/<CODE>`, not the bare code:
//   - Septena's own scanner reads the code from the last path component and
//     then shows the same "Sign in on <device>?" confirmation as a typed code.
//   - A phone's system camera opens the URL in a browser. That page only says
//     where to scan it (`pairLandingPage`). The app registers no handler for
//     this URL on purpose: a link in an email or a chat must never open a
//     prefilled approval. Only a deliberate scan inside the app approves.
//
// One encoder for every surface: the authorize page draws the SVG, and
// `/v1/auth/device/start` returns the module matrix so a client (Android)
// draws the same QR without a QR library of its own.

/// The URL a sign-in QR encodes. `code` is a normalized 8-character code.
export function pairApproveUrl(publicUrl: string, code: string): string {
  return `${publicUrl.replace(/\/$/, "")}/pair/${code}`;
}

function encode(text: string) {
  // M recovers ~15% of the modules: enough for a screen photographed at an
  // angle, and the ~37-byte URL still fits version 3 (29×29).
  const qr = qrcode(0, "M");
  qr.addData(text, "Byte");
  qr.make();
  return qr;
}

/// The QR as plain JSON for a client to draw: `size` modules per side and
/// `modules`, size×size characters row by row, "1" dark and "0" light. The
/// client adds the 4-module quiet zone.
export function pairQrMatrix(text: string): { size: number; modules: string } {
  const qr = encode(text);
  const size = qr.getModuleCount();
  let modules = "";
  for (let r = 0; r < size; r++) {
    for (let c = 0; c < size; c++) modules += qr.isDark(r, c) ? "1" : "0";
  }
  return { size, modules };
}

/// An inline SVG, dark modules on white with the 4-module quiet zone. It stays
/// dark-on-white in dark mode too: not every scanner reads an inverted QR.
export function pairQrSvg(text: string, label: string): string {
  const qr = encode(text);
  const size = qr.getModuleCount();
  const quiet = 4;
  const side = size + quiet * 2;
  let path = "";
  for (let r = 0; r < size; r++) {
    for (let c = 0; c < size; c++) {
      if (qr.isDark(r, c)) path += `M${c + quiet} ${r + quiet}h1v1h-1z`;
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${side} ${side}" shape-rendering="crispEdges" role="img" aria-label="${escapeHtml(label)}"><rect width="${side}" height="${side}" fill="#fff"/><path d="${path}" fill="#000"/></svg>`;
}
