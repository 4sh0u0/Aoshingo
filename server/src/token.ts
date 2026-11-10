// SPDX-License-Identifier: Apache-2.0

// Stateless upload tokens. Layout (58 bytes, sent as base64url without padding):
//   [0]      version (1)
//   [1]      App Attest environment (0 = production, 1 = development)
//   [2..18)  random token ID (16 bytes); never derived from the App Attest keyId
//   [18..26) expiry, Unix seconds, unsigned 64-bit big-endian
//   [26..58) HMAC-SHA256(TOKEN_SECRET, bytes [0..26))

import type { AttestEnvironment } from "./appattest";
import { concatBytes, decodeBase64Url, encodeBase64Url, randomBytes } from "./encoding";

const VERSION = 1;
const ID_LENGTH = 16;
const PAYLOAD_LENGTH = 2 + ID_LENGTH + 8;
const MAC_LENGTH = 32;
const TOKEN_LENGTH = PAYLOAD_LENGTH + MAC_LENGTH;
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{78}$/;

export interface TokenClaims {
  /** Random token ID, used only as the rate-limit key. */
  id: Uint8Array;
  expiresAt: number;
  environment: AttestEnvironment;
}

let cachedKey: { secret: string; key: Promise<CryptoKey> } | undefined;

function hmacKey(secret: string): Promise<CryptoKey> {
  if (cachedKey?.secret !== secret) {
    const key = crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    cachedKey = { secret, key };
  }
  return cachedKey.key;
}

async function mac(secret: string, payload: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(secret), payload));
}

function encodePayload(claims: TokenClaims): Uint8Array {
  const payload = new Uint8Array(PAYLOAD_LENGTH);
  payload[0] = VERSION;
  payload[1] = claims.environment === "development" ? 1 : 0;
  payload.set(claims.id, 2);
  new DataView(payload.buffer).setBigUint64(2 + ID_LENGTH, BigInt(claims.expiresAt));
  return payload;
}

/** Signs explicit claims. Exposed for tests; request handlers use `issueToken`. */
export async function signToken(secret: string, claims: TokenClaims): Promise<string> {
  const payload = encodePayload(claims);
  return encodeBase64Url(concatBytes(payload, await mac(secret, payload)));
}

export async function issueToken(
  secret: string,
  environment: AttestEnvironment,
  ttlSeconds: number,
  nowSeconds: number,
): Promise<{ token: string; expiresAt: number }> {
  const expiresAt = nowSeconds + ttlSeconds;
  const token = await signToken(secret, { id: randomBytes(ID_LENGTH), expiresAt, environment });
  return { token, expiresAt };
}

/** Returns the claims of a valid, unexpired token, or null. */
export async function verifyToken(
  secret: string,
  token: string,
  nowSeconds: number,
): Promise<TokenClaims | null> {
  if (!TOKEN_PATTERN.test(token)) return null;
  const bytes = decodeBase64Url(token);
  if (bytes === null || bytes.byteLength !== TOKEN_LENGTH) return null;
  const payload = bytes.subarray(0, PAYLOAD_LENGTH);
  const expected = await mac(secret, payload);
  // Constant-time comparison (workerd extension to SubtleCrypto); both inputs are 32 bytes.
  if (!crypto.subtle.timingSafeEqual(expected, bytes.subarray(PAYLOAD_LENGTH))) return null;
  if (payload[0] !== VERSION) return null;
  const environmentByte = payload[1];
  if (environmentByte !== 0 && environmentByte !== 1) return null;
  const expiresAt = Number(new DataView(payload.buffer, payload.byteOffset).getBigUint64(2 + ID_LENGTH));
  if (expiresAt <= nowSeconds) return null;
  return {
    id: payload.slice(2, 2 + ID_LENGTH),
    expiresAt,
    environment: environmentByte === 1 ? "development" : "production",
  };
}
