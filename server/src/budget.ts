// SPDX-License-Identifier: Apache-2.0

// A daily budget for the D1 writes that requests cause, so that no client (even one with a genuine
// device and valid tokens) can use up the account's daily D1 write quota or fill the database.
// The Workers Free plan allows 100,000 rows written per day for the whole account, a 500 MB
// database and 50 D1 queries per invocation; the defaults in cloudflare.config.ts stay well below.
//
// Every write path reserves its rows (and payload bytes) first, in the same UTC day that D1's
// limits use. The reservation is one conditional upsert, so concurrent requests cannot overshoot.
// The table holds only the day and two counters.

import { HttpError } from "./http";

export interface BudgetLimits {
  /** Rows written per UTC day by API requests, including indexes and this table. */
  rowsPerDay: number;
  /** Report payload bytes stored per UTC day. */
  payloadBytesPerDay: number;
  /** Refuse new writes once the database is this large (D1 reports its size after each query). */
  maxDatabaseBytes: number;
}

/** Each reservation updates its own daily_usage row once. */
export const BUDGET_ROW_COST = 1;

const RESERVE_SQL = `
INSERT INTO daily_usage (day, rows_written, payload_bytes) VALUES (?1, ?2, ?3)
    ON CONFLICT (day) DO UPDATE
   SET rows_written = rows_written + excluded.rows_written,
       payload_bytes = payload_bytes + excluded.payload_bytes
 WHERE rows_written + excluded.rows_written <= ?4
   AND payload_bytes + excluded.payload_bytes <= ?5
RETURNING rows_written`;

/**
 * Reserves `rows` written rows and `payloadBytes` bytes for `day` (YYYY-MM-DD, UTC), or throws
 * 503 over_capacity. `rows` must already include the indexes the caller writes.
 */
export async function reserveWrites(
  db: D1Database,
  limits: BudgetLimits,
  day: string,
  rows: number,
  payloadBytes = 0,
): Promise<void> {
  const total = rows + BUDGET_ROW_COST;
  if (total > limits.rowsPerDay || payloadBytes > limits.payloadBytesPerDay) {
    throw new HttpError(503, "over_capacity");
  }
  const result = await db
    .prepare(RESERVE_SQL)
    .bind(day, total, payloadBytes, limits.rowsPerDay, limits.payloadBytesPerDay)
    .all();
  if (result.results.length !== 1) throw new HttpError(503, "over_capacity");
  // Checked after the reservation, which costs one row at most; size_after is the database size.
  const size = result.meta.size_after;
  if (typeof size === "number" && size > limits.maxDatabaseBytes) throw new HttpError(503, "over_capacity");
}

/** Deletes counters older than `keepFromDay`. */
export async function deleteOldUsage(db: D1Database, keepFromDay: string): Promise<void> {
  await db.prepare("DELETE FROM daily_usage WHERE day < ?1").bind(keepFromDay).run();
}
