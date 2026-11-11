// SPDX-License-Identifier: Apache-2.0

// D1 access for report rows and the retention job. Report rows never contain the upload token,
// its ID or the App Attest keyId.

import type { WriteCost } from "./budget";
import { randomBytes } from "./encoding";
import type { Report } from "./report";

/** YYYY-MM-DD in UTC. */
export function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

/**
 * The JSON stored for each intersection, in report order. Schema 1 rows keep the shape they always
 * had. Schema 2 rows add the new lists, always written out (empty when the body left them out),
 * and their items carry every field, null when unknown.
 */
export function reportPayloads(report: Report): string[] {
  if (report.schema === 1) {
    return report.intersections.map((intersection) =>
      JSON.stringify({
        serviceUUIDs: intersection.serviceUUIDs,
        emitters: intersection.emitters,
        observations: intersection.observations,
        transitions: intersection.transitions,
      }),
    );
  }
  return report.intersections.map((intersection) =>
    JSON.stringify({
      serviceUUIDs: intersection.serviceUUIDs,
      emitters: intersection.emitters,
      emitterInfo: intersection.emitterInfo,
      observations: intersection.observations,
      transitions: intersection.transitions,
      steps: intersection.steps,
      packets: intersection.packets,
      coverage: intersection.coverage,
      labels: intersection.labels,
    }),
  );
}

/**
 * For each intersection, in report order, the most aggregate rows that folding its stored row can
 * add or update (reports.aggregate_items, which sizes the cron's chunks). A schema 1 observation
 * counts in observation_counts and a transition in transition_counts only. In schema 2 an
 * observation can also count in range_counts, a transition in duration_counts twice (held and
 * cycle), and a step or label in one row at most (duration_counts, crosswalk_labels). packets and
 * coverage are not aggregated. A schema 2 row weighs at most 600 x 2 + 300 x 3 + 600 + 20 = 2,720.
 */
export function aggregateItems(report: Report): number[] {
  if (report.schema === 1) {
    return report.intersections.map((intersection) => intersection.observations.length + intersection.transitions.length);
  }
  return report.intersections.map(
    (intersection) =>
      2 * intersection.observations.length +
      3 * intersection.transitions.length +
      intersection.steps.length +
      intersection.labels.length,
  );
}

/** Rows written per stored intersection: the table and the received_day index. */
export const ROWS_WRITTEN_PER_INTERSECTION = 2;

// SQLite's table B-tree layout (https://www.sqlite.org/fileformat2.html#b_tree_pages) with D1's
// 4,096-byte pages: a record larger than MAX_LOCAL keeps a part of MIN_LOCAL..MAX_LOCAL bytes in
// the leaf page and the rest in overflow pages of OVERFLOW_BYTES each.
const PAGE_BYTES = 4096;
const MAX_LOCAL = PAGE_BYTES - 35;
const MIN_LOCAL = Math.floor(((PAGE_BYTES - 12) * 32) / 255) - 23;
const OVERFLOW_BYTES = PAGE_BYTES - 4;

/**
 * Bytes counted for storing one report row whose payload is `length` bytes: the other columns
 * (about 100 bytes), the index entry and the free space that pages keep. Whole overflow pages,
 * plus the leaf part with at least 400 bytes of overhead, at most a page, and twice its size up to
 * that, because a part larger than half a page has a leaf page to itself. For payloads from
 * 150 B to 60 KB it was at least what the local D1 used (test/storage.test.ts), so a day's budget
 * stores at most DAILY_STORAGE_LIMIT_BYTES. Small rows are overcounted (a 150 B row takes about
 * 280 bytes).
 */
export function rowStorageBytes(length: number): number {
  const record = length + 100;
  let local = record;
  let overflowPages = 0;
  if (record > MAX_LOCAL) {
    const k = MIN_LOCAL + ((record - MIN_LOCAL) % OVERFLOW_BYTES);
    local = k <= MAX_LOCAL ? k : MIN_LOCAL;
    overflowPages = Math.ceil((record - local) / OVERFLOW_BYTES);
  }
  return overflowPages * PAGE_BYTES + Math.max(local + 400, Math.min(2 * local + 100, PAGE_BYTES + 104));
}

/**
 * What storing `payloads` costs. Payloads are ASCII (validated hex, numbers and fixed names), so
 * their length is their size in bytes.
 */
export function reportWriteCost(payloads: string[]): WriteCost {
  return {
    rows: payloads.length * ROWS_WRITTEN_PER_INTERSECTION,
    storedBytes: payloads.reduce((sum, payload) => sum + rowStorageBytes(payload.length), 0),
  };
}

/**
 * A random row key in 0 ..< 2^53: exact as a JavaScript number, so the cron can page through rows
 * by key. Random, so row keys say nothing about which rows arrived together or in which order.
 */
export function randomRowId(): number {
  const bytes = randomBytes(7);
  let id = bytes[0]! & 0x1f;
  for (let i = 1; i < 7; i++) id = id * 256 + bytes[i]!;
  return id;
}

/** Stores one row per intersection in a single D1 batch (one transaction). */
export async function storeReport(
  db: D1Database,
  report: Report,
  nowMs: number,
  payloads: string[] = reportPayloads(report),
): Promise<void> {
  const receivedDay = utcDay(nowMs);
  const items = aggregateItems(report);
  const statement = db.prepare(
    `INSERT INTO reports
       (id, intersection_id, received_day, schema, client, observation_count, transition_count, aggregate_items, payload)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`,
  );
  const statements = report.intersections.map((intersection, index) =>
    statement.bind(
      randomRowId(),
      intersection.id,
      receivedDay,
      report.schema,
      report.client,
      intersection.observations.length,
      intersection.transitions.length,
      items[index]!,
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
   * Aggregate items per chunk (reports.aggregate_items, see aggregateItems; the first row is
   * always taken, and no row weighs more than 2,720). The items bound the aggregate rows that a
   * chunk adds or updates across all five aggregate tables.
   */
  chunkItems: number;
  /** Chunks per run; each costs two queries (the chunk query and one batch). */
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

// The report rows of the chunk that ends at (?2, ?3), among those received before ?1.
const IN_CHUNK_SQL = "r.received_day < ?1 AND (r.received_day, r.id) <= (?2, ?3)";

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
 WHERE ${IN_CHUNK_SQL}
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
 WHERE ${IN_CHUNK_SQL}
 GROUP BY 1, 2, 3, 4, 5
    ON CONFLICT (intersection_id, message_type, rssi, bearing, heading)
    DO UPDATE SET count = count + excluded.count`;

// Schema 2 durations in whole seconds (rounded half up from milliseconds), keyed by the JST
// weekday (0 = Sunday; 1970-01-01, day 0 of Unix time, was a Thursday) and hour of the item's own
// t. held: how long the signal showed `from` before this transition. cycle: time since it last
// changed to `to`. step: how long the remaining-time step `from` (0 when unknown) lasted. Schema 1
// rows have neither durations nor steps, so they add nothing here.
const FOLD_DURATIONS_SQL = `
INSERT INTO duration_counts (intersection_id, kind, slot, state, step, weekday_jst, hour_jst, seconds, count)
SELECT intersection_id, kind, slot, state, step,
       ((t + 32400) / 86400 + 4) % 7,
       ((t + 32400) % 86400) / 3600,
       (ms + 500) / 1000,
       COUNT(*)
  FROM (SELECT r.intersection_id, 'held' AS kind, json_extract(x.value, '$.slot') AS slot,
               json_extract(x.value, '$.from') AS state, 0 AS step,
               json_extract(x.value, '$.t') AS t, json_extract(x.value, '$.held') AS ms
          FROM reports AS r, json_each(r.payload, '$.transitions') AS x
         WHERE ${IN_CHUNK_SQL}
        UNION ALL
        SELECT r.intersection_id, 'cycle', json_extract(x.value, '$.slot'),
               json_extract(x.value, '$.to'), 0,
               json_extract(x.value, '$.t'), json_extract(x.value, '$.cycle')
          FROM reports AS r, json_each(r.payload, '$.transitions') AS x
         WHERE ${IN_CHUNK_SQL}
        UNION ALL
        SELECT r.intersection_id, 'step', json_extract(x.value, '$.slot'),
               json_extract(x.value, '$.state'), IFNULL(json_extract(x.value, '$.from'), 0),
               json_extract(x.value, '$.t'), json_extract(x.value, '$.held')
          FROM reports AS r, json_each(r.payload, '$.steps') AS x
         WHERE ${IN_CHUNK_SQL})
 WHERE ms IS NOT NULL
 GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
    ON CONFLICT (intersection_id, kind, slot, state, step, weekday_jst, hour_jst, seconds)
    DO UPDATE SET count = count + excluded.count`;

// Schema 2 observations with a distance, by signal strength, distance and bearing. Unknown values
// use the sentinels of observation_counts.
const FOLD_RANGES_SQL = `
INSERT INTO range_counts (intersection_id, rssi, distance, bearing, count)
SELECT r.intersection_id,
       IFNULL(json_extract(o.value, '$.rssi'), 1),
       json_extract(o.value, '$.distance'),
       IFNULL(json_extract(o.value, '$.bearing'), -1),
       COUNT(*)
  FROM reports AS r, json_each(r.payload, '$.observations') AS o
 WHERE ${IN_CHUNK_SQL} AND json_extract(o.value, '$.distance') IS NOT NULL
 GROUP BY 1, 2, 3, 4
    ON CONFLICT (intersection_id, rssi, distance, bearing)
    DO UPDATE SET count = count + excluded.count`;

// Crosswalk labels (their slot is never null). Button labels, packets and coverage are not kept.
const FOLD_CROSSWALKS_SQL = `
INSERT INTO crosswalk_labels (intersection_id, slot, bearing, heading, distance, count)
SELECT r.intersection_id,
       json_extract(l.value, '$.slot'),
       IFNULL(json_extract(l.value, '$.bearing'), -1),
       IFNULL(json_extract(l.value, '$.heading'), -1),
       IFNULL(json_extract(l.value, '$.distance'), -1),
       COUNT(*)
  FROM reports AS r, json_each(r.payload, '$.labels') AS l
 WHERE ${IN_CHUNK_SQL} AND json_extract(l.value, '$.kind') = 'crosswalk'
 GROUP BY 1, 2, 3, 4, 5
    ON CONFLICT (intersection_id, slot, bearing, heading, distance)
    DO UPDATE SET count = count + excluded.count`;

const DELETE_FOLDED_SQL = "DELETE FROM reports WHERE received_day < ?1 AND (received_day, id) <= (?2, ?3)";

// The next chunk, in (received_day, id) order so the received_day index (which carries the rowid
// id) is read in order and only the chunk's rows are read. Returns no row when nothing has
// expired. Rows that the previous version inserted while a deploy was under way have the column
// default aggregate_items = 0; they are schema 1, for which observations + transitions is exact.
const NEXT_CHUNK_SQL = `
WITH candidates AS (
  SELECT received_day, id, max(aggregate_items, observation_count + transition_count) AS items
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
      .first<{ available: number; rows: number; last_day: string; last_id: number }>();
    if (chunk === null) break;
    // The delete comes last, after every aggregate has read the chunk's rows.
    const written = await db.batch(
      [
        FOLD_TRANSITIONS_SQL,
        FOLD_OBSERVATIONS_SQL,
        FOLD_DURATIONS_SQL,
        FOLD_RANGES_SQL,
        FOLD_CROSSWALKS_SQL,
        DELETE_FOLDED_SQL,
      ].map((sql) => db.prepare(sql).bind(cutoffDay, chunk.last_day, chunk.last_id)),
    );
    result.chunks += 1;
    result.folded += chunk.rows;
    result.rowsWritten += written.reduce((sum, item) => sum + (item.meta.rows_written ?? 0), 0);
    // Fewer candidates than asked for, all of them taken: nothing else has expired.
    if (chunk.available < limits.chunkRows && chunk.rows === chunk.available) break;
  }
  return result;
}
