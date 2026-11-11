// SPDX-License-Identifier: Apache-2.0

// App Attest attestation and assertion verification, following Apple's "Validating apps that
// connect to your server" as summarised in docs/field-data-api.md.

import { decodeCbor, isBytes, isCborMap, type CborValue } from "./cbor";
import { children, contextTag, ecdsaDerToRaw, expectTag, parseDer, TAG } from "./der";
import { bytesEqual, sha256, utf8 } from "./encoding";
import { CertificateError, verifyChain } from "./x509";

export type AttestEnvironment = "production" | "development";

const NONCE_EXTENSION_OID = "1.2.840.113635.100.8.2";

// "appattest" followed by seven 0x00 bytes, and "appattestdevelop".
const AAGUID_PRODUCTION = new Uint8Array([
  0x61, 0x70, 0x70, 0x61, 0x74, 0x74, 0x65, 0x73, 0x74, 0, 0, 0, 0, 0, 0, 0,
]);
const AAGUID_DEVELOPMENT = utf8("appattestdevelop");

/** Thrown with a machine-readable reason; the HTTP layer maps every reason to one error code. */
export class VerificationError extends Error {
  constructor(readonly reason: string) {
    super(reason);
    this.name = "VerificationError";
  }
}

function fail(reason: string): never {
  throw new VerificationError(reason);
}

function decodeMap(bytes: Uint8Array): Map<string | number, CborValue> {
  let value: CborValue;
  try {
    value = decodeCbor(bytes);
  } catch {
    fail("cbor_malformed");
  }
  if (!isCborMap(value)) fail("cbor_not_map");
  return value;
}

/** `clientDataHash` = SHA-256 of the challenge string exactly as issued. */
export function clientDataHash(challenge: string): Promise<Uint8Array> {
  return sha256(utf8(challenge));
}

/** `appId` is "<APPLE_TEAM_ID>.<APP_BUNDLE_ID>". */
export function rpIdHash(appId: string): Promise<Uint8Array> {
  return sha256(utf8(appId));
}

function readCounter(authData: Uint8Array): number {
  return new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0);
}

/** Extracts the nonce from `SEQUENCE { [1] EXPLICIT OCTET STRING }`. */
function extractNonce(extensionValue: Uint8Array): Uint8Array {
  try {
    const sequence = expectTag(parseDer(extensionValue), TAG.SEQUENCE);
    const tagged = children(sequence).find((child) => child.tag === contextTag(1));
    if (tagged === undefined) fail("nonce_extension_malformed");
    return expectTag(parseDer(tagged.content), TAG.OCTET_STRING).content;
  } catch (error) {
    if (error instanceof VerificationError) throw error;
    fail("nonce_extension_malformed");
  }
}

export interface AttestationInput {
  attestation: Uint8Array;
  /** Decoded keyId (32 bytes). */
  keyId: Uint8Array;
  challenge: string;
  appId: string;
  allowDevelopment: boolean;
  nowMs: number;
  /** DER of the trusted root; production callers pass the pinned Apple root. */
  trustedRoot: Uint8Array;
}

export interface AttestationResult {
  /** The credential public key as an uncompressed X9.62 point (65 bytes). */
  publicKey: Uint8Array;
  environment: AttestEnvironment;
}

export async function verifyAttestation(input: AttestationInput): Promise<AttestationResult> {
  // 1. Decode the attestation object.
  const object = decodeMap(input.attestation);
  if (object.get("fmt") !== "apple-appattest") fail("bad_format");
  const statement = object.get("attStmt");
  const authData = object.get("authData");
  if (!isCborMap(statement) || !isBytes(authData)) fail("bad_structure");
  const x5c = statement.get("x5c");
  if (!Array.isArray(x5c) || x5c.length !== 2 || !x5c.every(isBytes)) fail("bad_x5c");
  const [credCertDer, intermediateDer] = x5c as [Uint8Array, Uint8Array];

  // 2. Validate the certificate chain against the pinned root.
  let credCert;
  try {
    credCert = await verifyChain(credCertDer, intermediateDer, input.trustedRoot, input.nowMs);
  } catch (error) {
    if (error instanceof CertificateError) fail("bad_chain");
    throw error;
  }

  // 3. nonce = SHA-256(authData || clientDataHash) must match the credCert extension.
  const extension = credCert.extensions.get(NONCE_EXTENSION_OID);
  if (extension === undefined) fail("nonce_extension_missing");
  const nonce = await sha256(authData, await clientDataHash(input.challenge));
  if (!bytesEqual(extractNonce(extension.value), nonce)) fail("nonce_mismatch");

  // 4. SHA-256 of the credCert public key must equal keyId.
  if (credCert.curve !== "P-256") fail("bad_key_type");
  if (!bytesEqual(await sha256(credCert.publicKey), input.keyId)) fail("key_id_mismatch");

  // authData: rpIdHash(32) flags(1) signCount(4) aaguid(16) credentialIdLength(2) credentialId(n) ...
  if (authData.byteLength < 55) fail("auth_data_too_short");

  // 5. rpIdHash.
  if (!bytesEqual(authData.subarray(0, 32), await rpIdHash(input.appId))) fail("rp_id_mismatch");

  // 6. The sign count of a fresh key is 0.
  if (readCounter(authData) !== 0) fail("counter_not_zero");

  // 7. AAGUID selects the App Attest environment.
  const aaguid = authData.subarray(37, 53);
  let environment: AttestEnvironment;
  if (bytesEqual(aaguid, AAGUID_PRODUCTION)) {
    environment = "production";
  } else if (bytesEqual(aaguid, AAGUID_DEVELOPMENT)) {
    if (!input.allowDevelopment) fail("development_not_allowed");
    environment = "development";
  } else {
    fail("bad_aaguid");
  }

  // 8. The credential ID must equal keyId.
  const credentialIdLength = (authData[53]! << 8) | authData[54]!;
  if (authData.byteLength < 55 + credentialIdLength) fail("auth_data_too_short");
  if (!bytesEqual(authData.subarray(55, 55 + credentialIdLength), input.keyId)) {
    fail("credential_id_mismatch");
  }

  return { publicKey: credCert.publicKey, environment };
}

export interface AssertionInput {
  assertion: Uint8Array;
  /** Stored uncompressed P-256 point. */
  publicKey: Uint8Array;
  storedSignCount: number;
  challenge: string;
  appId: string;
}

/** Returns the new sign count, which the caller must store. */
export async function verifyAssertion(input: AssertionInput): Promise<number> {
  const object = decodeMap(input.assertion);
  const signature = object.get("signature");
  const authenticatorData = object.get("authenticatorData");
  if (!isBytes(signature) || !isBytes(authenticatorData)) fail("bad_structure");
  if (authenticatorData.byteLength < 37) fail("auth_data_too_short");

  // nonce = SHA-256(authenticatorData || clientDataHash); the signature is ECDSA-SHA256 over nonce.
  const nonce = await sha256(authenticatorData, await clientDataHash(input.challenge));
  let rawSignature: Uint8Array;
  try {
    rawSignature = ecdsaDerToRaw(signature, 32);
  } catch {
    fail("bad_signature_encoding");
  }
  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey(
      "raw",
      input.publicKey,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
  } catch {
    fail("bad_stored_key");
  }
  let valid = false;
  try {
    valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, rawSignature, nonce);
  } catch {
    // Treated like any other invalid signature.
  }
  if (!valid) fail("bad_signature");

  if (!bytesEqual(authenticatorData.subarray(0, 32), await rpIdHash(input.appId))) fail("rp_id_mismatch");

  const counter = readCounter(authenticatorData);
  if (counter <= input.storedSignCount) fail("counter_not_increasing");
  return counter;
}
