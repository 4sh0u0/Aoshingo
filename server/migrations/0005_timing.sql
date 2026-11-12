-- SPDX-License-Identifier: Apache-2.0
-- Report schema 4 and the timing plans (docs/timing-estimation.md): the clock check of each report
-- row, the tables of the fitted plans, and the status of the cron that fits them.
--
-- `npm run deploy` applies migrations before the new code is live. This one only adds nullable
-- columns, a partial index and tables, so the previous version keeps working until the deploy
-- finishes: it accepts schema 1 to 3 only and inserts rows with clock_ok NULL, which the partial
-- index leaves out (so its count of rows written per report stays exact); it never reads the new
-- tables; and its daily cron records its own columns of service_state only. Its scheduled handler
-- would run the daily jobs for the new 18:30 trigger too, but the trigger is added by the same
-- deploy that replaces the code.

-- 1. The clock check of schema 4 (src/storage.ts, clockOk): 1 when the device clock (sentAt) was
-- within 2 seconds of the server's when the request arrived, 0 otherwise, NULL for schema 1 to 3.
-- Neither sentAt nor the difference is stored: a device's steady clock offset could link its reports.
ALTER TABLE reports ADD COLUMN clock_ok INTEGER CHECK (clock_ok IN (0, 1));

-- The rows the timing cron reads (clock_ok = 1), by intersection. Partial, so rows of schema 1 to 3
-- and rows with clock_ok = 0 cost no extra write; a row with clock_ok = 1 costs one more row written
-- (src/storage.ts, TIMING_INDEX_ROWS). Without it each intersection's fit would scan every report row.
CREATE INDEX reports_for_timing ON reports (intersection_id, received_day) WHERE clock_ok = 1;

-- 2. Fitted timing plans (src/timing.ts): one row per published cell. Holds what the signal does
-- and last_day, which only serves to delete the row: the cron deletes rows whose last_day is more
-- than 21 days before its UTC day, and never stores such a cell. The day counts and report counts
-- that decide publication are checked during the fit and not stored, and GET /v1/plans serves none
-- of last_day and updated_day: with the bin and the intersection, they could tell when a single
-- contributor passed. The cron replaces an intersection's rows at every fit.
CREATE TABLE timing_plans (
  intersection_id TEXT NOT NULL,       -- 8 uppercase hex digits
  slot            INTEGER NOT NULL,    -- 1-6
  day_type        INTEGER NOT NULL,    -- 0 = Monday to Friday, 1 = Saturday, 2 = Sunday (JST)
  bin             INTEGER NOT NULL,    -- 0-47: minutes since midnight JST divided by 30
  cycle_ms        INTEGER NOT NULL,    -- whole seconds, 30,000-300,000
  reference       TEXT NOT NULL CHECK (reference IN ('epoch', 'midnight')),
  phase_ms        INTEGER NOT NULL,    -- 0 <= phase_ms < cycle_ms, from the reference
  spread_ms       INTEGER NOT NULL,    -- 0-3,000: spread of the daily phases
  green_ms        INTEGER,             -- median held of Green, or NULL
  blink_ms        INTEGER,             -- median held of BlinkGreen, or NULL
  last_day        TEXT NOT NULL,       -- YYYY-MM-DD (JST), the last date with a green start; never served
  updated_day     TEXT NOT NULL,       -- YYYY-MM-DD (UTC), when the cron fitted it; never served
  PRIMARY KEY (intersection_id, slot, day_type, bin)
) WITHOUT ROWID;

-- The name (PICS message type 0) and position (type 1) that the intersection's signal broadcasts,
-- as raw packets: public data. One row per fitted intersection; updated_day (UTC) is the day of its
-- last fit, which orders the cron's work. The cron deletes the row once the intersection has no
-- plans and no clock_ok = 1 row received in the last 21 days.
CREATE TABLE timing_places (
  intersection_id TEXT PRIMARY KEY,    -- 8 uppercase hex digits
  name_raw        TEXT,                -- uppercase hex starting with CE01, or NULL
  position_raw    TEXT,                -- uppercase hex starting with CE01, or NULL
  updated_day     TEXT NOT NULL        -- YYYY-MM-DD (UTC); never served
) WITHOUT ROWID;

-- The body of GET /v1/plans, rebuilt in SQL at the end of every timing cron run, so that a request
-- reads one row per chunk instead of every plan, and no value comes near D1's 2 MB limit. Each
-- chunk holds the intersection objects of the response, joined with commas and without the
-- enclosing brackets, in intersection order; chunk 0 with an empty body when there are no plans.
CREATE TABLE timing_snapshot (
  chunk           INTEGER PRIMARY KEY, -- 0, 1, 2, ...
  body            TEXT NOT NULL,       -- about 1 MB at most
  generated       TEXT NOT NULL        -- YYYY-MM-DD (UTC), the day of the run that built it
);

-- 3. What the last successful timing cron run did (src/timing.ts), next to the daily cron's columns.
-- Only times and counts. NULL until the timing cron first succeeds.
ALTER TABLE service_state ADD COLUMN timing_last_success TEXT;  -- ISO 8601 time (UTC) the run started
ALTER TABLE service_state ADD COLUMN timing_fitted INTEGER;      -- intersections it fitted
ALTER TABLE service_state ADD COLUMN timing_plan_rows INTEGER;   -- plan rows it stored
ALTER TABLE service_state ADD COLUMN timing_expired INTEGER;     -- plan rows it deleted after 21 days
ALTER TABLE service_state ADD COLUMN timing_backlog INTEGER;     -- 1 when it stopped at the row limit
ALTER TABLE service_state ADD COLUMN timing_waiting INTEGER;     -- intersections with new data it left for later
ALTER TABLE service_state ADD COLUMN timing_rows_written INTEGER; -- rows it wrote
