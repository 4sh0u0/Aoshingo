// SPDX-License-Identifier: Apache-2.0

// A daily budget for the D1 writes that requests cause, so that no client (even one with a genuine
// device and valid tokens) can use up the account's daily D1 write quota or fill the database.
// The Workers Free plan allows 100,000 rows written per day for the whole account, a 500 MB
// database and 50 D1 queries per invocation; the defaults in cloudflare.config.ts stay well below.
//
// Every write path reserves its rows and estimated stored bytes first, in the same UTC day that
// D1's limits use. The reservation is one conditional upsert, so concurrent requests cannot
// overshoot. /v1/challenge only reads the counters (checkCapacity). The table holds only the day
// and two counters.
//
// Database size: D1 reports `size_after` with every query, including reads. A Worker cannot read
// page_count or freelist_count (D1 does not allow those PRAGMAs), but size_after counts only pages
// in use: workerd computes it as (page_count - freelist_count) * page_size, and Cloudflare states
// that production D1 has always run with auto-vacuum (github.com/cloudflare/workerd/issues/1618).
// So once the cron deletes old rows the size drops and writes resume without anyone stepping in
// (test/budget.test.ts checks this locally).

import { HttpError } from "./http";

export interface BudgetLimits {
  /** Rows written per UTC day by API requests, including indexes and this table. */
  rowsPerDay: number;
  /** Estimated bytes of new rows stored per UTC day (WriteCost.storedBytes). */
  storedBytesPerDay: number;
  /** Refuse new writes while the database is larger than this. */
  maxDatabaseBytes: number;
}

/** What one request writes. */
export interface WriteCost {
  /** Rows written, indexes included, not counting the reservation itself. */
  rows: number;
  /** Estimated bytes the new rows take in the database (0 for updates in place). */
  storedBytes: number;
}

/** Each reservation updates its own daily_usage row once. */
export const BUDGET_ROW_COST = 1;

const RESERVE_SQL = `
INSERT INTO daily_usage (day, rows_written, stored_bytes) VALUES (?1, ?2, ?3)
    ON CONFLICT (day) DO UPDATE
   SET rows_written = rows_written + excluded.rows_written,
       stored_bytes = stored_bytes + excluded.stored_bytes
 WHERE rows_written + excluded.rows_written <= ?4
   AND stored_bytes + excluded.stored_bytes <= ?5
RETURNING rows_written`;

const USAGE_SQL = "SELECT rows_written, stored_bytes FROM daily_usage WHERE day = ?1";

function overCapacity(): never {
  throw new HttpError(503, "over_capacity");
}

function checkDatabaseSize(limits: BudgetLimits, sizeAfter: unknown): void {
  if (typeof sizeAfter === "number" && sizeAfter > limits.maxDatabaseBytes) overCapacity();
}

/** Rejects a cost that could never fit in one day. */
function checkCost(limits: BudgetLimits, cost: WriteCost): number {
  const rows = cost.rows + BUDGET_ROW_COST;
  if (rows > limits.rowsPerDay || cost.storedBytes > limits.storedBytesPerDay) overCapacity();
  return rows;
}

/**
 * Reserves `cost` for `day` (YYYY-MM-DD, UTC), or throws 503 over_capacity. The caller must count
 * every row it writes, indexes included.
 */
export async function reserveWrites(db: D1Database, limits: BudgetLimits, day: string, cost: WriteCost): Promise<void> {
  const rows = checkCost(limits, cost);
  const result = await db
    .prepare(RESERVE_SQL)
    .bind(day, rows, cost.storedBytes, limits.rowsPerDay, limits.storedBytesPerDay)
    .all();
  if (result.results.length !== 1) overCapacity();
  // Checked after the reservation, which then stays counted although nothing more is written: the
  // counters can only over-count, never under-count. /v1/challenge already refuses while the
  // database is too large, so few requests get this far.
  checkDatabaseSize(limits, result.meta.size_after);
}

/**
 * Throws 503 over_capacity when `cost` no longer fits into `day`'s budget or the database is over
 * its size limit. Read-only: one indexed read, no write. A later reservation can still fail when
 * concurrent requests use up the rest first.
 */
export async function checkCapacity(db: D1Database, limits: BudgetLimits, day: string, cost: WriteCost): Promise<void> {
  const rows = checkCost(limits, cost);
  const result = await db.prepare(USAGE_SQL).bind(day).all<{ rows_written: number; stored_bytes: number }>();
  const used = result.results[0];
  if (
    used !== undefined &&
    (used.rows_written + rows > limits.rowsPerDay || used.stored_bytes + cost.storedBytes > limits.storedBytesPerDay)
  ) {
    overCapacity();
  }
  checkDatabaseSize(limits, result.meta.size_after);
}

/** Deletes counters older than `keepFromDay`. */
export async function deleteOldUsage(db: D1Database, keepFromDay: string): Promise<D1Result> {
  return db.prepare("DELETE FROM daily_usage WHERE day < ?1").bind(keepFromDay).run();
}
