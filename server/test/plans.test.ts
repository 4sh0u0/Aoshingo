// SPDX-License-Identifier: Apache-2.0

// GET /v1/plans (docs/timing-estimation.md, "GET /v1/plans").

import { createExecutionContext, createScheduledController } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { DEFAULT_TIMING_LIMITS, runTimingJob, type TimingLimits } from "../src/timing";
import {
  BASE,
  createContext,
  makeToken,
  meteredDatabase,
  reportRequest,
  resetDatabase,
  tokenId,
  type TestContext,
} from "./helpers/context";

let context: TestContext;
let token: string;

beforeEach(async () => {
  await resetDatabase();
  context = await createContext();
  token = (await makeToken(context)).token;
});

function getPlans(query = "", headers: Record<string, string> = { authorization: `Bearer ${token}` }): Request {
  return new Request(`${BASE}/v1/plans${query}`, { headers });
}

const PLAN_SQL = `INSERT INTO timing_plans
  (intersection_id, slot, day_type, bin, cycle_ms, reference, phase_ms, spread_ms, green_ms, blink_ms, last_day, updated_day)
  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, '2026-11-11')`;

type PlanValues = [
  id: string,
  slot: number,
  dayType: number,
  bin: number,
  cycle: number,
  reference: string,
  phase: number,
  spread: number,
  green: number | null,
  blink: number | null,
  lastDay: string,
];

// Saturday 2026-11-14 18:30 UTC, when the timing cron builds the snapshot.
const BUILT_AT = Date.UTC(2026, 10, 14, 18, 30);

/** Stores plans and places, and lets the timing cron build the snapshot from them. */
async function seed(limits?: TimingLimits): Promise<void> {
  const plans: PlanValues[] = [
    // Inserted out of order on purpose.
    ["1234ABCD", 2, 0, 14, 90_000, "midnight", 100, 0, null, null, "2026-11-09"],
    ["1234ABCD", 1, 1, 3, 120_000, "epoch", 37_400, 1_800, 24_000, 6_000, "2026-11-08"],
    ["1234ABCD", 1, 0, 15, 120_000, "epoch", 1_000, 200, 24_100, null, "2026-11-10"],
    ["1234ABCD", 1, 0, 14, 120_000, "epoch", 37_400, 1_800, 24_000, 6_000, "2026-11-10"],
    ["0000FFFF", 6, 2, 47, 300_000, "epoch", 299_999, 3_000, null, 6_000, "2026-11-01"],
  ];
  await env.DB.batch([
    ...plans.map((values) => env.DB.prepare(PLAN_SQL).bind(...values)),
    env.DB.prepare("INSERT INTO timing_places VALUES ('1234ABCD', 'CE0100000000AA', 'CE0100000100BB', '2026-11-11')"),
    // A fitted intersection without plans.
    env.DB.prepare("INSERT INTO timing_places VALUES ('ABCDEF01', 'CE01NAME', 'CE01POS', '2026-11-11')"),
  ]);
  await runTimingJob(env.DB, BUILT_AT, limits);
}

// Neither the day and report counts nor any date of the plans.
const PLAN_1234 = [
  { slot: 1, dayType: 0, bin: 14, cycle: 120_000, reference: "epoch", phase: 37_400, spread: 1_800, green: 24_000, blink: 6_000 },
  { slot: 1, dayType: 0, bin: 15, cycle: 120_000, reference: "epoch", phase: 1_000, spread: 200, green: 24_100, blink: null },
  { slot: 1, dayType: 1, bin: 3, cycle: 120_000, reference: "epoch", phase: 37_400, spread: 1_800, green: 24_000, blink: 6_000 },
  { slot: 2, dayType: 0, bin: 14, cycle: 90_000, reference: "midnight", phase: 100, spread: 0, green: null, blink: null },
];

const INTERSECTION_0000 = {
  id: "0000FFFF",
  name: null,
  position: null,
  plans: [
    { slot: 6, dayType: 2, bin: 47, cycle: 300_000, reference: "epoch", phase: 299_999, spread: 3_000, green: null, blink: 6_000 },
  ],
};

const INTERSECTION_1234 = { id: "1234ABCD", name: "CE0100000000AA", position: "CE0100000100BB", plans: PLAN_1234 };

const BODY = JSON.stringify({ generated: "2026-11-14", intersections: [INTERSECTION_0000, INTERSECTION_1234] });

describe("GET /v1/plans", () => {
  it("returns every intersection with plans, sorted, in the documented format", async () => {
    await seed();
    const response = await context.fetch(getPlans());
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(response.headers.get("cache-control")).toBe("private, max-age=3600");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    // The exact text: field order as documented.
    expect(await response.text()).toBe(BODY);
  });

  it("joins the snapshot's chunks into the same body", async () => {
    // A chunk for every intersection.
    await seed({ ...DEFAULT_TIMING_LIMITS, snapshotChunkBytes: 1 });
    expect(await env.DB.prepare("SELECT count(*) AS n FROM timing_snapshot").first("n")).toBe(2);
    expect(await (await context.fetch(getPlans())).text()).toBe(BODY);
  });

  it("serves the snapshot of the last run until the next one, not the plans as they are now", async () => {
    await seed();
    await env.DB.prepare("DELETE FROM timing_plans WHERE intersection_id = '0000FFFF'").run();
    expect(await (await context.fetch(getPlans())).text()).toBe(BODY);
    await runTimingJob(env.DB, BUILT_AT + 86_400_000);
    expect(await (await context.fetch(getPlans())).json()).toEqual({ generated: "2026-11-15", intersections: [INTERSECTION_1234] });
  });

  it("returns an empty list with the day of the last run when there are no plans", async () => {
    await env.DB.prepare("INSERT INTO timing_places VALUES ('ABCDEF01', NULL, NULL, '2026-11-11')").run();
    await runTimingJob(env.DB, BUILT_AT);
    const response = await context.fetch(getPlans());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("private, max-age=3600");
    expect(await response.text()).toBe('{"generated":"2026-11-14","intersections":[]}');
  });

  it("returns generated null and an empty list before the first run", async () => {
    // Plans without a snapshot are not served.
    await env.DB.prepare(PLAN_SQL).bind("1234ABCD", 1, 0, 14, 120_000, "epoch", 0, 0, null, null, "2026-11-10").run();
    const response = await context.fetch(getPlans());
    expect(response.status).toBe(200);
    expect(await response.text()).toBe('{"generated":null,"intersections":[]}');
  });

  it("answers 400 bad_request for any query, ids included", async () => {
    await seed();
    for (const query of ["?ids=1234ABCD", "?ids=1234ABCD,0000FFFF", "?ids=", "?ids", "?v=2", "?=", "?&"]) {
      const response = await context.fetch(getPlans(query));
      expect(response.status, query).toBe(400);
      expect(await response.json(), query).toEqual({ error: "bad_request" });
      expect(response.headers.get("cache-control"), query).toBe("no-store");
    }
    // A bare "?" is no query.
    expect(await (await context.fetch(getPlans("?"))).text()).toBe(BODY);
  });

  it("requires a valid upload token", async () => {
    await seed();
    const expired = await makeToken(context, { expiresIn: 0 });
    const tampered = token.slice(0, 10) + (token[10] === "A" ? "B" : "A") + token.slice(11);
    for (const headers of [
      {},
      { authorization: token },
      { authorization: `Basic ${token}` },
      { authorization: `Bearer ${expired.token}` },
      { authorization: `Bearer ${tampered}` },
    ] as Record<string, string>[]) {
      const response = await context.fetch(getPlans("", headers));
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "invalid_token" });
    }
    // Checked before the query.
    expect((await context.fetch(getPlans("?ids=bad", {}))).status).toBe(401);
    expect(context.reportsLimiter.keys).toEqual([]);
  });

  it("refuses development tokens unless development is allowed", async () => {
    await seed();
    const { token: development } = await makeToken(context, { environment: "development" });
    const request = () => getPlans("", { authorization: `Bearer ${development}` });
    expect((await context.fetch(request())).status).toBe(401);
    const allowed = await createContext({ ALLOW_DEVELOPMENT_ATTESTATION: "true" });
    expect((await allowed.fetch(request())).status).toBe(200);
  });

  it("is rate limited per token with the reports limiter, under its own key", async () => {
    const response = await context.fetch(getPlans());
    expect(response.status).toBe(200);
    context.reportsLimiter.allow = false;
    const limited = await context.fetch(getPlans());
    expect(limited.status).toBe(429);
    expect(await limited.json()).toEqual({ error: "rate_limited" });
    expect(context.reportsLimiter.keys).toEqual([`plans:${tokenId(token)}`, `plans:${tokenId(token)}`]);
    expect(context.authLimiter.keys).toEqual([]);
  });

  it("only reads one row per chunk: no D1 write, no budget", async () => {
    await seed({ ...DEFAULT_TIMING_LIMITS, snapshotChunkBytes: 1 });
    const { db, meter } = meteredDatabase();
    let rowsRead = 0;
    const counting = new Proxy(db, {
      get(target, property) {
        if (property !== "prepare") return Reflect.get(target, property, target);
        return (query: string) => {
          const statement = target.prepare(query);
          return new Proxy(statement, {
            get(inner, name) {
              if (name !== "all") return Reflect.get(inner, name, inner);
              return async () => {
                const result = await inner.all();
                rowsRead += result.meta.rows_read ?? 0;
                return result;
              };
            },
          });
        };
      },
    });
    const metered = await createContext({ DB: counting, DAILY_WRITE_LIMIT: "1" });
    const { token: fresh } = await makeToken(metered);
    const response = await metered.fetch(getPlans("", { authorization: `Bearer ${fresh}` }));
    expect(await response.text()).toBe(BODY);
    expect(meter).toEqual({ queries: 1, rowsWritten: 0 });
    expect(rowsRead).toBe(2);
    expect(await env.DB.prepare("SELECT count(*) AS n FROM daily_usage").first("n")).toBe(0);
  });

  it("accepts only GET", async () => {
    const request = new Request(`${BASE}/v1/plans`, { method: "POST", headers: { authorization: `Bearer ${token}` } });
    const response = await context.fetch(request);
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("GET");
  });

  it("serves the plan fitted from reports sent through the API", async () => {
    // A 120 s signal (green at Unix time ≡ 37.4 s mod 120 s) seen on seven weekday mornings
    // (07:00-07:10 JST), each sent a minute after the last change.
    const id = "1234ABCD";
    for (const day of [10, 11, 12, 13, 16, 17, 18]) {
      const start = Date.UTC(2026, 10, day - 1, 22, 0); // 07:00 JST
      const transitions = [];
      for (let at = start + 37_400; at < start + 600_000; at += 120_000) {
        transitions.push({ t: Math.floor(at / 1000), ms: at % 1000, slot: 1, from: "Red", to: "Green", cycle: 120_000 });
        transitions.push({ t: Math.floor(at / 1000) + 30, ms: at % 1000, slot: 1, from: "Green", to: "BlinkGreen", held: 30_000 });
      }
      context.clock.ms = start + 600_000 + 60_000;
      const observations = [
        { t: context.clock.seconds - 30, raw: `CE0100000029000012ABCDEF`.replace("12ABCDEF", id).padEnd(52, "0") },
        { t: context.clock.seconds - 20, raw: `CE0100000129000012ABCDEF`.replace("12ABCDEF", id).padEnd(40, "1") },
      ];
      const body = {
        schema: 4,
        sentAt: context.clock.ms - 150,
        client: "aoshingo-ios/0.3.0",
        intersections: [{ id, serviceUUIDs: [], emitters: 0, observations, transitions }],
      };
      const { token: daily } = await makeToken(context);
      const response = await context.fetch(reportRequest(daily, body));
      expect(response.status, await response.clone().text()).toBe(202);
    }
    expect(await env.DB.prepare("SELECT DISTINCT clock_ok FROM reports").all()).toMatchObject({ results: [{ clock_ok: 1 }] });

    // Friday 18:30 UTC.
    context.clock.ms = Date.UTC(2026, 10, 20, 18, 30);
    await context.app.scheduled(createScheduledController({ cron: "30 18 * * *" }), context.env, createExecutionContext());
    const { token: reader } = await makeToken(context);
    const response = await context.fetch(getPlans("", { authorization: `Bearer ${reader}` }));
    expect(await response.json()).toEqual({
      generated: "2026-11-20",
      intersections: [
        {
          id,
          name: `CE01000000290000${id}`.padEnd(52, "0"),
          position: `CE01000001290000${id}`.padEnd(40, "1"),
          plans: [
            { slot: 1, dayType: 0, bin: 14, cycle: 120_000, reference: "epoch", phase: 37_400, spread: 0, green: 30_000, blink: null },
          ],
        },
      ],
    });
  });
});
