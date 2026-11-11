-- SPDX-License-Identifier: Apache-2.0
-- Key retention, storage accounting and a cron status row.
--
-- `npm run deploy` applies migrations before the new code is live. Until the deploy finishes
-- (usually well under a minute), the previous version fails on the changed tables and answers
-- 500, and the app retries later. That short outage is accepted.

-- 1. Challenges are signed instead of stored (src/challenge.ts), and nothing uses this table any more.
DROP INDEX IF EXISTS challenges_by_expiry;
DROP TABLE IF EXISTS challenges;

-- 2. The UTC day each App Attest key was last used (attested or refreshed). The daily cron
-- deletes keys unused for 30 days (src/keys.ts). Keys that exist now count as used on the day
-- they were registered, so the first cron deletes those registered more than 30 days ago, and their
-- apps attest a new key once (/v1/token answers 404 unknown_key). The empty default (a row the previous version might insert during the
-- deploy) counts as never used, so such a key is deleted by the next cron and its app attests a new key.
ALTER TABLE attest_keys ADD COLUMN last_used_day TEXT NOT NULL DEFAULT '';
UPDATE attest_keys SET last_used_day = created_day;

-- 3. Report rows move to a rowid table. In a WITHOUT ROWID table a row of about 1-4 KB spills
-- into an overflow page that it mostly leaves empty, so such rows took 3-5 times their size.
-- The key is still random (a 53-bit integer, src/storage.ts), so rows carry no arrival order.
CREATE TABLE reports_new (
  id                INTEGER PRIMARY KEY, -- random, 0 <= id < 2^53
  intersection_id   TEXT NOT NULL,       -- 8 uppercase hex digits
  received_day      TEXT NOT NULL,       -- YYYY-MM-DD (UTC), day granularity only
  schema            INTEGER NOT NULL,
  client            TEXT,                -- for example aoshingo-ios/0.1.0, or NULL
  observation_count INTEGER NOT NULL,
  transition_count  INTEGER NOT NULL,
  payload           TEXT NOT NULL CHECK (json_valid(payload))
                    -- JSON object with serviceUUIDs, emitters, observations and transitions
);
INSERT INTO reports_new
       (id, intersection_id, received_day, schema, client, observation_count, transition_count, payload)
SELECT random() & 9007199254740991, intersection_id, received_day, schema, client,
       observation_count, transition_count, payload
  FROM reports;
DROP INDEX reports_by_received_day;
DROP TABLE reports;
ALTER TABLE reports_new RENAME TO reports;
CREATE INDEX reports_by_received_day ON reports (received_day);

-- 4. The daily budget now counts an estimate of the bytes stored (payload plus a fixed amount
-- per row, src/storage.ts), not only the payload.
ALTER TABLE daily_usage RENAME COLUMN payload_bytes TO stored_bytes;

-- 5. What the last successful cron run did (src/cron.ts), because the Worker keeps no logs.
-- One row with only times, counts and the database size.
CREATE TABLE service_state (
  id                INTEGER PRIMARY KEY CHECK (id = 1),
  cron_last_success TEXT NOT NULL,       -- ISO 8601 time (UTC) the last run without errors started
  folded_reports    INTEGER NOT NULL,    -- report rows it folded into aggregates and deleted
  backlog           INTEGER NOT NULL,    -- 1 when it stopped at a limit (the rest waits a day)
  deleted_keys      INTEGER NOT NULL,    -- App Attest keys it deleted for not being used
  rows_written      INTEGER NOT NULL,    -- rows it wrote, indexes included
  database_bytes    INTEGER              -- size_after reported by D1 after its deletions
);
