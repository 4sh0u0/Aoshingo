// SPDX-License-Identifier: Apache-2.0

// D1 access for registered App Attest keys (attest_keys). Kept apart from report data: no report
// row references a key, and only coarse UTC days are stored.
//
// A key that has not been used for KEY_RETENTION_DAYS is deleted by the daily cron. Its app then
// gets 404 unknown_key from /v1/token and attests a new key, as it does for any unknown key.

import type { AttestEnvironment } from "./appattest";
import type { WriteCost } from "./budget";

/** Keys whose last use (attestation or token refresh) is this many days old are deleted. */
export const KEY_RETENTION_DAYS = 30;

/** At most this many keys are deleted per cron run (one row written each). */
export const KEY_DELETE_LIMIT = 10_000;

/**
 * Registering a key writes one row (the table has no secondary index). A row takes about 260 bytes
 * (measured locally), counted as 300.
 */
export const KEY_WRITE_COST: WriteCost = { rows: 1, storedBytes: 300 };

/** A token refresh updates the key's row in place: one row, nothing new stored. */
export const KEY_REFRESH_COST: WriteCost = { rows: 1, storedBytes: 0 };

export interface StoredKey {
  public_key: string;
  sign_count: number;
  environment: AttestEnvironment;
}

/** Stores a new key with counter 0; false when the keyId is already registered. */
export async function insertKey(
  db: D1Database,
  keyIdHex: string,
  publicKeyHex: string,
  environment: AttestEnvironment,
  day: string,
): Promise<boolean> {
  const inserted = await db
    .prepare(
      `INSERT INTO attest_keys (key_id, public_key, sign_count, environment, created_day, last_used_day)
       VALUES (?1, ?2, 0, ?3, ?4, ?4) ON CONFLICT (key_id) DO NOTHING`,
    )
    .bind(keyIdHex, publicKeyHex, environment, day)
    .run();
  return inserted.meta.changes === 1;
}

export async function findKey(db: D1Database, keyIdHex: string): Promise<StoredKey | null> {
  return db
    .prepare("SELECT public_key, sign_count, environment FROM attest_keys WHERE key_id = ?1")
    .bind(keyIdHex)
    .first<StoredKey>();
}

/**
 * Compare-and-set of the signature counter, so two concurrent requests cannot both use the same
 * value. Records the day of use in the same row update, so it costs nothing extra. False when the
 * stored counter is already at or above `counter` (or the key is gone).
 */
export async function updateCounter(db: D1Database, keyIdHex: string, counter: number, day: string): Promise<boolean> {
  const updated = await db
    .prepare("UPDATE attest_keys SET sign_count = ?1, last_used_day = ?3 WHERE key_id = ?2 AND sign_count < ?1")
    .bind(counter, keyIdHex, day)
    .run();
  return updated.meta.changes === 1;
}

/**
 * Deletes up to `limit` keys last used before `cutoffDay` (YYYY-MM-DD, UTC). One query; it scans
 * the table, which has no index on last_used_day so that refreshes stay at one row written.
 */
export async function deleteUnusedKeys(db: D1Database, cutoffDay: string, limit = KEY_DELETE_LIMIT): Promise<D1Result> {
  return db
    .prepare(
      `DELETE FROM attest_keys
        WHERE key_id IN (SELECT key_id FROM attest_keys WHERE last_used_day < ?1 LIMIT ?2)`,
    )
    .bind(cutoffDay, limit)
    .run();
}
