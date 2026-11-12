// SPDX-License-Identifier: Apache-2.0

// Shared test fixtures: an explicit Env with fake rate limiters, a controllable clock, and
// helpers that drive the Worker through its HTTP interface.

import { createExecutionContext } from "cloudflare:test";
import { env as bindings } from "cloudflare:workers";
import { createApp, type App } from "../../src/app";
import { decodeBase64Url, encodeBase64, encodeBase64Url, randomBytes } from "../../src/encoding";
import type { Env } from "../../src/env";
import { signToken } from "../../src/token";
import { buildAttestation, createFakePki, type BuiltAttestation, type FakePki } from "./appattest";

export const TEAM_ID = "TEAMID1234";
export const BUNDLE_ID = "es.4sh.aoshingo";
export const APP_ID = `${TEAM_ID}.${BUNDLE_ID}`;
export const TOKEN_SECRET = "unit-test-token-secret-0123456789abcdef";
export const BASE = "https://reports.example";

/** Records every key it is asked about; denies when `allow` is false. */
export class FakeRateLimiter implements RateLimit {
  readonly keys: string[] = [];
  constructor(public allow = true) {}
  async limit(options: RateLimitOptions): Promise<RateLimitOutcome> {
    this.keys.push(options.key);
    return { success: this.allow };
  }
}

export class Clock {
  constructor(public ms: number = Date.now()) {}
  get seconds(): number {
    return Math.floor(this.ms / 1000);
  }
  advance(seconds: number): void {
    this.ms += seconds * 1000;
  }
}

export interface TestContext {
  app: App;
  env: Env;
  clock: Clock;
  pki: FakePki;
  reportsLimiter: FakeRateLimiter;
  authLimiter: FakeRateLimiter;
  fetch(request: Request): Promise<Response>;
}

export async function createContext(overrides: Partial<Env> = {}): Promise<TestContext> {
  const clock = new Clock();
  const pki = await createFakePki(clock.ms);
  const reportsLimiter = new FakeRateLimiter();
  const authLimiter = new FakeRateLimiter();
  const env: Env = {
    DB: bindings.DB,
    REPORTS_RATE_LIMITER: reportsLimiter,
    AUTH_RATE_LIMITER: authLimiter,
    TOKEN_SECRET,
    APPLE_TEAM_ID: TEAM_ID,
    APP_BUNDLE_ID: BUNDLE_ID,
    ALLOW_DEVELOPMENT_ATTESTATION: "false",
    RETENTION_DAYS: "90",
    TOKEN_TTL_SECONDS: "21600",
    DAILY_WRITE_LIMIT: "30000",
    DAILY_STORAGE_LIMIT_BYTES: "3000000",
    MAX_DATABASE_BYTES: "450000000",
    ...overrides,
  };
  const app = createApp({ attestationRootForTesting: pki.rootDer, now: () => clock.ms });
  return {
    app,
    env,
    clock,
    pki,
    reportsLimiter,
    authLimiter,
    fetch: (request) => app.fetch(request, env, createExecutionContext()),
  };
}

export async function resetDatabase(): Promise<void> {
  await bindings.DB.batch(
    [
      "attest_keys",
      "reports",
      "transition_counts",
      "observation_counts",
      "duration_counts",
      "range_counts",
      "crosswalk_labels",
      "daily_usage",
      "service_state",
      "timing_plans",
      "timing_places",
      "timing_snapshot",
    ].map((table) => bindings.DB.prepare(`DELETE FROM ${table}`)),
  );
}

export function postJson(path: string, body: unknown, headers: Record<string, string> = {}): Request {
  return new Request(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

export async function getChallenge(context: TestContext): Promise<string> {
  const response = await context.fetch(new Request(`${BASE}/v1/challenge`, { method: "POST" }));
  if (response.status !== 201) throw new Error(`challenge failed: ${response.status}`);
  return ((await response.json()) as { challenge: string }).challenge;
}

export interface RegisteredKey extends BuiltAttestation {
  token: string;
  expiresAt: number;
}

/** Runs challenge + attest and returns the new key and its first upload token. */
export async function registerKey(
  context: TestContext,
  options: Partial<Parameters<typeof buildAttestation>[0]> = {},
): Promise<RegisteredKey> {
  const challenge = await getChallenge(context);
  const built = await buildAttestation({ pki: context.pki, challenge, appId: APP_ID, nowMs: context.clock.ms, ...options });
  const response = await context.fetch(
    postJson("/v1/attest", {
      keyId: encodeBase64(built.keyId),
      attestation: encodeBase64(built.attestation),
      challenge,
    }),
  );
  if (response.status !== 200) throw new Error(`attest failed: ${response.status} ${await response.text()}`);
  const { token, expiresAt } = (await response.json()) as { token: string; expiresAt: number };
  return { ...built, token, expiresAt };
}

/** A valid upload token signed with the test secret, without going through attestation. */
export async function makeToken(
  context: TestContext,
  options: { expiresIn?: number; environment?: "production" | "development"; id?: Uint8Array } = {},
): Promise<{ token: string; id: Uint8Array }> {
  const id = options.id ?? randomBytes(16);
  const token = await signToken(TOKEN_SECRET, {
    id,
    expiresAt: context.clock.seconds + (options.expiresIn ?? 3600),
    environment: options.environment ?? "production",
  });
  return { token, id };
}

export function tokenId(token: string): string {
  const bytes = decodeBase64Url(token)!;
  return encodeBase64Url(bytes.subarray(2, 18));
}

export function reportRequest(token: string, body: unknown, headers: Record<string, string> = {}): Request {
  return postJson("/v1/reports", body, { authorization: `Bearer ${token}`, ...headers });
}

/** The example report from docs/field-data-api.md, with times moved to `nowSeconds`. */
export function exampleReport(nowSeconds: number) {
  return {
    schema: 1,
    client: "aoshingo-ios/0.1.0",
    intersections: [
      {
        id: "1234ABCD",
        serviceUUIDs: [] as string[],
        emitters: 1,
        observations: [
          {
            t: nowSeconds - 10,
            raw: "CE010000022A00001234ABCD311384848484",
            rssi: -70,
            bearing: 3,
            heading: null,
          },
        ],
        transitions: [{ t: nowSeconds - 5, slot: 1, from: "Red", to: "Green" }],
      },
    ],
  };
}

/**
 * A schema 2 report: the example from docs/field-data-api.md without schema 3's
 * observations[].activity, with times moved to `nowSeconds`.
 */
export function exampleReport2(nowSeconds: number) {
  return {
    schema: 2,
    client: "aoshingo-ios/0.2.0",
    intersections: [
      {
        id: "1234ABCD",
        serviceUUIDs: [] as string[],
        emitters: 1,
        emitterInfo: [{ txPower: null, connectable: false }],
        observations: [
          {
            t: nowSeconds - 240,
            raw: "CE010000022A00001234ABCD311384848484",
            rssi: -70,
            bearing: 3,
            heading: null,
            emitter: 0,
            distance: 20,
            accuracy: 10,
            course: 2,
            speed: 1,
            nearby: 20,
          },
        ],
        transitions: [
          { t: nowSeconds - 235, slot: 1, from: "Red", to: "Green", emitter: 0, gap: 300, held: 42100, cycle: 98700 },
        ],
        steps: [{ t: nowSeconds - 231, slot: 1, state: "Green", from: 8, to: 7, emitter: 0, held: 3900 }],
        packets: [{ emitter: 0, type: 2, count: 1180, minInterval: 90, medianInterval: 200 }],
        coverage: [{ start: nowSeconds - 250, end: nowSeconds - 10 }],
        labels: [{ t: nowSeconds - 140, kind: "crosswalk", slot: 1, heading: 2, bearing: 5, distance: 10 }],
      },
    ],
  };
}

/** The schema 3 example report from docs/field-data-api.md, with times moved to `nowSeconds`. */
export function exampleReport3(nowSeconds: number) {
  const report = exampleReport2(nowSeconds);
  return {
    ...report,
    schema: 3,
    intersections: report.intersections.map((intersection) => ({
      ...intersection,
      observations: intersection.observations.map((observation) => ({ ...observation, activity: "walking" })),
    })),
  };
}

/**
 * The schema 4 example report from docs/field-data-api.md, with times moved to `nowSeconds`:
 * schema 3 plus sentAt (123 ms after the start of `nowSeconds`, so within the clock check's 2 s of
 * the server's clock) and the ms of each transition and step (written last, as they are stored).
 */
export function exampleReport4(nowSeconds: number) {
  const report = exampleReport3(nowSeconds);
  return {
    schema: 4,
    sentAt: nowSeconds * 1000 + 123,
    client: report.client,
    intersections: report.intersections.map((intersection) => ({
      ...intersection,
      transitions: intersection.transitions.map((transition) => ({ ...transition, ms: 400 })),
      steps: intersection.steps.map((step) => ({ ...step, ms: 900 })),
    })),
  };
}

/** The daily_usage row for `day`, or null. */
export async function usage(day: string): Promise<{ rows_written: number; stored_bytes: number } | null> {
  return bindings.DB.prepare("SELECT rows_written, stored_bytes FROM daily_usage WHERE day = ?1")
    .bind(day)
    .first<{ rows_written: number; stored_bytes: number }>();
}

/** What a MeteredDatabase saw. */
export interface Meter {
  /** D1 queries; a batch counts as one, as on the Free plan's per-invocation limit. */
  queries: number;
  /** Sum of D1's own meta.rows_written. */
  rowsWritten: number;
}

const ORIGINAL = Symbol("original statement");

/**
 * Wraps a D1 binding and adds up the queries made and the rows D1 reports as written, so tests can
 * compare the budget's accounting with D1's. `first()` returns no meta, so it is counted as a
 * query only; the Worker uses it for reads alone.
 */
export function meteredDatabase(db: D1Database = bindings.DB): { db: D1Database; meter: Meter } {
  const meter: Meter = { queries: 0, rowsWritten: 0 };
  const add = (result: D1Result): D1Result => {
    meter.rowsWritten += result.meta.rows_written ?? 0;
    return result;
  };
  const wrap = (statement: D1PreparedStatement): D1PreparedStatement =>
    new Proxy(statement, {
      get(target, property) {
        if (property === ORIGINAL) return target;
        if (property === "bind") return (...values: unknown[]) => wrap(target.bind(...values));
        if (property === "run" || property === "all") {
          return async () => {
            meter.queries += 1;
            return add(await target[property]());
          };
        }
        if (property === "first" || property === "raw") {
          return (...args: unknown[]) => {
            meter.queries += 1;
            return (target[property] as (...rest: unknown[]) => unknown).apply(target, args);
          };
        }
        const value: unknown = Reflect.get(target, property, target);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
  const metered = new Proxy(db, {
    get(target, property) {
      if (property === "prepare") return (query: string) => wrap(target.prepare(query));
      if (property === "batch") {
        return async (statements: D1PreparedStatement[]) => {
          meter.queries += 1;
          const originals = statements.map(
            (statement) => (statement as unknown as Record<symbol, D1PreparedStatement | undefined>)[ORIGINAL] ?? statement,
          );
          const results = await target.batch(originals);
          for (const result of results) add(result);
          return results;
        };
      }
      const value: unknown = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  return { db: metered, meter };
}
