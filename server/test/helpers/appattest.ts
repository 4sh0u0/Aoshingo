// SPDX-License-Identifier: Apache-2.0

// Builds a fake App Attest PKI (root → intermediate → credential certificate) and attestation /
// assertion objects shaped like the ones DCAppAttestService produces.

import { concatBytes, randomBytes, sha256, utf8 } from "../../src/encoding";
import { encodeCbor } from "./cbor-encoder";
import {
  bitString,
  bool,
  ecdsaRawToDer,
  explicit,
  integer,
  octetString,
  oid,
  seq,
  set,
  time,
  utf8String,
} from "./der-builder";

const DAY = 86_400_000;
export const AAGUID_PRODUCTION = concatBytes(utf8("appattest"), new Uint8Array(7));
export const AAGUID_DEVELOPMENT = utf8("appattestdevelop");

type Curve = "P-256" | "P-384";
type Hash = "SHA-256" | "SHA-384";

export async function generateKeyPair(curve: Curve): Promise<CryptoKeyPair> {
  return (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: curve }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
}

async function exportSpki(key: CryptoKey): Promise<Uint8Array> {
  return new Uint8Array((await crypto.subtle.exportKey("spki", key)) as ArrayBuffer);
}

export async function exportRaw(key: CryptoKey): Promise<Uint8Array> {
  return new Uint8Array((await crypto.subtle.exportKey("raw", key)) as ArrayBuffer);
}

export function name(commonName: string): Uint8Array {
  return seq(set(seq(oid("2.5.4.3"), utf8String(commonName))));
}

export function extension(id: string, critical: boolean, value: Uint8Array): Uint8Array {
  return seq(oid(id), ...(critical ? [bool(true)] : []), octetString(value));
}

export interface CertificateOptions {
  serial?: number;
  issuer: Uint8Array;
  subject: Uint8Array;
  notBefore: number;
  notAfter: number;
  subjectPublicKey: CryptoKey;
  signingKey: CryptoKey;
  hash: Hash;
  /** Adds basicConstraints; undefined omits the extension. */
  isCA?: boolean;
  extensions?: Uint8Array[];
}

export async function makeCertificate(options: CertificateOptions): Promise<Uint8Array> {
  const algorithm = seq(oid(options.hash === "SHA-256" ? "1.2.840.10045.4.3.2" : "1.2.840.10045.4.3.3"));
  const extensions = [...(options.extensions ?? [])];
  if (options.isCA !== undefined) {
    extensions.unshift(extension("2.5.29.19", true, seq(...(options.isCA ? [bool(true)] : []))));
  }
  const tbs = seq(
    explicit(0, integer(2)),
    integer(options.serial ?? 1),
    algorithm,
    options.issuer,
    seq(time(options.notBefore), time(options.notAfter)),
    options.subject,
    await exportSpki(options.subjectPublicKey),
    ...(extensions.length > 0 ? [explicit(3, seq(...extensions))] : []),
  );
  const raw = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: options.hash }, options.signingKey, tbs),
  );
  return seq(tbs, algorithm, bitString(ecdsaRawToDer(raw)));
}

export interface FakePki {
  root: CryptoKeyPair;
  rootDer: Uint8Array;
  rootName: Uint8Array;
  intermediate: CryptoKeyPair;
  intermediateDer: Uint8Array;
  intermediateName: Uint8Array;
}

/** A P-384 root and intermediate, like Apple's. */
export async function createFakePki(nowMs: number = Date.now()): Promise<FakePki> {
  const root = await generateKeyPair("P-384");
  const rootName = name("Fake App Attestation Root CA");
  const rootDer = await makeCertificate({
    issuer: rootName,
    subject: rootName,
    notBefore: nowMs - 365 * DAY,
    notAfter: nowMs + 3650 * DAY,
    subjectPublicKey: root.publicKey,
    signingKey: root.privateKey,
    hash: "SHA-384",
    isCA: true,
  });
  const intermediate = await generateKeyPair("P-384");
  const intermediateName = name("Fake App Attestation CA 1");
  const intermediateDer = await makeCertificate({
    serial: 2,
    issuer: rootName,
    subject: intermediateName,
    notBefore: nowMs - 30 * DAY,
    notAfter: nowMs + 365 * DAY,
    subjectPublicKey: intermediate.publicKey,
    signingKey: root.privateKey,
    hash: "SHA-384",
    isCA: true,
  });
  return { root, rootDer, rootName, intermediate, intermediateDer, intermediateName };
}

export const NONCE_OID = "1.2.840.113635.100.8.2";

export function nonceExtension(nonce: Uint8Array): Uint8Array {
  return extension(NONCE_OID, false, seq(explicit(1, octetString(nonce))));
}

export interface AttestationOptions {
  pki: FakePki;
  challenge: string;
  appId: string;
  aaguid?: Uint8Array;
  counter?: number;
  /** Defaults to the real keyId. */
  credentialId?: Uint8Array;
  /** Replaces the computed nonce in the certificate extension. */
  nonce?: Uint8Array;
  omitNonceExtension?: boolean;
  leafNotBefore?: number;
  leafNotAfter?: number;
  /** Signs the credential certificate with another key instead of the intermediate's. */
  leafSigningKey?: CryptoKey;
  /** Replaces attStmt.x5c; receives [credCert, intermediate]. */
  x5c?: (certificates: [Uint8Array, Uint8Array]) => Uint8Array[];
  fmt?: string;
  nowMs?: number;
  /** Re-attests an existing credential key instead of generating a new one. */
  credentialKey?: CryptoKeyPair;
}

export interface BuiltAttestation {
  attestation: Uint8Array;
  keyId: Uint8Array;
  credentialKey: CryptoKeyPair;
  publicKey: Uint8Array;
  authData: Uint8Array;
}

export function buildAuthData(options: {
  appIdHash: Uint8Array;
  counter: number;
  aaguid?: Uint8Array;
  credentialId?: Uint8Array;
}): Uint8Array {
  const counter = new Uint8Array(4);
  new DataView(counter.buffer).setUint32(0, options.counter);
  const parts = [options.appIdHash, Uint8Array.of(options.aaguid ? 0x40 : 0x00), counter];
  if (options.aaguid && options.credentialId) {
    const length = Uint8Array.of(options.credentialId.byteLength >> 8, options.credentialId.byteLength & 0xff);
    // A stand-in for the COSE public key that follows the credential ID.
    parts.push(options.aaguid, length, options.credentialId, encodeCbor({ "1": 2, "3": -7 }));
  }
  return concatBytes(...parts);
}

export async function buildAttestation(options: AttestationOptions): Promise<BuiltAttestation> {
  const nowMs = options.nowMs ?? Date.now();
  const credentialKey = options.credentialKey ?? (await generateKeyPair("P-256"));
  const publicKey = await exportRaw(credentialKey.publicKey);
  const keyId = await sha256(publicKey);
  const authData = buildAuthData({
    appIdHash: await sha256(utf8(options.appId)),
    counter: options.counter ?? 0,
    aaguid: options.aaguid ?? AAGUID_PRODUCTION,
    credentialId: options.credentialId ?? keyId,
  });
  const nonce = options.nonce ?? (await sha256(authData, await sha256(utf8(options.challenge))));
  const credCert = await makeCertificate({
    serial: 3,
    issuer: options.pki.intermediateName,
    subject: name("fake credential"),
    notBefore: options.leafNotBefore ?? nowMs - DAY,
    notAfter: options.leafNotAfter ?? nowMs + 30 * DAY,
    subjectPublicKey: credentialKey.publicKey,
    signingKey: options.leafSigningKey ?? options.pki.intermediate.privateKey,
    hash: "SHA-256",
    extensions: options.omitNonceExtension ? [] : [nonceExtension(nonce)],
  });
  const certificates: [Uint8Array, Uint8Array] = [credCert, options.pki.intermediateDer];
  const attestation = encodeCbor({
    fmt: options.fmt ?? "apple-appattest",
    attStmt: { x5c: options.x5c ? options.x5c(certificates) : certificates, receipt: randomBytes(64) },
    authData,
  });
  return { attestation, keyId, credentialKey, publicKey, authData };
}

export interface AssertionOptions {
  privateKey: CryptoKey;
  challenge: string;
  appId: string;
  counter: number;
}

export async function buildAssertion(options: AssertionOptions): Promise<Uint8Array> {
  const authenticatorData = buildAuthData({
    appIdHash: await sha256(utf8(options.appId)),
    counter: options.counter,
  });
  const nonce = await sha256(authenticatorData, await sha256(utf8(options.challenge)));
  const raw = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, options.privateKey, nonce),
  );
  return encodeCbor({ signature: ecdsaRawToDer(raw), authenticatorData });
}
