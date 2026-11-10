// SPDX-License-Identifier: Apache-2.0

// D1 access for report rows and the retention job. Report rows never contain the upload token,
// its ID or the App Attest keyId.

import { randomBytes, toHex } from "./encoding";
import type { Report } from "./report";

/** YYYY-MM-DD in UTC. */
export function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

/** Stores one row per intersection in a single D1 batch (one transaction). */
export async function storeReport(db: D1Database, report: Report, nowMs: number): Promise<void> {
  const receivedDay = utcDay(nowMs);
  const statement = db.prepare(
    `INSERT INTO reports
       (id, intersection_id, received_day, schema, client, observation_count, transition_count, payload)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
  );
  const statements = report.intersections.map((intersection) =>
    statement.bind(
      // A random key, so row order says nothing about which rows arrived together.
      toHex(randomBytes(16)),
      intersection.id,
      receivedDay,
      report.schema,
      report.client,
      intersection.observations.length,
      intersection.transitions.length,
      JSON.stringify({
        serviceUUIDs: intersection.serviceUUIDs,
        emitters: intersection.emitters,
        observations: intersection.observations,
        transitions: intersection.transitions,
      }),
    ),
  );
  await db.batch(statements);
}

// Up to 20,000 rows per cron run (two D1 calls per chunk, well under the per-invocation
// subrequest limit). Anything left over is folded on the following days.
const FOLD_BATCH_SIZE = 200;
const MAX_FOLD_BATCHES = 100;

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
 WHERE r.received_day < ?1 AND r.id <= ?2
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
 WHERE r.received_day < ?1 AND r.id <= ?2
 GROUP BY 1, 2, 3, 4, 5
    ON CONFLICT (intersection_id, message_type, rssi, bearing, heading)
    DO UPDATE SET count = count + excluded.count`;

const DELETE_FOLDED_SQL = "DELETE FROM reports WHERE received_day < ?1 AND id <= ?2";

/**
 * Folds report rows received before `cutoffDay` into the aggregate tables and deletes them.
 * Works in chunks ordered by id; each chunk's fold and delete run in one D1 batch (transaction),
 * so a failure never counts a row twice. Returns the number of rows folded.
 */
export async function foldExpiredReports(db: D1Database, cutoffDay: string): Promise<number> {
  let folded = 0;
  for (let i = 0; i < MAX_FOLD_BATCHES; i++) {
    const chunk = await db
      .prepare(
        `SELECT max(id) AS last_id, count(*) AS rows
           FROM (SELECT id FROM reports WHERE received_day < ?1 ORDER BY id LIMIT ?2)`,
      )
      .bind(cutoffDay, FOLD_BATCH_SIZE)
      .first<{ last_id: string | null; rows: number }>();
    if (chunk === null || chunk.last_id === null || chunk.rows === 0) break;
    await db.batch([
      db.prepare(FOLD_TRANSITIONS_SQL).bind(cutoffDay, chunk.last_id),
      db.prepare(FOLD_OBSERVATIONS_SQL).bind(cutoffDay, chunk.last_id),
      db.prepare(DELETE_FOLDED_SQL).bind(cutoffDay, chunk.last_id),
    ]);
    folded += chunk.rows;
    if (chunk.rows < FOLD_BATCH_SIZE) break;
  }
  return folded;
}
