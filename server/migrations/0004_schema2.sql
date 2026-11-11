-- SPDX-License-Identifier: Apache-2.0
-- Report schema 2 (docs/field-data-api.md): aggregates for its new fields, and how many aggregate
-- rows each report row can add when the cron folds it.
--
-- `npm run deploy` applies migrations before the new code is live. This one only adds tables and a
-- column with a default, so the previous version keeps working until the deploy finishes: it
-- never reads the new tables, accepts only schema 1 reports, and inserts rows with
-- aggregate_items = 0. The new cron weighs every row by at least observation_count +
-- transition_count, which is exact for schema 1 rows (src/storage.ts, NEXT_CHUNK_SQL).

-- 1. Aggregates that outlive the retention period, like those of 0001. Unknown values use
-- sentinels so they can be part of the key: rssi = 1; bearing, heading and distance = -1.

-- How long signal states, cycles and remaining-time steps lasted, per JST weekday and hour of the
-- item's own timestamp. Durations are rounded to whole seconds.
CREATE TABLE duration_counts (
  intersection_id TEXT NOT NULL,
  kind            TEXT NOT NULL CHECK (kind IN ('held', 'cycle', 'step')),
                  -- held: transitions[].held; cycle: transitions[].cycle; step: steps[].held
  slot            INTEGER NOT NULL,      -- 1-6
  state           TEXT NOT NULL,         -- held: from; cycle: to; step: the state
  step            INTEGER NOT NULL,      -- step: from (1-8), or 0 when unknown; 0 for held and cycle
  weekday_jst     INTEGER NOT NULL,      -- 0-6, 0 = Sunday
  hour_jst        INTEGER NOT NULL,      -- 0-23
  seconds         INTEGER NOT NULL,      -- 0-3600
  count           INTEGER NOT NULL,
  PRIMARY KEY (intersection_id, kind, slot, state, step, weekday_jst, hour_jst, seconds)
) WITHOUT ROWID;

-- Observations with a distance, per signal strength, distance and bearing.
CREATE TABLE range_counts (
  intersection_id TEXT NOT NULL,
  rssi            INTEGER NOT NULL,      -- -130..0 in steps of 5, or 1 when unknown
  distance        INTEGER NOT NULL,      -- 0, 10, 20, 40, 80 or 160 (m, lower bound)
  bearing         INTEGER NOT NULL,      -- 0-7, or -1 when unknown
  count           INTEGER NOT NULL,
  PRIMARY KEY (intersection_id, rssi, distance, bearing)
) WITHOUT ROWID;

-- Testers' crosswalk labels (labels[].kind = 'crosswalk'). Button labels are not kept.
CREATE TABLE crosswalk_labels (
  intersection_id TEXT NOT NULL,
  slot            INTEGER NOT NULL,      -- 1-6
  bearing         INTEGER NOT NULL,      -- 0-7, or -1 when unknown
  heading         INTEGER NOT NULL,      -- 0-7, or -1 when unknown
  distance        INTEGER NOT NULL,      -- 0, 10, 20, 40, 80 or 160, or -1 when unknown
  count           INTEGER NOT NULL,
  PRIMARY KEY (intersection_id, slot, bearing, heading, distance)
) WITHOUT ROWID;

-- 2. The most aggregate rows a report row adds when folded (src/storage.ts, aggregateItems).
-- The cron sizes its chunks with it, so that a chunk's writes stay bounded although a schema 2
-- item can count in more than one table. Rows stored so far are schema 1, where each observation
-- and transition counts once.
ALTER TABLE reports ADD COLUMN aggregate_items INTEGER NOT NULL DEFAULT 0;
UPDATE reports SET aggregate_items = observation_count + transition_count;
