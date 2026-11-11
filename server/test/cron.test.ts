// SPDX-License-Identifier: Apache-2.0

import { createExecutionContext, createScheduledController } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { DEFAULT_CRON_LIMITS, maxCronQueries, runDailyJobs } from "../src/cron";
import { encodeBase64 } from "../src/encoding";
import { KEY_RETENTION_DAYS } from "../src/keys";
import type { Report } from "../src/report";
import { DEFAULT_FOLD_LIMITS, foldExpiredReports, storeReport, utcDay } from "../src/storage";
import { buildAssertion } from "./helpers/appattest";
import {
  APP_ID,
  createContext,
  getChallenge,
  meteredDatabase,
  postJson,
  registerKey,
  resetDatabase,
  usage,
  type RegisteredKey,
  type TestContext,
} from "./helpers/context";

const DAY_MS = 86_400_000;
// 2026-11-10 18:00 UTC, when the daily cron runs (03:00 JST).
const NOW = Date.UTC(2026, 10, 10, 18, 0, 0);

let context: TestContext;

beforeEach(async () => {
  await resetDatabase();
  context = await createContext();
  context.clock.ms = NOW;
});

function raw(id: string, messageType: number): string {
  return `CE010000${messageType.toString(16).padStart(2, "0").toUpperCase()}2A0000${id}31138484`;
}

/** A report whose own timestamps sit at `receivedMs`. */
function report(receivedMs: number, ids: string[] = ["1234ABCD"]): Report {
  const t = Math.floor(receivedMs / 1000);
  return {
    schema: 1,
    client: "aoshingo-ios/0.1.0",
    intersections: ids.map((id) => ({
      id,
      serviceUUIDs: [],
      emitters: 1,
      observations: [
        { t, raw: raw(id, 2), rssi: -70, bearing: 3, heading: null },
        { t: t + 1, raw: raw(id, 2), rssi: -70, bearing: 3, heading: null },
        { t: t + 2, raw: raw(id, 0), rssi: null, bearing: null, heading: 7 },
      ],
      transitions: [
        { t, slot: 1, from: "Red", to: "Green" },
        { t: t + 40, slot: 1, from: "Green", to: "BlinkGreen" },
      ],
    })),
  };
}

async function runCron(): Promise<void> {
  await context.app.scheduled(createScheduledController({ cron: "0 18 * * *" }), context.env, createExecutionContext());
}

async function rows(sql: string): Promise<Record<string, unknown>[]> {
  return (await env.DB.prepare(sql).all<Record<string, unknown>>()).results;
}

describe("scheduled retention job", () => {
  it("folds reports older than RETENTION_DAYS into aggregates and deletes them", async () => {
    // 2026-08-11 00:30 UTC = 09:30 JST; 91 days before NOW's day, so it is past retention.
    const expiredAt = Date.UTC(2026, 7, 11, 0, 30);
    await storeReport(env.DB, report(expiredAt), expiredAt);
    await storeReport(env.DB, report(expiredAt + 3600_000), expiredAt + 3600_000);
    // 2026-08-12 (exactly 90 days) and today are kept.
    const keptAt = Date.UTC(2026, 7, 12, 23, 0);
    await storeReport(env.DB, report(keptAt), keptAt);
    await storeReport(env.DB, report(NOW), NOW);

    await runCron();

    expect(await rows("SELECT received_day FROM reports ORDER BY received_day")).toEqual([
      { received_day: "2026-08-12" },
      { received_day: "2026-11-10" },
    ]);
    expect(
      await rows("SELECT * FROM transition_counts ORDER BY hour_jst, from_state"),
    ).toEqual([
      { intersection_id: "1234ABCD", slot: 1, from_state: "Green", to_state: "BlinkGreen", hour_jst: 9, count: 1 },
      { intersection_id: "1234ABCD", slot: 1, from_state: "Red", to_state: "Green", hour_jst: 9, count: 1 },
      { intersection_id: "1234ABCD", slot: 1, from_state: "Green", to_state: "BlinkGreen", hour_jst: 10, count: 1 },
      { intersection_id: "1234ABCD", slot: 1, from_state: "Red", to_state: "Green", hour_jst: 10, count: 1 },
    ]);
    expect(await rows("SELECT * FROM observation_counts ORDER BY message_type")).toEqual([
      { intersection_id: "1234ABCD", message_type: 0, rssi: 1, bearing: -1, heading: 7, count: 2 },
      { intersection_id: "1234ABCD", message_type: 2, rssi: -70, bearing: 3, heading: -1, count: 4 },
    ]);
  });

  it("computes the JST hour across midnight", async () => {
    // 15:10 UTC = 00:10 JST the next day.
    const expiredAt = Date.UTC(2026, 7, 1, 15, 10);
    await storeReport(env.DB, report(expiredAt), expiredAt);
    await runCron();
    expect(await rows("SELECT DISTINCT hour_jst FROM transition_counts")).toEqual([{ hour_jst: 0 }]);
  });

  it("adds to existing aggregates and never counts a row twice", async () => {
    const expiredAt = Date.UTC(2026, 7, 1, 0, 30);
    await storeReport(env.DB, report(expiredAt), expiredAt);
    await runCron();
    await runCron();
    expect(await rows("SELECT sum(count) AS n FROM observation_counts")).toEqual([{ n: 3 }]);

    await storeReport(env.DB, report(expiredAt), expiredAt);
    await runCron();
    expect(await rows("SELECT sum(count) AS n FROM observation_counts")).toEqual([{ n: 6 }]);
    expect(await rows("SELECT count, from_state FROM transition_counts ORDER BY from_state")).toEqual([
      { count: 2, from_state: "Green" },
      { count: 2, from_state: "Red" },
    ]);
  });

  it("folds a 50-intersection backlog in one run", async () => {
    const expiredAt = Date.UTC(2026, 6, 1, 0, 0);
    const ids = Array.from({ length: 50 }, (_, i) => (0x20000000 + i).toString(16).toUpperCase());
    for (let i = 0; i < 9; i++) await storeReport(env.DB, report(expiredAt, ids), expiredAt);
    expect(await rows("SELECT count(*) AS n FROM reports")).toEqual([{ n: 450 }]);

    await runCron();

    expect(await rows("SELECT count(*) AS n FROM reports")).toEqual([{ n: 0 }]);
    expect(await rows("SELECT sum(count) AS n FROM observation_counts")).toEqual([{ n: 450 * 3 }]);
    expect(await rows("SELECT sum(count) AS n FROM transition_counts")).toEqual([{ n: 450 * 2 }]);
    expect(await rows("SELECT count(DISTINCT intersection_id) AS n FROM observation_counts")).toEqual([{ n: 50 }]);
  });

  it("sizes chunks by observations and transitions", async () => {
    // Each row holds 3 observations + 2 transitions = 5 items.
    for (const day of [3, 1, 2]) {
      const at = Date.UTC(2026, 6, day, 0, 0);
      await storeReport(env.DB, report(at, ["10000001", "10000002", "10000003"]), at);
    }
    const cutoff = utcDay(NOW - 90 * DAY_MS);
    const limits = { ...DEFAULT_FOLD_LIMITS, chunkItems: 12 };

    const result = await foldExpiredReports(env.DB, cutoff, limits);

    expect(result).toMatchObject({ folded: 9, chunks: 5, stoppedAtLimit: false });
    expect(result.rowsWritten).toBeGreaterThan(0);
    expect(await rows("SELECT count(*) AS n FROM reports")).toEqual([{ n: 0 }]);
    expect(await rows("SELECT sum(count) AS n FROM observation_counts")).toEqual([{ n: 27 }]);
  });

  it("takes a row larger than the item limit on its own", async () => {
    const at = Date.UTC(2026, 6, 1, 0, 0);
    await storeReport(env.DB, report(at, ["10000001", "10000002"]), at);
    const result = await foldExpiredReports(env.DB, utcDay(NOW - 90 * DAY_MS), {
      ...DEFAULT_FOLD_LIMITS,
      chunkItems: 1,
    });
    expect(result).toMatchObject({ folded: 2, chunks: 2 });
  });

  it("stops at the chunk limit and leaves the rest for the next run", async () => {
    const at = Date.UTC(2026, 6, 1, 0, 0);
    await storeReport(env.DB, report(at, ["10000001", "10000002", "10000003", "10000004"]), at);
    const cutoff = utcDay(NOW - 90 * DAY_MS);
    const limits = { ...DEFAULT_FOLD_LIMITS, chunkRows: 1, maxChunks: 3 };

    expect(await foldExpiredReports(env.DB, cutoff, limits)).toMatchObject({ folded: 3, chunks: 3, stoppedAtLimit: true });
    expect(await rows("SELECT count(*) AS n FROM reports")).toEqual([{ n: 1 }]);
    expect(await foldExpiredReports(env.DB, cutoff, limits)).toMatchObject({ folded: 1, chunks: 1 });
    expect(await rows("SELECT sum(count) AS n FROM transition_counts")).toEqual([{ n: 8 }]);
  });

  it("starts no new chunk once the run has written its share of rows", async () => {
    const at = Date.UTC(2026, 6, 1, 0, 0);
    await storeReport(env.DB, report(at, ["10000001", "10000002", "10000003"]), at);
    const cutoff = utcDay(NOW - 90 * DAY_MS);
    const result = await foldExpiredReports(env.DB, cutoff, { ...DEFAULT_FOLD_LIMITS, chunkRows: 1, maxRowsWritten: 1 });
    expect(result).toMatchObject({ folded: 1, chunks: 1, stoppedAtLimit: true });
    expect(await rows("SELECT count(*) AS n FROM reports")).toEqual([{ n: 2 }]);
  });

  it("uses at most 43 D1 queries per run, within the Free plan's 50 per invocation", async () => {
    expect(maxCronQueries()).toBe(43);
    // A backlog bigger than one run: with one row per chunk the run stops at maxChunks.
    const at = Date.UTC(2026, 6, 1, 0, 0);
    const ids = Array.from({ length: DEFAULT_FOLD_LIMITS.maxChunks + 5 }, (_, i) => (0x50000000 + i).toString(16).toUpperCase());
    await storeReport(env.DB, report(at, ids), at);
    const { db, meter } = meteredDatabase();
    const limits = { ...DEFAULT_CRON_LIMITS, fold: { ...DEFAULT_FOLD_LIMITS, chunkRows: 1 } };
    const result = await runDailyJobs(db, NOW, 90, limits);
    expect(result.fold).toMatchObject({ folded: DEFAULT_FOLD_LIMITS.maxChunks, stoppedAtLimit: true });
    expect(meter.queries).toBe(maxCronQueries(limits));
    expect(meter.queries).toBeLessThanOrEqual(50);
    expect(result.rowsWritten).toBe(meter.rowsWritten);
  });

  it("deletes usage counters older than a week", async () => {
    for (const daysAgo of [8, 7, 0]) {
      const day = utcDay(NOW - daysAgo * DAY_MS);
      await env.DB.prepare("INSERT INTO daily_usage (day, rows_written, stored_bytes) VALUES (?1, 1, 1)").bind(day).run();
    }
    await runCron();
    expect(await usage(utcDay(NOW - 8 * DAY_MS))).toBeNull();
    expect(await usage(utcDay(NOW - 7 * DAY_MS))).not.toBeNull();
    expect(await usage(utcDay(NOW))).not.toBeNull();
  });

  it("honours RETENTION_DAYS", async () => {
    const shortRetention = await createContext({ RETENTION_DAYS: "1" });
    shortRetention.clock.ms = NOW;
    await storeReport(env.DB, report(NOW - 2 * DAY_MS), NOW - 2 * DAY_MS);
    await storeReport(env.DB, report(NOW - DAY_MS), NOW - DAY_MS);
    await shortRetention.app.scheduled(createScheduledController(), shortRetention.env, createExecutionContext());
    expect(await rows("SELECT received_day FROM reports")).toEqual([{ received_day: "2026-11-09" }]);
  });
});

async function insertKey(id: string, lastUsedDay: string): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO attest_keys (key_id, public_key, sign_count, environment, created_day, last_used_day)
     VALUES (?1, '04', 0, 'production', '2026-01-01', ?2)`,
  )
    .bind(id, lastUsedDay)
    .run();
}

async function keyIds(): Promise<string[]> {
  return (await rows("SELECT key_id FROM attest_keys ORDER BY key_id")).map((row) => row.key_id as string);
}

/** Runs challenge + assertion against /v1/token for a registered key. */
async function refresh(ctx: TestContext, key: RegisteredKey, counter: number): Promise<Response> {
  const challenge = await getChallenge(ctx);
  const assertion = await buildAssertion({ privateKey: key.credentialKey.privateKey, challenge, appId: APP_ID, counter });
  return ctx.fetch(postJson("/v1/token", { keyId: encodeBase64(key.keyId), assertion: encodeBase64(assertion), challenge }));
}

describe("App Attest key retention", () => {
  it("deletes keys not used for 30 days and keeps the others", async () => {
    expect(KEY_RETENTION_DAYS).toBe(30);
    await insertKey("a-31-days", utcDay(NOW - 31 * DAY_MS));
    await insertKey("b-30-days", utcDay(NOW - 30 * DAY_MS));
    await insertKey("c-today", utcDay(NOW));
    // Inserted during a deploy by the previous version, which did not set the column.
    await insertKey("d-never", "");

    const { db, meter } = meteredDatabase();
    const result = await runDailyJobs(db, NOW, 90);

    expect(await keyIds()).toEqual(["b-30-days", "c-today"]);
    expect(result.deletedKeys).toBe(2);
    // One row written per deleted key (the table has no secondary index).
    expect(result.rowsWritten).toBe(meter.rowsWritten);
  });

  it("keeps a key that is still used, and answers 404 unknown_key once it was deleted", async () => {
    const key = await registerKey(context);
    const registeredDay = utcDay(context.clock.ms);
    expect(await rows("SELECT created_day, last_used_day FROM attest_keys")).toEqual([
      { created_day: registeredDay, last_used_day: registeredDay },
    ]);

    // 20 days later the app refreshes its token, which records the day of use.
    context.clock.advance(20 * 86_400);
    expect((await refresh(context, key, 1)).status).toBe(200);
    expect(await rows("SELECT created_day, last_used_day FROM attest_keys")).toEqual([
      { created_day: registeredDay, last_used_day: utcDay(context.clock.ms) },
    ]);

    // 40 days after registration: last used 20 days ago, so it stays.
    context.clock.advance(20 * 86_400);
    await runCronAt(context.clock.ms);
    expect(await rows("SELECT count(*) AS n FROM attest_keys")).toEqual([{ n: 1 }]);

    // 52 days after registration: unused for 32 days, so the cron deletes it.
    context.clock.advance(12 * 86_400);
    await runCronAt(context.clock.ms);
    expect(await rows("SELECT count(*) AS n FROM attest_keys")).toEqual([{ n: 0 }]);

    // The app gets the usual answer for an unknown key and attests a new one.
    const response = await refresh(context, key, 2);
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "unknown_key" });
    await registerKey(context);
    expect(await rows("SELECT count(*) AS n FROM attest_keys")).toEqual([{ n: 1 }]);
  });

  it("deletes at most keyDeleteLimit keys per run and leaves the rest for the next one", async () => {
    for (const id of ["k1", "k2", "k3"]) await insertKey(id, utcDay(NOW - 60 * DAY_MS));
    const limits = { ...DEFAULT_CRON_LIMITS, keyDeleteLimit: 2 };
    expect((await runDailyJobs(env.DB, NOW, 90, limits)).deletedKeys).toBe(2);
    expect(await keyIds()).toHaveLength(1);
    expect((await runDailyJobs(env.DB, NOW, 90, limits)).deletedKeys).toBe(1);
    expect(await keyIds()).toEqual([]);
  });
});

async function runCronAt(ms: number): Promise<void> {
  const at = await createContext();
  at.clock.ms = ms;
  await at.app.scheduled(createScheduledController({ cron: "0 18 * * *" }), at.env, createExecutionContext());
}

describe("service_state", () => {
  it("records what the last successful run did, without personal data", async () => {
    const expiredAt = Date.UTC(2026, 7, 1, 0, 30);
    await storeReport(env.DB, report(expiredAt, ["10000001", "10000002"]), expiredAt);
    await insertKey("old-key", utcDay(NOW - 40 * DAY_MS));
    const { db, meter } = meteredDatabase();
    const result = await runDailyJobs(db, NOW, 90);

    const state = await rows("SELECT * FROM service_state");
    expect(state).toEqual([
      {
        id: 1,
        cron_last_success: "2026-11-10T18:00:00Z",
        folded_reports: 2,
        backlog: 0,
        deleted_keys: 1,
        rows_written: meter.rowsWritten,
        database_bytes: result.databaseBytes,
      },
    ]);
    expect(result.databaseBytes).toBeGreaterThan(0);
    expect(Object.keys(state[0]!)).toEqual([
      "id",
      "cron_last_success",
      "folded_reports",
      "backlog",
      "deleted_keys",
      "rows_written",
      "database_bytes",
    ]);
  });

  it("keeps a single row and flags a backlog", async () => {
    const at = Date.UTC(2026, 6, 1, 0, 0);
    await storeReport(env.DB, report(at, ["10000001", "10000002", "10000003"]), at);
    const limits = { ...DEFAULT_CRON_LIMITS, fold: { ...DEFAULT_FOLD_LIMITS, chunkRows: 1, maxChunks: 2 } };
    await runDailyJobs(env.DB, NOW, 90, limits);
    expect(await rows("SELECT folded_reports, backlog FROM service_state")).toEqual([{ folded_reports: 2, backlog: 1 }]);
    await runDailyJobs(env.DB, NOW + DAY_MS, 90, limits);
    expect(await rows("SELECT cron_last_success, folded_reports, backlog FROM service_state")).toEqual([
      { cron_last_success: "2026-11-11T18:00:00Z", folded_reports: 1, backlog: 0 },
    ]);
  });

  it("is not updated when a step fails", async () => {
    await runDailyJobs(env.DB, NOW, 90);
    const failing = new Proxy(env.DB, {
      get(target, property) {
        if (property === "prepare") {
          return (query: string) => {
            if (query.includes("DELETE FROM attest_keys")) throw new Error("D1 is down");
            return target.prepare(query);
          };
        }
        const value: unknown = Reflect.get(target, property, target);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    await expect(runDailyJobs(failing, NOW + DAY_MS, 90)).rejects.toThrow("D1 is down");
    expect(await rows("SELECT cron_last_success FROM service_state")).toEqual([
      { cron_last_success: "2026-11-10T18:00:00Z" },
    ]);
  });
});
