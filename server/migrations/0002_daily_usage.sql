-- SPDX-License-Identifier: Apache-2.0
-- Daily write budget (src/budget.ts). Holds only the UTC day and two counters; the daily cron
-- deletes rows older than a week.
CREATE TABLE daily_usage (
  day           TEXT PRIMARY KEY,        -- YYYY-MM-DD (UTC), the day D1's free limits reset on
  rows_written  INTEGER NOT NULL,        -- rows written by API requests, indexes included
  payload_bytes INTEGER NOT NULL         -- bytes of report payload stored
) WITHOUT ROWID;

-- Challenges are now signed instead of stored (src/challenge.ts). The challenges table is no
-- longer used. It is not dropped here, because `npm run deploy` applies migrations before the new
-- code is live and the previous version still writes to it; a later migration can drop it.
