// SPDX-License-Identifier: Apache-2.0

// The daily cron (0 18 * * * UTC = 03:00 JST): drops old usage counters, folds expired reports
// into aggregates, deletes App Attest keys that are no longer used, and records what it did in
// service_state, since the Worker keeps no logs. That row holds only times, counts and the
// database size. Each job runs even when an earlier one failed (for example a fold that hits a D1
// limit must not keep unused keys); a run with a failed job records nothing, so
// cron_last_success falls behind, and ends with that job's error.
//
// Free plan limits per run: D1 queries 1 (usage) + 2 per fold chunk (the chunk query and one batch
// with all its statements; at most 40) + 1 (keys) + 1 (record) = 43 of 50. Rows written at most
// about 52,000 (fold) + 10,000 (keys) + a few; with the API's DAILY_WRITE_LIMIT of 30,000 and the
// timing cron's 5,741 (src/timing.ts) that stays below the account's 100,000 per day.

import { deleteOldUsage } from "./budget";
import { deleteUnusedKeys, KEY_DELETE_LIMIT, KEY_RETENTION_DAYS } from "./keys";
import { DEFAULT_FOLD_LIMITS, foldExpiredReports, utcDay, type FoldLimits, type FoldResult } from "./storage";

const DAY_MS = 86_400_000;

/** The cron expression of the daily jobs, as declared in cloudflare.config.ts and wrangler.jsonc. */
export const DAILY_CRON = "0 18 * * *";

/** daily_usage rows older than this many days are deleted. */
export const USAGE_KEEP_DAYS = 7;

export interface CronLimits {
  fold: FoldLimits;
  keyDeleteLimit: number;
}

export const DEFAULT_CRON_LIMITS: CronLimits = { fold: DEFAULT_FOLD_LIMITS, keyDeleteLimit: KEY_DELETE_LIMIT };

/** D1 queries one run makes at most (the Free plan allows 50 per invocation). */
export function maxCronQueries(limits: CronLimits = DEFAULT_CRON_LIMITS): number {
  return 1 + 2 * limits.fold.maxChunks + 1 + 1;
}

export interface CronResult {
  fold: FoldResult;
  deletedKeys: number;
  rowsWritten: number;
  databaseBytes: number | null;
}

const RECORD_SQL = `
INSERT INTO service_state
       (id, cron_last_success, folded_reports, backlog, deleted_keys, rows_written, database_bytes)
VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6)
    ON CONFLICT (id) DO UPDATE
   SET cron_last_success = excluded.cron_last_success,
       folded_reports = excluded.folded_reports,
       backlog = excluded.backlog,
       deleted_keys = excluded.deleted_keys,
       rows_written = excluded.rows_written,
       database_bytes = excluded.database_bytes`;

/** Runs the daily jobs as of `nowMs`. Rows expire `retentionDays` after the day they arrived. */
export async function runDailyJobs(
  db: D1Database,
  nowMs: number,
  retentionDays: number,
  limits: CronLimits = DEFAULT_CRON_LIMITS,
): Promise<CronResult> {
  const errors: unknown[] = [];
  async function attempt<T>(job: () => Promise<T>): Promise<T | null> {
    try {
      return await job();
    } catch (error) {
      errors.push(error);
      return null;
    }
  }
  const usage = await attempt(() => deleteOldUsage(db, utcDay(nowMs - USAGE_KEEP_DAYS * DAY_MS)));
  const fold = await attempt(() => foldExpiredReports(db, utcDay(nowMs - retentionDays * DAY_MS), limits.fold));
  const keys = await attempt(() =>
    deleteUnusedKeys(db, utcDay(nowMs - KEY_RETENTION_DAYS * DAY_MS), limits.keyDeleteLimit),
  );
  if (usage === null || fold === null || keys === null) throw errors[0];

  const size = keys.meta.size_after;
  const result: CronResult = {
    fold,
    deletedKeys: keys.meta.changes ?? 0,
    // The record below writes one more row.
    rowsWritten: (usage.meta.rows_written ?? 0) + fold.rowsWritten + (keys.meta.rows_written ?? 0) + 1,
    databaseBytes: typeof size === "number" ? size : null,
  };
  await db
    .prepare(RECORD_SQL)
    .bind(
      new Date(nowMs).toISOString().slice(0, 19) + "Z",
      fold.folded,
      fold.stoppedAtLimit ? 1 : 0,
      result.deletedKeys,
      result.rowsWritten,
      result.databaseBytes,
    )
    .run();
  return result;
}
