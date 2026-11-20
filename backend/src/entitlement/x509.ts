import { fromBase64Url } from "../util.js";

// Just enough DER / X.509 to check an Apple-signed certificate chain with
// WebCrypto: the signed TBS bytes, the signature, the validity window, the
// subject public key and the extension OIDs. No dependency: the Worker ships
// without an X.509 library, and Apple's chain is three fixed-shape EC certs.

export class CertError extends Error {}

interface Tlv {
  tag: number;
  /// Offset of the tag byte (start of the whole element).
  start: number;
  /// Content range.
  body: number;
  end: number;
}

function readTlv(buf: Uint8Array, at: number, limit = buf.length): Tlv {
  if (at + 2 > limit) throw new CertError("truncated DER");
  const tag = buf[at];
  let len = buf[at + 1];
  let body = at + 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 3 || body + n > limit) throw new CertError("bad DER length");
    len = 0;
    for (let i = 0; i < n; i++) len = (len << 8) | buf[body + i];
    body += n;
  }
  const end = body + len;
  if (end > limit) throw new CertError("truncated DER");
  return { tag, start: at, body, end };
}

/// The direct children of a constructed element.
function children(buf: Uint8Array, parent: Tlv): Tlv[] {
  const out: Tlv[] = [];
  for (let at = parent.body; at < parent.end; ) {
    const t = readTlv(buf, at, parent.end);
    out.push(t);
    at = t.end;
  }
  return out;
}

function hex(buf: Uint8Array, t: Tlv): string {
  return [...buf.subarray(t.body, t.end)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// DER-encoded OID bodies, hex.
const OID = {
  ecdsaSha256: "2a8648ce3d040302",
  ecdsaSha384: "2a8648ce3d040303",
  p256: "2a8648ce3d030107",
  p384: "2b81040022",
} as const;

export interface Cert {
  der: Uint8Array<ArrayBuffer>;
  tbs: Uint8Array<ArrayBuffer>;
  sigHash: "SHA-256" | "SHA-384";
  /// DER ECDSA-Sig-Value from the BIT STRING.
  sigDer: Uint8Array<ArrayBuffer>;
  notBefore: number;
  notAfter: number;
  spki: Uint8Array<ArrayBuffer>;
  curve: "P-256" | "P-384";
  /// Extension OIDs present, as DER body hex.
  extensionOids: Set<string>;
}

function parseTime(buf: Uint8Array, t: Tlv): number {
  const s = new TextDecoder().decode(buf.subarray(t.body, t.end));
  let m: RegExpMatchArray | null;
  if (t.tag === 0x17 && (m = s.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/))) {
    const yy = Number(m[1]);
    return Date.UTC(yy >= 50 ? 1900 + yy : 2000 + yy, Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]));
  }
  if (t.tag === 0x18 && (m = s.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/))) {
    return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]));
  }
  throw new CertError("bad certificate time");
}

export function parseCert(der: Uint8Array<ArrayBuffer>): Cert {
  const root = readTlv(der, 0);
  if (root.tag !== 0x30 || root.end !== der.length) throw new CertError("not a certificate");
  const [tbsT, algT, sigT] = children(der, root);
  if (!tbsT || !algT || !sigT || tbsT.tag !== 0x30 || algT.tag !== 0x30 || sigT.tag !== 0x03) {
    throw new CertError("not a certificate");
  }
  const algOid = children(der, algT)[0];
  const alg = algOid ? hex(der, algOid) : "";
  const sigHash = alg === OID.ecdsaSha256 ? "SHA-256" : alg === OID.ecdsaSha384 ? "SHA-384" : null;
  if (!sigHash) throw new CertError("unsupported signature algorithm");
  if (der[sigT.body] !== 0) throw new CertError("bad signature bit string");

  let fields = children(der, tbsT);
  if (fields[0]?.tag === 0xa0) fields = fields.slice(1); // explicit version
  // serial, signature, issuer, validity, subject, spki, [1], [2], [3]
  const [, , , validityT, , spkiT, ...rest] = fields;
  if (!validityT || !spkiT || validityT.tag !== 0x30 || spkiT.tag !== 0x30) throw new CertError("bad TBS");
  const [nbT, naT] = children(der, validityT);
  const spkiAlg = children(der, children(der, spkiT)[0]);
  const curveHex = spkiAlg[1] ? hex(der, spkiAlg[1]) : "";
  const curve = curveHex === OID.p256 ? "P-256" : curveHex === OID.p384 ? "P-384" : null;
  if (!curve) throw new CertError("unsupported key");

  const extensionOids = new Set<string>();
  const extWrap = rest.find((t) => t.tag === 0xa3);
  if (extWrap) {
    const seq = children(der, extWrap)[0];
    if (seq) for (const ext of children(der, seq)) {
      const id = children(der, ext)[0];
      if (id?.tag === 0x06) extensionOids.add(hex(der, id));
    }
  }

  return {
    der,
    tbs: der.slice(tbsT.start, tbsT.end),
    sigHash,
    sigDer: der.slice(sigT.body + 1, sigT.end),
    notBefore: parseTime(der, nbT),
    notAfter: parseTime(der, naT),
    spki: der.slice(spkiT.start, spkiT.end),
    curve,
    extensionOids,
  };
}

/// DER ECDSA-Sig-Value → the IEEE P1363 r||s form WebCrypto verifies.
function ecdsaDerToRaw(sig: Uint8Array, size: number): Uint8Array<ArrayBuffer> {
  const seq = readTlv(sig, 0);
  const [r, s] = children(sig, seq);
  if (seq.tag !== 0x30 || r?.tag !== 0x02 || s?.tag !== 0x02) throw new CertError("bad ECDSA signature");
  const out = new Uint8Array(size * 2);
  for (const [i, t] of [r, s].entries()) {
    let v = sig.subarray(t.body, t.end);
    while (v.length > size && v[0] === 0) v = v.subarray(1);
    if (v.length > size) throw new CertError("bad ECDSA signature");
    out.set(v, i * size + (size - v.length));
  }
  return out;
}

export function importCertKey(cert: Pick<Cert, "spki" | "curve">): Promise<CryptoKey> {
  return crypto.subtle.importKey("spki", cert.spki, { name: "ECDSA", namedCurve: cert.curve }, false, ["verify"]);
}

/// True when `issuerKey` (on `issuerCurve`) signed `cert`.
export async function certSignedBy(cert: Cert, issuerKey: CryptoKey, issuerCurve: "P-256" | "P-384"): Promise<boolean> {
  const raw = ecdsaDerToRaw(cert.sigDer, issuerCurve === "P-256" ? 32 : 48);
  return crypto.subtle.verify({ name: "ECDSA", hash: cert.sigHash }, issuerKey, raw, cert.tbs);
}

export function fromBase64(s: string): Uint8Array<ArrayBuffer> {
  // x5c entries are standard base64; fromBase64Url accepts both alphabets
  // once + and / pass through its replacements unchanged.
  return fromBase64Url(s.replace(/=+$/, ""));
}

export async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return [...d].map((b) => b.toString(16).padStart(2, "0")).join("");
}
