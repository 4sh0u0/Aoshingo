// SPDX-License-Identifier: Apache-2.0

// GET /v1/plans (docs/timing-estimation.md, "GET /v1/plans").

import { createExecutionContext, createScheduledController } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
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
  (intersection_id, slot, day_type, bin, cycle_ms, reference, phase_ms, spread_ms, green_ms, blink_ms, days, reports,
   last_day, updated_day)
  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, '2026-11-11')`;

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
  days: number,
  reports: number,
  lastDay: string,
];

async function seed(): Promise<void> {
  const plans: PlanValues[] = [
    // Inserted out of order on purpose.
    ["1234ABCD", 2, 0, 14, 90_000, "midnight", 100, 0, null, null, 3, 2, "2026-11-09"],
    ["1234ABCD", 1, 1, 3, 120_000, "epoch", 37_400, 1_800, 24_000, 6_000, 4, 5, "2026-11-08"],
    ["1234ABCD", 1, 0, 15, 120_000, "epoch", 1_000, 200, 24_100, null, 5, 6, "2026-11-10"],
    ["1234ABCD", 1, 0, 14, 120_000, "epoch", 37_400, 1_800, 24_000, 6_000, 4, 5, "2026-11-10"],
    ["0000FFFF", 6, 2, 47, 300_000, "epoch", 299_999, 3_000, null, 6_000, 3, 2, "2026-11-01"],
  ];
  await env.DB.batch([
    ...plans.map((values) => env.DB.prepare(PLAN_SQL).bind(...values)),
    env.DB.prepare("INSERT INTO timing_places VALUES ('1234ABCD', 'CE0100000000AA', 'CE0100000100BB', '2026-11-11')"),
    // A fitted intersection without plans, and one with only a name.
    env.DB.prepare("INSERT INTO timing_places VALUES ('ABCDEF01', 'CE01NAME', 'CE01POS', '2026-11-11')"),
  ]);
}

const PLAN_1234 = [
  {
    slot: 1, dayType: 0, bin: 14, cycle: 120_000, reference: "epoch", phase: 37_400, spread: 1_800,
    green: 24_000, blink: 6_000, days: 4, reports: 5, lastDay: "2026-11-10",
  },
  {
    slot: 1, dayType: 0, bin: 15, cycle: 120_000, reference: "epoch", phase: 1_000, spread: 200,
    green: 24_100, blink: null, days: 5, reports: 6, lastDay: "2026-11-10",
  },
  {
    slot: 1, dayType: 1, bin: 3, cycle: 120_000, reference: "epoch", phase: 37_400, spread: 1_800,
    green: 24_000, blink: 6_000, days: 4, reports: 5, lastDay: "2026-11-08",
  },
  {
    slot: 2, dayType: 0, bin: 14, cycle: 90_000, reference: "midnight", phase: 100, spread: 0,
    green: null, blink: null, days: 3, reports: 2, lastDay: "2026-11-09",
  },
];

const INTERSECTION_0000 = {
  id: "0000FFFF",
  name: null,
  position: null,
  plans: [
    {
      slot: 6, dayType: 2, bin: 47, cycle: 300_000, reference: "epoch", phase: 299_999, spread: 3_000,
      green: null, blink: 6_000, days: 3, reports: 2, lastDay: "2026-11-01",
    },
  ],
};

const INTERSECTION_1234 = { id: "1234ABCD", name: "CE0100000000AA", position: "CE0100000100BB", plans: PLAN_1234 };

describe("GET /v1/plans", () => {
  it("returns every intersection with plans, sorted, in the documented format", async () => {
    await seed();
    const response = await context.fetch(getPlans());
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(response.headers.get("cache-control")).toBe("private, max-age=3600");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    // The exact text: field order as documented.
    expect(await response.text()).toBe(JSON.stringify({ intersections: [INTERSECTION_0000, INTERSECTION_1234] }));
  });

  it("returns an empty list when there are no plans", async () => {
    await env.DB.prepare("INSERT INTO timing_places VALUES ('ABCDEF01', NULL, NULL, '2026-11-11')").run();
    const response = await context.fetch(getPlans());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("private, max-age=3600");
    expect(await response.text()).toBe('{"intersections":[]}');
  });

  it("filters by ids", async () => {
    await seed();
    const cases: [string, unknown[]][] = [
      ["?ids=1234ABCD", [INTERSECTION_1234]],
      ["?ids=1234ABCD,0000FFFF", [INTERSECTION_0000, INTERSECTION_1234]],
      ["?ids=1234ABCD,1234ABCD", [INTERSECTION_1234]],
      ["?ids=1234ABCD%2C0000FFFF", [INTERSECTION_0000, INTERSECTION_1234]],
      // Fitted, but without plans; unknown.
      ["?ids=ABCDEF01", []],
      ["?ids=FFFFFFFF", []],
      // Other parameters are ignored.
      ["?ids=0000FFFF&v=2", [INTERSECTION_0000]],
      ["?v=2", [INTERSECTION_0000, INTERSECTION_1234]],
    ];
    for (const [query, intersections] of cases) {
      const response = await context.fetch(getPlans(query));
      expect(response.status, query).toBe(200);
      expect(await response.json(), query).toEqual({ intersections });
    }
    const fifty = Array.from({ length: 50 }, (_, i) => (0x10000000 + i).toString(16).toUpperCase());
    const response = await context.fetch(getPlans(`?ids=${[...fifty.slice(1), "1234ABCD"].join(",")}`));
    expect(await response.json()).toEqual({ intersections: [INTERSECTION_1234] });
  });

  it("answers 400 bad_request for a malformed ids query", async () => {
    const fiftyOne = Array.from({ length: 51 }, (_, i) => (0x10000000 + i).toString(16).toUpperCase()).join(",");
    for (const query of [
      "?ids=",
      "?ids",
      "?ids=1234abcd",
      "?ids=1234ABC",
      "?ids=1234ABCD0",
      "?ids=1234ABCG",
      "?ids=1234ABCD,",
      "?ids=,1234ABCD",
      "?ids=1234ABCD,,0000FFFF",
      "?ids=1234ABCD%200000FFFF",
      "?ids=1234ABCD;0000FFFF",
      "?ids=%201234ABCD",
      "?ids=1234ABCD&ids=0000FFFF",
      `?ids=${fiftyOne}`,
    ]) {
      const response = await context.fetch(getPlans(query));
      expect(response.status, query).toBe(400);
      expect(await response.json(), query).toEqual({ error: "bad_request" });
      expect(response.headers.get("cache-control"), query).toBe("no-store");
    }
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
    // Checked before the ids.
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

  it("only reads: no D1 write, no budget", async () => {
    await seed();
    const { db, meter } = meteredDatabase();
    const metered = await createContext({ DB: db, DAILY_WRITE_LIMIT: "1" });
    const { token: fresh } = await makeToken(metered);
    const response = await metered.fetch(getPlans("", { authorization: `Bearer ${fresh}` }));
    expect(response.status).toBe(200);
    expect(meter).toEqual({ queries: 1, rowsWritten: 0 });
    expect(await env.DB.prepare("SELECT count(*) AS n FROM daily_usage").first("n")).toBe(0);
  });

  it("accepts only GET", async () => {
    const request = new Request(`${BASE}/v1/plans`, { method: "POST", headers: { authorization: `Bearer ${token}` } });
    const response = await context.fetch(request);
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("GET");
  });

  it("serves the plan fitted from reports sent through the API", async () => {
    // A 120 s signal (green at Unix time ≡ 37.4 s mod 120 s) seen on three weekday mornings
    // (Tuesday to Thursday, 07:00-07:10 JST), each sent a minute after the last change.
    const id = "1234ABCD";
    for (const day of [17, 18, 19]) {
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
    const response = await context.fetch(getPlans(`?ids=${id}`, { authorization: `Bearer ${reader}` }));
    expect(await response.json()).toEqual({
      intersections: [
        {
          id,
          name: `CE01000000290000${id}`.padEnd(52, "0"),
          position: `CE01000001290000${id}`.padEnd(40, "1"),
          plans: [
            {
              slot: 1, dayType: 0, bin: 14, cycle: 120_000, reference: "epoch", phase: 37_400, spread: 0,
              green: 30_000, blink: null, days: 3, reports: 3, lastDay: "2026-11-19",
            },
          ],
        },
      ],
    });
  });
});
