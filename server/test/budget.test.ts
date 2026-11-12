// SPDX-License-Identifier: Apache-2.0

import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { runDailyJobs } from "../src/cron";
import { encodeBase64 } from "../src/encoding";
import { KEY_WRITE_COST } from "../src/keys";
import { validateReport, type Report } from "../src/report";
import { reportPayloads, reportWriteCost, rowStorageBytes, storeReport, utcDay } from "../src/storage";
import { buildAssertion } from "./helpers/appattest";
import {
  APP_ID,
  BASE,
  createContext,
  exampleReport,
  exampleReport4,
  getChallenge,
  makeToken,
  meteredDatabase,
  postJson,
  registerKey,
  reportRequest,
  resetDatabase,
  usage,
  type TestContext,
} from "./helpers/context";

let context: TestContext;

beforeEach(async () => {
  await resetDatabase();
  context = await createContext();
});

async function count(table: string): Promise<unknown> {
  return env.DB.prepare(`SELECT count(*) AS n FROM ${table}`).first("n");
}

async function expectOverCapacity(response: Response): Promise<void> {
  expect(response.status).toBe(503);
  expect(await response.json()).toEqual({ error: "over_capacity" });
}

/** A valid report with `n` intersections. */
function reportWith(n: number, nowSeconds: number) {
  const base = exampleReport(nowSeconds);
  const template = base.intersections[0]!;
  return {
    ...base,
    intersections: Array.from({ length: n }, (_, i) => {
      const id = (0x30000000 + i).toString(16).toUpperCase();
      return {
        ...template,
        id,
        observations: template.observations.map((o) => ({ ...o, raw: `CE010000022A0000${id}311384848484` })),
      };
    }),
  };
}

/** The estimated bytes the report's rows take (payload, other columns, index, page space). */
function storedBytes(body: ReturnType<typeof reportWith>): number {
  return reportWriteCost(reportPayloads(body as never)).storedBytes;
}

function validated(body: unknown, nowSeconds: number): Report {
  const result = validateReport(body, nowSeconds);
  if (!result.ok) throw new Error(result.reason);
  return result.report;
}

async function databaseSize(): Promise<number> {
  return (await env.DB.prepare("SELECT 1").all()).meta.size_after;
}

describe("daily write budget", () => {
  it("counts each report's rows (table, index and counter) and stored bytes", async () => {
    const { token } = await makeToken(context);
    const body = reportWith(3, context.clock.seconds);
    expect((await context.fetch(reportRequest(token, body))).status).toBe(202);
    expect((await context.fetch(reportRequest(token, body))).status).toBe(202);
    const payloads = reportPayloads(body as never);
    expect(storedBytes(body)).toBe(payloads.reduce((sum, payload) => sum + rowStorageBytes(payload.length), 0));
    expect(storedBytes(body)).toBeGreaterThan(payloads.reduce((sum, payload) => sum + payload.length, 0) + 3 * 499);
    expect(await usage(utcDay(context.clock.ms))).toEqual({
      rows_written: 2 * (3 * 2 + 1),
      stored_bytes: 2 * storedBytes(body),
    });
  });

  it("counts exactly the rows D1 reports as written, for every write path", async () => {
    const { db, meter } = meteredDatabase();
    const metered = await createContext({ DB: db });
    const day = utcDay(metered.clock.ms);

    const key = await registerKey(metered);
    expect(await usage(day)).toEqual({ rows_written: meter.rowsWritten, stored_bytes: KEY_WRITE_COST.storedBytes });

    const before = meter.rowsWritten;
    const challenge = await getChallenge(metered);
    const assertion = await buildAssertion({ privateKey: key.credentialKey.privateKey, challenge, appId: APP_ID, counter: 1 });
    const refreshed = await metered.fetch(
      postJson("/v1/token", { keyId: encodeBase64(key.keyId), assertion: encodeBase64(assertion), challenge }),
    );
    expect(refreshed.status).toBe(200);
    // The refresh also records the day of use, in the same row update.
    expect(meter.rowsWritten - before).toBe(2);

    const body = reportWith(3, metered.clock.seconds);
    expect((await metered.fetch(reportRequest(key.token, body))).status).toBe(202);
    expect((await usage(day))?.rows_written).toBe(meter.rowsWritten);
  });

  it("counts the timing index of schema 4 rows with clock_ok = 1, exactly as D1 reports it", async () => {
    const { db, meter } = meteredDatabase();
    const metered = await createContext({ DB: db });
    const day = utcDay(metered.clock.ms);
    const { token } = await makeToken(metered);
    const report = (sentAt: number) => {
      const body = exampleReport4(metered.clock.seconds);
      const second = { ...body.intersections[0]!, id: "0000FFFF", observations: [] };
      return { ...body, sentAt, intersections: [body.intersections[0]!, second] };
    };

    // clock_ok = 1: table, received_day index and timing index per row, plus the counter.
    expect((await metered.fetch(reportRequest(token, report(metered.clock.ms)))).status).toBe(202);
    const payloads = reportPayloads(validated(report(metered.clock.ms), metered.clock.seconds));
    expect(await usage(day)).toEqual({ rows_written: 2 * 3 + 1, stored_bytes: reportWriteCost(payloads, 1).storedBytes });
    expect(meter.rowsWritten).toBe(2 * 3 + 1);

    // clock_ok = 0: not in the timing index.
    expect((await metered.fetch(reportRequest(token, report(metered.clock.ms + 60_000)))).status).toBe(202);
    expect((await usage(day))?.rows_written).toBe(2 * 3 + 1 + 2 * 2 + 1);
    expect((await usage(day))?.rows_written).toBe(meter.rowsWritten);
  });

  it("refuses reports with 503 over_capacity once the day's rows are used, and stores nothing", async () => {
    // One report with 3 intersections costs 7 rows.
    const limited = await createContext({ DAILY_WRITE_LIMIT: "10" });
    const { token } = await makeToken(limited);
    const body = reportWith(3, limited.clock.seconds);
    expect((await limited.fetch(reportRequest(token, body))).status).toBe(202);
    await expectOverCapacity(await limited.fetch(reportRequest(token, body)));
    expect(await count("reports")).toBe(3);
    expect(await usage(utcDay(limited.clock.ms))).toMatchObject({ rows_written: 7 });

    // A smaller report still fits: 1 intersection costs 3 rows.
    expect((await limited.fetch(reportRequest(token, reportWith(1, limited.clock.seconds)))).status).toBe(202);
    expect(await usage(utcDay(limited.clock.ms))).toMatchObject({ rows_written: 10 });
  });

  it("refuses a single report larger than the whole budget", async () => {
    const limited = await createContext({ DAILY_WRITE_LIMIT: "6" });
    const { token } = await makeToken(limited);
    await expectOverCapacity(await limited.fetch(reportRequest(token, reportWith(3, limited.clock.seconds))));
    expect(await count("daily_usage")).toBe(0);
  });

  it("limits the estimated bytes stored per day", async () => {
    const body = reportWith(1, context.clock.seconds);
    const limited = await createContext({ DAILY_STORAGE_LIMIT_BYTES: String(storedBytes(body) * 2) });
    const { token } = await makeToken(limited);
    expect((await limited.fetch(reportRequest(token, body))).status).toBe(202);
    expect((await limited.fetch(reportRequest(token, body))).status).toBe(202);
    await expectOverCapacity(await limited.fetch(reportRequest(token, body)));
    expect(await count("reports")).toBe(2);
  });

  it("starts again on the next UTC day", async () => {
    const limited = await createContext({ DAILY_WRITE_LIMIT: "3" });
    const { token } = await makeToken(limited, { expiresIn: 3 * 86_400 });
    expect((await limited.fetch(reportRequest(token, reportWith(1, limited.clock.seconds)))).status).toBe(202);
    await expectOverCapacity(await limited.fetch(reportRequest(token, reportWith(1, limited.clock.seconds))));
    limited.clock.ms = Date.UTC(...nextUtcDay(limited.clock.ms));
    expect((await limited.fetch(reportRequest(token, reportWith(1, limited.clock.seconds)))).status).toBe(202);
  });

  it("refuses new writes once the database is larger than MAX_DATABASE_BYTES", async () => {
    const limited = await createContext({ MAX_DATABASE_BYTES: "1" });
    const { token } = await makeToken(limited);
    await expectOverCapacity(await limited.fetch(reportRequest(token, reportWith(1, limited.clock.seconds))));
    expect(await count("reports")).toBe(0);
  });

  it("measures pages in use, so writes resume by themselves once the cron has deleted old rows", async () => {
    // About 2 MB of expired report rows (100 days old).
    const oldMs = context.clock.ms - 100 * 86_400_000;
    const observation = { t: Math.floor(oldMs / 1000), raw: "CE010000022A00004000000031138484", rssi: -70, bearing: 3, heading: null };
    const old: Report = {
      schema: 1,
      client: "aoshingo-ios/0.1.0",
      intersections: Array.from({ length: 40 }, (_, i) => ({
        id: (0x40000000 + i).toString(16).toUpperCase(),
        serviceUUIDs: [],
        emitters: 1,
        observations: Array(500).fill(observation),
        transitions: [],
      })),
    };
    const empty = await databaseSize();
    await storeReport(env.DB, old, oldMs);
    const full = await databaseSize();
    expect(full - empty).toBeGreaterThan(1_500_000);

    const limited = await createContext({ MAX_DATABASE_BYTES: String(Math.round((empty + full) / 2)) });
    const { token } = await makeToken(limited);
    const body = reportWith(1, limited.clock.seconds);
    await expectOverCapacity(await limited.fetch(reportRequest(token, body)));
    await expectOverCapacity(await limited.fetch(new Request(`${BASE}/v1/challenge`, { method: "POST" })));

    const run = await runDailyJobs(env.DB, limited.clock.ms, 90);
    expect(run.fold.folded).toBe(40);
    expect(run.databaseBytes).toBeLessThan(Math.round((empty + full) / 2));
    expect(await databaseSize()).toBeLessThan(empty + 100_000);

    expect((await limited.fetch(new Request(`${BASE}/v1/challenge`, { method: "POST" }))).status).toBe(201);
    expect((await limited.fetch(reportRequest(token, body))).status).toBe(202);
  });

  it("covers /v1/attest and /v1/token, after their verification", async () => {
    const key = await registerKey(context);
    expect(await usage(utcDay(context.clock.ms))).toEqual({ rows_written: 2, stored_bytes: 300 });

    const full = await createContext({ DAILY_WRITE_LIMIT: "2" });
    full.clock.ms = context.clock.ms;
    // A full budget already refuses new challenges (test/challenge.test.ts); this one was issued
    // before the budget ran out.
    const challenge = await getChallenge(context);
    const assertion = await buildAssertion({ privateKey: key.credentialKey.privateKey, challenge, appId: APP_ID, counter: 1 });
    await expectOverCapacity(
      await full.fetch(postJson("/v1/token", { keyId: encodeBase64(key.keyId), assertion: encodeBase64(assertion), challenge })),
    );
    // The counter is unchanged, so the client can retry with the same counter later.
    expect(
      await env.DB.prepare("SELECT sign_count FROM attest_keys").first("sign_count"),
    ).toBe(0);
    await expectOverCapacity(await full.fetch(new Request(`${BASE}/v1/challenge`, { method: "POST" })));
  });
});

function nextUtcDay(ms: number): [number, number, number, number] {
  const date = new Date(ms);
  return [date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() + 1, 1];
}
