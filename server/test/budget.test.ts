// SPDX-License-Identifier: Apache-2.0

import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { encodeBase64 } from "../src/encoding";
import { reportPayloads, utcDay } from "../src/storage";
import { buildAssertion } from "./helpers/appattest";
import {
  APP_ID,
  createContext,
  exampleReport,
  getChallenge,
  makeToken,
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

function payloadBytes(body: ReturnType<typeof reportWith>): number {
  return reportPayloads(body as never).reduce((sum, payload) => sum + payload.length, 0);
}

describe("daily write budget", () => {
  it("counts each report's rows (table, index and counter) and payload bytes", async () => {
    const { token } = await makeToken(context);
    const body = reportWith(3, context.clock.seconds);
    expect((await context.fetch(reportRequest(token, body))).status).toBe(202);
    expect((await context.fetch(reportRequest(token, body))).status).toBe(202);
    expect(await usage(utcDay(context.clock.ms))).toEqual({
      rows_written: 2 * (3 * 2 + 1),
      payload_bytes: 2 * payloadBytes(body),
    });
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

  it("limits the payload bytes stored per day", async () => {
    const body = reportWith(1, context.clock.seconds);
    const limited = await createContext({ DAILY_PAYLOAD_LIMIT_BYTES: String(payloadBytes(body) * 2) });
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

  it("covers /v1/attest and /v1/token, after their verification", async () => {
    const key = await registerKey(context);
    expect(await usage(utcDay(context.clock.ms))).toEqual({ rows_written: 2, payload_bytes: 0 });

    const full = await createContext({ DAILY_WRITE_LIMIT: "2" });
    full.clock.ms = context.clock.ms;
    const challenge = await getChallenge(full);
    const assertion = await buildAssertion({ privateKey: key.credentialKey.privateKey, challenge, appId: APP_ID, counter: 1 });
    await expectOverCapacity(
      await full.fetch(postJson("/v1/token", { keyId: encodeBase64(key.keyId), assertion: encodeBase64(assertion), challenge })),
    );
    // The counter is unchanged, so the client can retry with the same counter later.
    expect(
      await env.DB.prepare("SELECT sign_count FROM attest_keys").first("sign_count"),
    ).toBe(0);
  });
});

function nextUtcDay(ms: number): [number, number, number, number] {
  const date = new Date(ms);
  return [date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() + 1, 1];
}
