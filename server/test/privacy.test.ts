// SPDX-License-Identifier: Apache-2.0

import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { decodeBase64Url, encodeBase64, encodeBase64Url, toHex } from "../src/encoding";
import {
  createContext,
  exampleReport,
  exampleReport4,
  makeToken,
  registerKey,
  reportRequest,
  resetDatabase,
  type TestContext,
} from "./helpers/context";

// The Worker's own source, bundled as text by Vite for static checks.
const sources = import.meta.glob<string>("../src/**/*.ts", { query: "?raw", import: "default", eager: true });

let context: TestContext;

beforeEach(async () => {
  await resetDatabase();
  context = await createContext();
});

describe("privacy", () => {
  it("stores neither the token, its ID nor the keyId in report rows", async () => {
    const key = await registerKey(context);
    const response = await context.fetch(reportRequest(key.token, exampleReport(context.clock.seconds)));
    expect(response.status).toBe(202);

    const tokenBytes = decodeBase64Url(key.token)!;
    const tokenIdBytes = tokenBytes.subarray(2, 18);
    const secrets = [
      key.token,
      encodeBase64Url(tokenIdBytes),
      encodeBase64(tokenIdBytes),
      toHex(tokenIdBytes),
      toHex(tokenIdBytes).toUpperCase(),
      encodeBase64(key.keyId),
      encodeBase64Url(key.keyId),
      toHex(key.keyId),
      toHex(key.keyId).toUpperCase(),
      toHex(key.publicKey),
    ];

    const { results } = await env.DB.prepare("SELECT * FROM reports").all<Record<string, unknown>>();
    expect(results).toHaveLength(1);
    expect(Object.keys(results[0]!).sort()).toEqual([
      "aggregate_items",
      "client",
      "clock_ok",
      "id",
      "intersection_id",
      "observation_count",
      "payload",
      "received_day",
      "schema",
      "transition_count",
    ]);
    const dump = JSON.stringify(results);
    for (const secret of secrets) expect(dump).not.toContain(secret);
    // The row ID is a random 53-bit integer, not derived from the token.
    const id = results[0]!.id;
    expect(Number.isSafeInteger(id) && (id as number) >= 0).toBe(true);
  });

  it("stores only the clock check of schema 4, neither sentAt nor its difference from the server's clock", async () => {
    context.clock.ms = Date.UTC(2026, 10, 12, 3, 4, 5, 678);
    const { token } = await makeToken(context);
    // 1,777 ms behind: within the 2 s of the clock check.
    const sentAt = context.clock.ms - 1777;
    const response = await context.fetch(reportRequest(token, { ...exampleReport4(context.clock.seconds), sentAt }));
    expect(response.status).toBe(202);

    const { results } = await env.DB.prepare("SELECT * FROM reports").all<Record<string, unknown>>();
    expect(results).toHaveLength(1);
    expect(results[0]!.clock_ok).toBe(1);
    const numbers: number[] = [];
    const collect = (value: unknown): void => {
      if (typeof value === "number") numbers.push(value);
      else if (typeof value === "string" && value.startsWith("{")) collect(JSON.parse(value));
      else if (typeof value === "object" && value !== null) Object.values(value).forEach(collect);
    };
    collect(results[0]);
    for (const secret of [sentAt, 1777, -1777, sentAt % 1000, Math.floor(sentAt / 1000)]) {
      expect(numbers, String(secret)).not.toContain(secret);
    }
    expect(JSON.stringify(results)).not.toContain("sentAt");
    expect(JSON.stringify(results)).not.toContain(String(sentAt));
  });

  it("keeps only what the signal does in the timing tables, with days as the finest time", async () => {
    // Neither the day nor the report counts of a plan are stored. last_day and updated_day are,
    // for deleting old plans and ordering the fits, but never served (test/plans.test.ts).
    const columns: Record<string, string[]> = {};
    for (const table of ["timing_plans", "timing_places", "timing_snapshot"]) {
      const { results } = await env.DB.prepare("SELECT name FROM pragma_table_info(?1) ORDER BY cid").bind(table).all();
      columns[table] = results.map((row) => row.name as string);
    }
    expect(columns).toEqual({
      timing_plans: [
        "intersection_id",
        "slot",
        "day_type",
        "bin",
        "cycle_ms",
        "reference",
        "phase_ms",
        "spread_ms",
        "green_ms",
        "blink_ms",
        "last_day",
        "updated_day",
      ],
      timing_places: ["intersection_id", "name_raw", "position_raw", "updated_day"],
      timing_snapshot: ["chunk", "body", "generated"],
    });
  });

  it("gives report rows random keys, so rows carry no arrival order", async () => {
    const { token } = await makeToken(context);
    for (let i = 0; i < 20; i++) {
      expect((await context.fetch(reportRequest(token, exampleReport(context.clock.seconds)))).status).toBe(202);
    }
    const ids = (await env.DB.prepare("SELECT id FROM reports").all<{ id: number }>()).results.map((row) => row.id);
    expect(new Set(ids).size).toBe(20);
    for (const id of ids) expect(Number.isSafeInteger(id) && id >= 0).toBe(true);
    // Not a counter: a random 53-bit value is below 2^30 with probability 2^-23.
    expect(ids.filter((id) => id < 2 ** 30)).toHaveLength(0);
  });

  it("keeps App Attest keys in their own table without report data", async () => {
    await registerKey(context);
    const columns = await env.DB.prepare("SELECT name FROM pragma_table_info('attest_keys') ORDER BY cid").all();
    expect(columns.results.map((row) => row.name)).toEqual([
      "key_id",
      "public_key",
      "sign_count",
      "environment",
      "created_day",
      "last_used_day",
    ]);
  });

  it("keeps no finer time than the JST weekday and hour in aggregates", async () => {
    const columns: Record<string, string[]> = {};
    for (const table of ["transition_counts", "observation_counts", "duration_counts", "range_counts", "crosswalk_labels"]) {
      const { results } = await env.DB.prepare("SELECT name FROM pragma_table_info(?1) ORDER BY cid").bind(table).all();
      columns[table] = results.map((row) => row.name as string);
    }
    expect(columns).toEqual({
      transition_counts: ["intersection_id", "slot", "from_state", "to_state", "hour_jst", "count"],
      observation_counts: ["intersection_id", "message_type", "rssi", "bearing", "heading", "count"],
      duration_counts: [
        "intersection_id",
        "kind",
        "slot",
        "state",
        "step",
        "weekday_jst",
        "hour_jst",
        "seconds",
        "count",
      ],
      range_counts: ["intersection_id", "rssi", "distance", "bearing", "count"],
      crosswalk_labels: ["intersection_id", "slot", "bearing", "heading", "distance", "count"],
    });
  });

  it("answers unexpected failures with a bare 500 that reveals nothing", async () => {
    const failing = await createContext({
      DB: {
        prepare() {
          throw new Error("D1 is down: SELECT secret FROM somewhere");
        },
      } as unknown as D1Database,
    });
    const { token } = await makeToken(failing);
    const response = await failing.fetch(reportRequest(token, exampleReport(failing.clock.seconds)));
    expect(response.status).toBe(500);
    expect(await response.text()).toBe('{"error":"internal_error"}');
  });

  it("source never reads client address headers, request.cf, or logs", () => {
    const files = Object.entries(sources);
    expect(files.length).toBeGreaterThan(5);
    const allowedHeaders = new Set(["authorization", "content-length", "content-type"]);
    for (const [file, text] of files) {
      const code = text.replace(/\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "");
      for (const match of code.matchAll(/headers\.get\(\s*(['"`])([^'"`]+)\1/g)) {
        expect(allowedHeaders.has(match[2]!.toLowerCase()), `${file} reads ${match[2]}`).toBe(true);
      }
      expect(code, file).not.toMatch(/headers\.(entries|forEach|keys|values)\b|\.\.\.\s*request\.headers/);
      expect(code, file).not.toMatch(/\.cf\b/);
      expect(code, file).not.toMatch(/\bconsole\./);
      expect(code.toLowerCase(), file).not.toMatch(/connecting-ip|forwarded|ipcountry|true-client-ip/);
    }
  });
});
