import { fromBase64Url } from "../util.js";
import { CertError, certSignedBy, fromBase64, importCertKey, parseCert, sha256Hex, type Cert } from "./x509.js";

// Verifies an App Store signed payload (StoreKit 2 JWSTransaction,
// JWSRenewalInfo, or an App Store Server Notification V2 `signedPayload`).
//
// The same check as Apple's App Store Server Library (SignedDataVerifier),
// done with WebCrypto:
//   1. header alg is ES256 and x5c carries [leaf, intermediate, root];
//   2. the intermediate is signed by Apple Root CA - G3, which is pinned here
//      (the chain's own root is never trusted);
//   3. the leaf is signed by the intermediate;
//   4. the leaf carries Apple's receipt-signing OID 1.2.840.113635.100.6.11.1,
//      the intermediate Apple's WWDR CA OID 1.2.840.113635.100.6.2.1;
//   5. both certificates are valid at the payload's own `signedDate`
//      (the library's rule when online revocation checks are off);
//   6. the leaf key verifies the JWS signature.
// No network call: the root is a constant, so a verification cannot fail
// because apple.com is slow.

/// Apple Root CA - G3, DER, base64. Source:
/// https://www.apple.com/certificateauthority/AppleRootCA-G3.cer (fetched
/// 2026-11-20). Valid 2014-04-30 to 2039-04-30.
/// SHA-256 fingerprint:
/// 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
export const APPLE_ROOT_CA_G3_B64 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==";
export const APPLE_ROOT_CA_G3_SHA256 =
  "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";

const LEAF_OID = "2a864886f76364060b01"; // 1.2.840.113635.100.6.11.1
const INTERMEDIATE_OID = "2a864886f76364060201"; // 1.2.840.113635.100.6.2.1

export class AppleJwsError extends Error {}

let rootCache: Promise<{ cert: Cert; key: CryptoKey }> | null = null;

function trustedRoot(): Promise<{ cert: Cert; key: CryptoKey }> {
  rootCache ??= (async () => {
    const der = fromBase64(APPLE_ROOT_CA_G3_B64);
    // Guards the constant against an accidental edit.
    if ((await sha256Hex(der)) !== APPLE_ROOT_CA_G3_SHA256) throw new Error("Apple root certificate constant is corrupt");
    const cert = parseCert(der);
    return { cert, key: await importCertKey(cert) };
  })();
  return rootCache;
}

function decodeJson<T>(part: string): T {
  try {
    return JSON.parse(new TextDecoder().decode(fromBase64Url(part))) as T;
  } catch {
    throw new AppleJwsError("malformed JWS");
  }
}

/// Verifies `jws` and returns its decoded payload. Throws AppleJwsError.
export async function verifyAppleJws<T extends { signedDate?: number }>(jws: string): Promise<T> {
  const parts = jws.split(".");
  if (parts.length !== 3) throw new AppleJwsError("malformed JWS");
  const [h, p, s] = parts;
  const header = decodeJson<{ alg?: string; x5c?: unknown }>(h);
  if (header.alg !== "ES256") throw new AppleJwsError("unexpected alg");
  if (!Array.isArray(header.x5c) || header.x5c.length !== 3 || !header.x5c.every((c) => typeof c === "string")) {
    throw new AppleJwsError("missing certificate chain");
  }
  const payload = decodeJson<T>(p);
  const at = typeof payload.signedDate === "number" ? payload.signedDate : Date.now();

  let leaf: Cert;
  let intermediate: Cert;
  try {
    leaf = parseCert(fromBase64(header.x5c[0] as string));
    intermediate = parseCert(fromBase64(header.x5c[1] as string));
  } catch (e) {
    throw new AppleJwsError(e instanceof CertError ? e.message : "bad certificate");
  }
  const root = await trustedRoot();

  if (!leaf.extensionOids.has(LEAF_OID)) throw new AppleJwsError("leaf is not an App Store signing certificate");
  if (!intermediate.extensionOids.has(INTERMEDIATE_OID)) throw new AppleJwsError("intermediate is not Apple WWDR");
  for (const c of [leaf, intermediate, root.cert]) {
    if (at < c.notBefore || at > c.notAfter) throw new AppleJwsError("certificate not valid at signedDate");
  }
  try {
    if (!(await certSignedBy(intermediate, root.key, root.cert.curve))) throw new AppleJwsError("intermediate not signed by Apple root");
    const intermediateKey = await importCertKey(intermediate);
    if (!(await certSignedBy(leaf, intermediateKey, intermediate.curve))) throw new AppleJwsError("leaf not signed by intermediate");
    if (leaf.curve !== "P-256") throw new AppleJwsError("unexpected leaf key");
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      await importCertKey(leaf),
      fromBase64Url(s),
      new TextEncoder().encode(`${h}.${p}`),
    );
    if (!ok) throw new AppleJwsError("bad signature");
  } catch (e) {
    if (e instanceof AppleJwsError) throw e;
    throw new AppleJwsError(e instanceof CertError ? e.message : "signature check failed");
  }
  return payload;
}

// ---- payload shapes (the fields this backend reads) ----

export type AppleEnvironment = "Production" | "Sandbox" | "Xcode" | "LocalTesting";

export interface JwsTransaction {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  purchaseDate?: number;
  expiresDate?: number;
  revocationDate?: number;
  appAccountToken?: string;
  environment: AppleEnvironment;
  signedDate: number;
  type?: string;
}

export interface JwsRenewalInfo {
  originalTransactionId: string;
  autoRenewProductId?: string;
  productId?: string;
  gracePeriodExpiresDate?: number;
  isInBillingRetryPeriod?: boolean;
  environment: AppleEnvironment;
  signedDate: number;
}

export interface NotificationV2 {
  notificationType: string;
  subtype?: string;
  notificationUUID: string;
  signedDate: number;
  data?: {
    bundleId?: string;
    environment?: AppleEnvironment;
    /// 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked.
    status?: number;
    signedTransactionInfo?: string;
    signedRenewalInfo?: string;
  };
}
