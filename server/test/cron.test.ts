// SPDX-License-Identifier: Apache-2.0

import { createExecutionContext, createScheduledController } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import type { Report } from "../src/report";
import { DEFAULT_FOLD_LIMITS, foldExpiredReports, storeReport, utcDay } from "../src/storage";
import { createContext, resetDatabase, usage, type TestContext } from "./helpers/context";

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

  it("uses at most 41 D1 queries, within the Free plan's 50 per invocation", () => {
    expect(1 + 2 * DEFAULT_FOLD_LIMITS.maxChunks).toBeLessThanOrEqual(41);
  });

  it("deletes usage counters older than a week", async () => {
    for (const daysAgo of [8, 7, 0]) {
      const day = utcDay(NOW - daysAgo * DAY_MS);
      await env.DB.prepare("INSERT INTO daily_usage (day, rows_written, payload_bytes) VALUES (?1, 1, 1)").bind(day).run();
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
