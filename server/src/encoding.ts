// SPDX-License-Identifier: Apache-2.0

// Byte and text encoding helpers. All decoders are strict and return null on malformed input.

const encoder = new TextEncoder();

export function utf8(text: string): Uint8Array {
  return encoder.encode(text);
}

export function concatBytes(...parts: Uint8Array[]): Uint8Array {
  let length = 0;
  for (const part of parts) length += part.byteLength;
  const out = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.byteLength;
  }
  return out;
}

/** Plain (not constant-time) equality, for values that are not secret. */
export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.byteLength !== b.byteLength) return false;
  for (let i = 0; i < a.byteLength; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

const HEX = "0123456789abcdef";

export function toHex(bytes: Uint8Array): string {
  let out = "";
  for (const byte of bytes) out += HEX[byte >> 4]! + HEX[byte & 0x0f]!;
  return out;
}

export function fromHex(text: string): Uint8Array | null {
  if (text.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(text)) return null;
  const out = new Uint8Array(text.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(text.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function binaryToBytes(binary: string): Uint8Array {
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function bytesToBinary(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return binary;
}

const BASE64_PADDED = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const BASE64URL_UNPADDED = /^[A-Za-z0-9_-]*$/;

/** Standard base64 with padding, as produced by `Data.base64EncodedString()`. */
export function decodeBase64(text: string): Uint8Array | null {
  if (!BASE64_PADDED.test(text)) return null;
  try {
    return binaryToBytes(atob(text));
  } catch {
    return null;
  }
}

export function encodeBase64(bytes: Uint8Array): string {
  return btoa(bytesToBinary(bytes));
}

/** base64url without padding. */
export function decodeBase64Url(text: string): Uint8Array | null {
  if (!BASE64URL_UNPADDED.test(text) || text.length % 4 === 1) return null;
  const standard = text.replaceAll("-", "+").replaceAll("_", "/");
  const padded = standard + "=".repeat((4 - (standard.length % 4)) % 4);
  try {
    return binaryToBytes(atob(padded));
  } catch {
    return null;
  }
}

export function encodeBase64Url(bytes: Uint8Array): string {
  return encodeBase64(bytes).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export async function sha256(...parts: Uint8Array[]): Promise<Uint8Array> {
  const data = parts.length === 1 ? parts[0]! : concatBytes(...parts);
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data));
}

export function randomBytes(length: number): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(length));
}
