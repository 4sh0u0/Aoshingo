// SPDX-License-Identifier: Apache-2.0

// Single-use App Attest challenges, stored in D1 with a 300-second lifetime.

import { encodeBase64Url, randomBytes } from "./encoding";

export const CHALLENGE_TTL_SECONDS = 300;
const CHALLENGE_PATTERN = /^[A-Za-z0-9_-]{43}$/;

export async function issueChallenge(
  db: D1Database,
  nowSeconds: number,
): Promise<{ challenge: string; expiresAt: number }> {
  const challenge = encodeBase64Url(randomBytes(32));
  const expiresAt = nowSeconds + CHALLENGE_TTL_SECONDS;
  await db
    .prepare("INSERT INTO challenges (challenge, expires_at) VALUES (?1, ?2)")
    .bind(challenge, expiresAt)
    .run();
  return { challenge, expiresAt };
}

/**
 * Atomically deletes the challenge and reports whether it was valid. A challenge can be consumed
 * at most once, whether or not the request that presented it succeeds.
 */
export async function consumeChallenge(db: D1Database, challenge: unknown, nowSeconds: number): Promise<boolean> {
  if (typeof challenge !== "string" || !CHALLENGE_PATTERN.test(challenge)) return false;
  const row = await db
    .prepare("DELETE FROM challenges WHERE challenge = ?1 RETURNING expires_at")
    .bind(challenge)
    .first<{ expires_at: number }>();
  return row !== null && row.expires_at > nowSeconds;
}

export async function deleteExpiredChallenges(db: D1Database, nowSeconds: number): Promise<void> {
  await db.prepare("DELETE FROM challenges WHERE expires_at <= ?1").bind(nowSeconds).run();
}
