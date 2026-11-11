// SPDX-License-Identifier: Apache-2.0

// Just enough X.509 (RFC 5280) to validate an App Attest certificate chain: ECDSA P-256/P-384
// keys and ecdsa-with-SHA256/SHA384 signatures, checked with WebCrypto.

import {
  bitStringBytes,
  children,
  contextTag,
  decodeBoolean,
  decodeOid,
  decodeTime,
  DerError,
  ecdsaDerToRaw,
  expectTag,
  parseDer,
  TAG,
  type DerNode,
} from "./der";
import { bytesEqual } from "./encoding";

const OID_EC_PUBLIC_KEY = "1.2.840.10045.2.1";
const OID_BASIC_CONSTRAINTS = "2.5.29.19";

const CURVES: Record<string, { name: "P-256" | "P-384"; size: number; pointLength: number }> = {
  "1.2.840.10045.3.1.7": { name: "P-256", size: 32, pointLength: 65 },
  "1.3.132.0.34": { name: "P-384", size: 48, pointLength: 97 },
};

const SIGNATURE_HASHES: Record<string, "SHA-256" | "SHA-384"> = {
  "1.2.840.10045.4.3.2": "SHA-256",
  "1.2.840.10045.4.3.3": "SHA-384",
};

export class CertificateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CertificateError";
  }
}

export interface Extension {
  readonly critical: boolean;
  /** Contents of the extnValue OCTET STRING. */
  readonly value: Uint8Array;
}

export interface Certificate {
  readonly raw: Uint8Array;
  /** The exact signed bytes of tbsCertificate. */
  readonly tbs: Uint8Array;
  readonly signatureHash: "SHA-256" | "SHA-384";
  /** DER ECDSA-Sig-Value. */
  readonly signature: Uint8Array;
  /** DER-encoded issuer and subject Names, compared byte for byte. */
  readonly issuer: Uint8Array;
  readonly subject: Uint8Array;
  readonly notBefore: number;
  readonly notAfter: number;
  /** DER SubjectPublicKeyInfo, importable with WebCrypto `spki`. */
  readonly spki: Uint8Array;
  readonly curve: "P-256" | "P-384";
  readonly curveSize: number;
  /** subjectPublicKey: the uncompressed X9.62 point. */
  readonly publicKey: Uint8Array;
  readonly extensions: ReadonlyMap<string, Extension>;
  /** basicConstraints cA, or false when the extension is absent. */
  readonly isCA: boolean;
}

function parseAlgorithmOid(node: DerNode): string {
  const parts = children(expectTag(node, TAG.SEQUENCE));
  return decodeOid(expectTag(parts[0], TAG.OID));
}

function parseExtensions(node: DerNode): Map<string, Extension> {
  const sequence = expectTag(parseDer(node.content), TAG.SEQUENCE);
  const extensions = new Map<string, Extension>();
  for (const entry of children(sequence)) {
    const parts = children(expectTag(entry, TAG.SEQUENCE));
    const oid = decodeOid(expectTag(parts[0], TAG.OID));
    let index = 1;
    let critical = false;
    if (parts[index]?.tag === TAG.BOOLEAN) {
      critical = decodeBoolean(parts[index]!);
      index++;
    }
    const value = expectTag(parts[index], TAG.OCTET_STRING).content;
    if (index + 1 !== parts.length) throw new CertificateError("malformed extension");
    if (extensions.has(oid)) throw new CertificateError("duplicate extension");
    extensions.set(oid, { critical, value });
  }
  return extensions;
}

function parseBasicConstraintsCA(extension: Extension | undefined): boolean {
  if (extension === undefined) return false;
  const parts = children(expectTag(parseDer(extension.value), TAG.SEQUENCE));
  return parts[0]?.tag === TAG.BOOLEAN ? decodeBoolean(parts[0]) : false;
}

export function parseCertificate(der: Uint8Array): Certificate {
  try {
    const certificate = expectTag(parseDer(der), TAG.SEQUENCE);
    const [tbsNode, outerAlgorithm, signatureNode, ...rest] = children(certificate);
    if (rest.length !== 0) throw new CertificateError("unexpected certificate fields");
    const tbs = expectTag(tbsNode, TAG.SEQUENCE);
    const fields = children(tbs);

    let index = 0;
    const version = expectTag(fields[index++], contextTag(0));
    const versionValue = expectTag(parseDer(version.content), TAG.INTEGER).content;
    if (versionValue.byteLength !== 1 || versionValue[0] !== 2) {
      throw new CertificateError("only X.509 v3 certificates are supported");
    }
    expectTag(fields[index++], TAG.INTEGER); // serialNumber
    const innerAlgorithm = parseAlgorithmOid(fields[index++]!);
    const issuer = expectTag(fields[index++], TAG.SEQUENCE);
    const validity = children(expectTag(fields[index++], TAG.SEQUENCE));
    if (validity.length !== 2) throw new CertificateError("malformed validity");
    const subject = expectTag(fields[index++], TAG.SEQUENCE);
    const spki = expectTag(fields[index++], TAG.SEQUENCE);

    let extensions = new Map<string, Extension>();
    for (; index < fields.length; index++) {
      const field = fields[index]!;
      // issuerUniqueID [1] and subjectUniqueID [2] are ignored; extensions are [3].
      if (field.tag === contextTag(3)) extensions = parseExtensions(field);
    }

    const outerOid = parseAlgorithmOid(outerAlgorithm!);
    if (outerOid !== innerAlgorithm) throw new CertificateError("signature algorithm mismatch");
    const signatureHash = SIGNATURE_HASHES[outerOid];
    if (signatureHash === undefined) throw new CertificateError("unsupported signature algorithm");

    const [spkiAlgorithm, spkiKey] = children(spki);
    const algorithmParts = children(expectTag(spkiAlgorithm, TAG.SEQUENCE));
    if (decodeOid(expectTag(algorithmParts[0], TAG.OID)) !== OID_EC_PUBLIC_KEY) {
      throw new CertificateError("unsupported public key algorithm");
    }
    const curve = CURVES[decodeOid(expectTag(algorithmParts[1], TAG.OID))];
    if (curve === undefined) throw new CertificateError("unsupported curve");
    const publicKey = bitStringBytes(spkiKey!);
    if (publicKey.byteLength !== curve.pointLength || publicKey[0] !== 0x04) {
      throw new CertificateError("public key is not an uncompressed point");
    }

    return {
      raw: der,
      tbs: tbs.raw,
      signatureHash,
      signature: bitStringBytes(signatureNode!),
      issuer: issuer.raw,
      subject: subject.raw,
      notBefore: decodeTime(validity[0]!),
      notAfter: decodeTime(validity[1]!),
      spki: spki.raw,
      curve: curve.name,
      curveSize: curve.size,
      publicKey,
      extensions,
      isCA: parseBasicConstraintsCA(extensions.get(OID_BASIC_CONSTRAINTS)),
    };
  } catch (error) {
    if (error instanceof DerError) throw new CertificateError(`malformed certificate: ${error.message}`);
    throw error;
  }
}

async function importPublicKey(certificate: Certificate): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "spki",
    certificate.spki,
    { name: "ECDSA", namedCurve: certificate.curve },
    false,
    ["verify"],
  );
}

/** Verifies that `child` was signed by `issuer`'s key. */
export async function verifySignedBy(child: Certificate, issuer: Certificate): Promise<boolean> {
  try {
    const signature = ecdsaDerToRaw(child.signature, issuer.curveSize);
    const key = await importPublicKey(issuer);
    return await crypto.subtle.verify({ name: "ECDSA", hash: child.signatureHash }, key, signature, child.tbs);
  } catch {
    // Malformed signature or a public key WebCrypto rejects (e.g. a point not on the curve).
    return false;
  }
}

function isValidAt(certificate: Certificate, nowMs: number): boolean {
  return certificate.notBefore <= nowMs && nowMs <= certificate.notAfter;
}

/**
 * Validates `leaf → intermediate → trustedRoot`. The root is trusted because its exact DER is
 * pinned by the caller; it is not taken from the attestation. Throws CertificateError on failure.
 */
export async function verifyChain(
  leafDer: Uint8Array,
  intermediateDer: Uint8Array,
  trustedRootDer: Uint8Array,
  nowMs: number,
): Promise<Certificate> {
  const leaf = parseCertificate(leafDer);
  const intermediate = parseCertificate(intermediateDer);
  const root = parseCertificate(trustedRootDer);

  for (const certificate of [leaf, intermediate, root]) {
    if (!isValidAt(certificate, nowMs)) throw new CertificateError("certificate not valid at this time");
  }
  if (!root.isCA || !intermediate.isCA) throw new CertificateError("issuer is not a CA");
  if (!bytesEqual(leaf.issuer, intermediate.subject) || !bytesEqual(intermediate.issuer, root.subject)) {
    throw new CertificateError("issuer name mismatch");
  }
  if (!(await verifySignedBy(intermediate, root))) {
    throw new CertificateError("intermediate signature invalid");
  }
  if (!(await verifySignedBy(leaf, intermediate))) {
    throw new CertificateError("leaf signature invalid");
  }
  return leaf;
}

export function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN CERTIFICATE-----/, "")
    .replace(/-----END CERTIFICATE-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}
