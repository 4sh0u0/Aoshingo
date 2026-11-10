// SPDX-License-Identifier: Apache-2.0

// Stateless App Attest challenges with a 300-second lifetime. Nothing is stored: a challenge is
// signed with TOKEN_SECRET, so issuing one costs no D1 write. Layout (57 bytes, base64url without
// padding, 76 characters):
//   [0]      version (1)
//   [1..17)  random nonce (16 bytes)
//   [17..25) expiry, Unix seconds, unsigned 64-bit big-endian
//   [25..57) HMAC-SHA256(TOKEN_SECRET, LABEL ‖ bytes [0..25))
//
// A challenge is not single-use. Replays are stopped where the data is: /v1/attest stores each
// key once (a second attestation for the same keyId is 409 key_exists), and /v1/token accepts an
// assertion only when its counter is higher than the stored one. Both are bound to the challenge
// through clientDataHash, so a challenge only proves that the request is recent.

import { concatBytes, decodeBase64Url, encodeBase64Url, randomBytes } from "./encoding";
import { hmacSha256 } from "./token";

export const CHALLENGE_TTL_SECONDS = 300;

const VERSION = 1;
const NONCE_LENGTH = 16;
const PAYLOAD_LENGTH = 1 + NONCE_LENGTH + 8;
const MAC_LENGTH = 32;
const CHALLENGE_LENGTH = PAYLOAD_LENGTH + MAC_LENGTH;
const CHALLENGE_PATTERN = /^[A-Za-z0-9_-]{76}$/;
// Domain separation, so an upload token's MAC can never pass as a challenge's, or the reverse.
const LABEL = new TextEncoder().encode("aoshingo/challenge/v1\0");

function sign(secret: string, payload: Uint8Array): Promise<Uint8Array> {
  return hmacSha256(secret, concatBytes(LABEL, payload));
}

export async function issueChallenge(
  secret: string,
  nowSeconds: number,
): Promise<{ challenge: string; expiresAt: number }> {
  const expiresAt = nowSeconds + CHALLENGE_TTL_SECONDS;
  const payload = new Uint8Array(PAYLOAD_LENGTH);
  payload[0] = VERSION;
  payload.set(randomBytes(NONCE_LENGTH), 1);
  new DataView(payload.buffer).setBigUint64(1 + NONCE_LENGTH, BigInt(expiresAt));
  const challenge = encodeBase64Url(concatBytes(payload, await sign(secret, payload)));
  return { challenge, expiresAt };
}

/** True when `challenge` was issued with `secret` and has not expired. */
export async function verifyChallenge(secret: string, challenge: unknown, nowSeconds: number): Promise<boolean> {
  if (typeof challenge !== "string" || !CHALLENGE_PATTERN.test(challenge)) return false;
  const bytes = decodeBase64Url(challenge);
  if (bytes === null || bytes.byteLength !== CHALLENGE_LENGTH) return false;
  const payload = bytes.subarray(0, PAYLOAD_LENGTH);
  const expected = await sign(secret, payload);
  // Constant-time comparison (workerd extension to SubtleCrypto); both inputs are 32 bytes.
  if (!crypto.subtle.timingSafeEqual(expected, bytes.subarray(PAYLOAD_LENGTH))) return false;
  if (payload[0] !== VERSION) return false;
  const expiresAt = Number(new DataView(payload.buffer, payload.byteOffset).getBigUint64(1 + NONCE_LENGTH));
  return expiresAt > nowSeconds;
}
