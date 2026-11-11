-- SPDX-License-Identifier: Apache-2.0
-- Initial schema for the Aoshingo field-data Worker (docs/field-data-api.md).

-- Single-use App Attest challenges (300 s lifetime). Consumed rows are deleted immediately;
-- expired ones are removed by the daily cron.
CREATE TABLE challenges (
  challenge  TEXT PRIMARY KEY,           -- base64url, 32 random bytes
  expires_at INTEGER NOT NULL            -- Unix seconds
) WITHOUT ROWID;
CREATE INDEX challenges_by_expiry ON challenges (expires_at);

-- Registered App Attest keys. Kept apart from report data: no report row references a key.
CREATE TABLE attest_keys (
  key_id      TEXT PRIMARY KEY,          -- hex of the 32-byte keyId
  public_key  TEXT NOT NULL,             -- hex of the uncompressed P-256 point (65 bytes)
  sign_count  INTEGER NOT NULL,
  environment TEXT NOT NULL CHECK (environment IN ('production', 'development')),
  created_day TEXT NOT NULL              -- YYYY-MM-DD (UTC)
) WITHOUT ROWID;

-- Raw report data: one row per intersection per accepted report, kept for RETENTION_DAYS.
-- Neither the upload token, its ID nor the keyId is stored. The primary key is random, so rows
-- carry no arrival order.
CREATE TABLE reports (
  id                TEXT PRIMARY KEY,    -- 16 random bytes, hex
  intersection_id   TEXT NOT NULL,       -- 8 uppercase hex digits
  received_day      TEXT NOT NULL,       -- YYYY-MM-DD (UTC), day granularity only
  schema            INTEGER NOT NULL,
  client            TEXT,                -- e.g. "aoshingo-ios/0.1.0", or NULL
  observation_count INTEGER NOT NULL,
  transition_count  INTEGER NOT NULL,
  payload           TEXT NOT NULL CHECK (json_valid(payload))
                    -- {"serviceUUIDs": [...], "emitters": n, "observations": [...], "transitions": [...]}
) WITHOUT ROWID;
CREATE INDEX reports_by_received_day ON reports (received_day);

-- Aggregates that outlive the retention period. The cron adds expiring rows to these counts.

-- Signal state transitions per slot and JST hour of day (0-23).
CREATE TABLE transition_counts (
  intersection_id TEXT NOT NULL,
  slot            INTEGER NOT NULL,      -- 1-6
  from_state      TEXT NOT NULL,
  to_state        TEXT NOT NULL,
  hour_jst        INTEGER NOT NULL,      -- 0-23, from the transition's own timestamp
  count           INTEGER NOT NULL,
  PRIMARY KEY (intersection_id, slot, from_state, to_state, hour_jst)
) WITHOUT ROWID;

-- Observations per message type (byte 2 of the PICS payload) and bucket.
-- Unknown values use sentinels so they can be part of the key: rssi = 1, bearing/heading = -1.
CREATE TABLE observation_counts (
  intersection_id TEXT NOT NULL,
  message_type    INTEGER NOT NULL,      -- 0-255
  rssi            INTEGER NOT NULL,      -- -130..0 in steps of 5, or 1 when unknown
  bearing         INTEGER NOT NULL,      -- 0-7, or -1 when unknown
  heading         INTEGER NOT NULL,      -- 0-7, or -1 when unknown
  count           INTEGER NOT NULL,
  PRIMARY KEY (intersection_id, message_type, rssi, bearing, heading)
) WITHOUT ROWID;
