// SPDX-License-Identifier: Apache-2.0

// D1 access for report rows and the retention job. Report rows never contain the upload token,
// its ID or the App Attest keyId.

import { randomBytes, toHex } from "./encoding";
import type { Report } from "./report";

/** YYYY-MM-DD in UTC. */
export function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

/** The JSON stored for each intersection, in report order. */
export function reportPayloads(report: Report): string[] {
  return report.intersections.map((intersection) =>
    JSON.stringify({
      serviceUUIDs: intersection.serviceUUIDs,
      emitters: intersection.emitters,
      observations: intersection.observations,
      transitions: intersection.transitions,
    }),
  );
}

/** Rows written per stored intersection: the table and the received_day index. */
export const ROWS_WRITTEN_PER_INTERSECTION = 2;

/** Stores one row per intersection in a single D1 batch (one transaction). */
export async function storeReport(
  db: D1Database,
  report: Report,
  nowMs: number,
  payloads: string[] = reportPayloads(report),
): Promise<void> {
  const receivedDay = utcDay(nowMs);
  const statement = db.prepare(
    `INSERT INTO reports
       (id, intersection_id, received_day, schema, client, observation_count, transition_count, payload)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
  );
  const statements = report.intersections.map((intersection, index) =>
    statement.bind(
      // A random key, so row order says nothing about which rows arrived together.
      toHex(randomBytes(16)),
      intersection.id,
      receivedDay,
      report.schema,
      report.client,
      intersection.observations.length,
      intersection.transitions.length,
      payloads[index]!,
    ),
  );
  await db.batch(statements);
}

/**
 * Limits of one cron run. The Workers Free plan allows 50 D1 queries per invocation (a batch counts
 * as one) and 100,000 rows written per day for the whole account, shared with the requests'
 * budget (src/budget.ts).
 */
export interface FoldLimits {
  /** Rows per chunk. */
  chunkRows: number;
  /**
   * Observations + transitions per chunk (the first row is always taken). Each one adds to at
   * most one aggregate row, so this bounds the aggregate writes of a chunk.
   */
  chunkItems: number;
  /** Chunks per run; each costs two queries. */
  maxChunks: number;
  /** No new chunk is started once this many rows were written in the run. */
  maxRowsWritten: number;
}

// Worst case per chunk: 4,000 aggregate rows + 2 x 1,000 deleted rows (table and index) = 6,000
// rows written, so a run writes at most 45,000 + 6,000 rows and uses 1 + 2 x 20 queries.
export const DEFAULT_FOLD_LIMITS: FoldLimits = {
  chunkRows: 1000,
  chunkItems: 4000,
  maxChunks: 20,
  maxRowsWritten: 45_000,
};

// Message type is byte 2 of the PICS payload, i.e. hex characters 9-10 (1-based) of raw after
// the four characters of the company ID.
const MESSAGE_TYPE_SQL = `(instr('0123456789ABCDEF', substr(json_extract(o.value, '$.raw'), 9, 1)) - 1) * 16
       + (instr('0123456789ABCDEF', substr(json_extract(o.value, '$.raw'), 10, 1)) - 1)`;

const FOLD_TRANSITIONS_SQL = `
INSERT INTO transition_counts (intersection_id, slot, from_state, to_state, hour_jst, count)
SELECT r.intersection_id,
       json_extract(t.value, '$.slot'),
       json_extract(t.value, '$.from'),
       json_extract(t.value, '$.to'),
       ((json_extract(t.value, '$.t') + 32400) % 86400) / 3600,
       COUNT(*)
  FROM reports AS r, json_each(r.payload, '$.transitions') AS t
 WHERE r.received_day < ?1 AND (r.received_day, r.id) <= (?2, ?3)
 GROUP BY 1, 2, 3, 4, 5
    ON CONFLICT (intersection_id, slot, from_state, to_state, hour_jst)
    DO UPDATE SET count = count + excluded.count`;

const FOLD_OBSERVATIONS_SQL = `
INSERT INTO observation_counts (intersection_id, message_type, rssi, bearing, heading, count)
SELECT r.intersection_id,
       ${MESSAGE_TYPE_SQL},
       IFNULL(json_extract(o.value, '$.rssi'), 1),
       IFNULL(json_extract(o.value, '$.bearing'), -1),
       IFNULL(json_extract(o.value, '$.heading'), -1),
       COUNT(*)
  FROM reports AS r, json_each(r.payload, '$.observations') AS o
 WHERE r.received_day < ?1 AND (r.received_day, r.id) <= (?2, ?3)
 GROUP BY 1, 2, 3, 4, 5
    ON CONFLICT (intersection_id, message_type, rssi, bearing, heading)
    DO UPDATE SET count = count + excluded.count`;

const DELETE_FOLDED_SQL = "DELETE FROM reports WHERE received_day < ?1 AND (received_day, id) <= (?2, ?3)";

// The next chunk, in (received_day, id) order so the received_day index (which carries id, as
// the table has no rowid) is read in order and only the chunk's rows are read. Returns no row when
// nothing has expired.
const NEXT_CHUNK_SQL = `
WITH candidates AS (
  SELECT received_day, id, observation_count + transition_count AS items
    FROM reports
   WHERE received_day < ?1
   ORDER BY received_day, id
   LIMIT ?2
), chunk AS (
  SELECT received_day, id
    FROM (SELECT received_day, id,
                 sum(items) OVER (ORDER BY received_day, id ROWS UNBOUNDED PRECEDING) AS running,
                 row_number() OVER (ORDER BY received_day, id) AS n
            FROM candidates)
   WHERE n = 1 OR running <= ?3
)
SELECT (SELECT count(*) FROM candidates) AS available,
       (SELECT count(*) FROM chunk) AS rows,
       received_day AS last_day,
       id AS last_id
  FROM chunk
 ORDER BY received_day DESC, id DESC
 LIMIT 1`;

export interface FoldResult {
  /** Report rows folded and deleted. */
  folded: number;
  chunks: number;
  rowsWritten: number;
  /** True when the run stopped at a limit; expired rows may be left for the next run. */
  stoppedAtLimit: boolean;
}

/**
 * Folds report rows received before `cutoffDay` into the aggregate tables and deletes them, in
 * chunks within `limits`. Each chunk's fold and delete run in one D1 batch (transaction), so a
 * failure never counts a row twice. Rows left over are folded by the next run.
 */
export async function foldExpiredReports(
  db: D1Database,
  cutoffDay: string,
  limits: FoldLimits = DEFAULT_FOLD_LIMITS,
): Promise<FoldResult> {
  const result: FoldResult = { folded: 0, chunks: 0, rowsWritten: 0, stoppedAtLimit: false };
  for (;;) {
    if (result.chunks >= limits.maxChunks || result.rowsWritten >= limits.maxRowsWritten) {
      result.stoppedAtLimit = true;
      break;
    }
    const chunk = await db
      .prepare(NEXT_CHUNK_SQL)
      .bind(cutoffDay, limits.chunkRows, limits.chunkItems)
      .first<{ available: number; rows: number; last_day: string; last_id: string }>();
    if (chunk === null) break;
    const written = await db.batch([
      db.prepare(FOLD_TRANSITIONS_SQL).bind(cutoffDay, chunk.last_day, chunk.last_id),
      db.prepare(FOLD_OBSERVATIONS_SQL).bind(cutoffDay, chunk.last_day, chunk.last_id),
      db.prepare(DELETE_FOLDED_SQL).bind(cutoffDay, chunk.last_day, chunk.last_id),
    ]);
    result.chunks += 1;
    result.folded += chunk.rows;
    result.rowsWritten += written.reduce((sum, item) => sum + (item.meta.rows_written ?? 0), 0);
    // Fewer candidates than asked for, all of them taken: nothing else has expired.
    if (chunk.available < limits.chunkRows && chunk.rows === chunk.available) break;
  }
  return result;
}
