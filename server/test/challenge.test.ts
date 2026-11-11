// SPDX-License-Identifier: Apache-2.0

import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { issueChallenge, verifyChallenge } from "../src/challenge";
import { decodeBase64Url, encodeBase64, encodeBase64Url } from "../src/encoding";
import { buildAttestation } from "./helpers/appattest";
import { utcDay } from "../src/storage";
import {
  APP_ID,
  BASE,
  createContext,
  makeToken,
  meteredDatabase,
  postJson,
  resetDatabase,
  TOKEN_SECRET,
  usage,
  type TestContext,
} from "./helpers/context";

let context: TestContext;

beforeEach(async () => {
  await resetDatabase();
  context = await createContext();
});

function challengeRequest(): Request {
  return new Request(`${BASE}/v1/challenge`, { method: "POST" });
}

async function expectOverCapacity(response: Response): Promise<void> {
  expect(response.status).toBe(503);
  expect(await response.json()).toEqual({ error: "over_capacity" });
}

/** Sets today's daily_usage counters. */
async function setUsage(ctx: TestContext, rows: number, bytes: number): Promise<void> {
  await env.DB.prepare("INSERT INTO daily_usage (day, rows_written, stored_bytes) VALUES (?1, ?2, ?3)")
    .bind(utcDay(ctx.clock.ms), rows, bytes)
    .run();
}

describe("POST /v1/challenge", () => {
  it("issues a signed challenge valid for 300 s with one read, no D1 write and no rate limit", async () => {
    const { db, meter } = meteredDatabase();
    const metered = await createContext({ DB: db });
    const response = await metered.fetch(challengeRequest());
    expect(response.status).toBe(201);
    const body = (await response.json()) as { challenge: string; expiresAt: number };
    expect(Object.keys(body).sort()).toEqual(["challenge", "expiresAt"]);
    expect(body.challenge).toMatch(/^[A-Za-z0-9_-]{76}$/);
    expect(decodeBase64Url(body.challenge)?.byteLength).toBe(57);
    expect(body.expiresAt).toBe(metered.clock.seconds + 300);
    expect(await verifyChallenge(TOKEN_SECRET, body.challenge, metered.clock.seconds)).toBe(true);
    expect(meter).toEqual({ queries: 1, rowsWritten: 0 });
    expect(await env.DB.prepare("SELECT count(*) AS n FROM daily_usage").first("n")).toBe(0);
    expect(metered.authLimiter.keys).toEqual([]);
  });

  it("no longer has a challenges table", async () => {
    const tables = await env.DB.prepare("SELECT name FROM sqlite_schema WHERE name LIKE 'challenges%'").all();
    expect(tables.results).toEqual([]);
  });

  it("issues challenges while one more key fits into today's budget", async () => {
    // A key costs 2 rows (its row and the counter) and 300 bytes.
    const limited = await createContext({ DAILY_WRITE_LIMIT: "100", DAILY_STORAGE_LIMIT_BYTES: "1000" });
    await setUsage(limited, 98, 700);
    expect((await limited.fetch(challengeRequest())).status).toBe(201);
  });

  it("answers 503 over_capacity, writing nothing, once a key no longer fits into today's rows", async () => {
    const { db, meter } = meteredDatabase();
    const limited = await createContext({ DB: db, DAILY_WRITE_LIMIT: "100" });
    await setUsage(limited, 99, 0);
    await expectOverCapacity(await limited.fetch(challengeRequest()));
    expect(meter.rowsWritten).toBe(0);
    expect(await usage(utcDay(limited.clock.ms))).toEqual({ rows_written: 99, stored_bytes: 0 });
    expect(limited.authLimiter.keys).toEqual([]);
  });

  it("answers 503 over_capacity once a key no longer fits into today's bytes", async () => {
    const limited = await createContext({ DAILY_STORAGE_LIMIT_BYTES: "1000" });
    await setUsage(limited, 0, 701);
    await expectOverCapacity(await limited.fetch(challengeRequest()));
  });

  it("answers 503 over_capacity while the database is larger than MAX_DATABASE_BYTES", async () => {
    const limited = await createContext({ MAX_DATABASE_BYTES: "1" });
    await expectOverCapacity(await limited.fetch(challengeRequest()));
    expect(await env.DB.prepare("SELECT count(*) AS n FROM daily_usage").first("n")).toBe(0);
  });

  it("issues challenges again on the next UTC day", async () => {
    const limited = await createContext({ DAILY_WRITE_LIMIT: "100" });
    await setUsage(limited, 100, 0);
    await expectOverCapacity(await limited.fetch(challengeRequest()));
    limited.clock.advance(86_400);
    expect((await limited.fetch(challengeRequest())).status).toBe(201);
  });

  it("accepts an empty JSON body", async () => {
    const response = await context.fetch(postJson("/v1/challenge", {}));
    expect(response.status).toBe(201);
  });

  it("issues distinct challenges", async () => {
    const a = await issueChallenge(TOKEN_SECRET, context.clock.seconds);
    const b = await issueChallenge(TOKEN_SECRET, context.clock.seconds);
    expect(a.challenge).not.toBe(b.challenge);
  });

  it("answers 500 server_misconfigured without TOKEN_SECRET", async () => {
    const broken = await createContext({ TOKEN_SECRET: undefined });
    const response = await broken.fetch(new Request(`${BASE}/v1/challenge`, { method: "POST" }));
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "server_misconfigured" });
  });
});

describe("challenge verification", () => {
  it("accepts a challenge until just before expiry and rejects it from then on", async () => {
    const { challenge } = await issueChallenge(TOKEN_SECRET, context.clock.seconds);
    expect(await verifyChallenge(TOKEN_SECRET, challenge, context.clock.seconds + 299)).toBe(true);
    expect(await verifyChallenge(TOKEN_SECRET, challenge, context.clock.seconds + 300)).toBe(false);
  });

  it("rejects challenges signed with another secret", async () => {
    const { challenge } = await issueChallenge("another-secret-0123456789abcdef-xyz", context.clock.seconds);
    expect(await verifyChallenge(TOKEN_SECRET, challenge, context.clock.seconds)).toBe(false);
  });

  it("rejects a challenge whose expiry was changed", async () => {
    const { challenge } = await issueChallenge(TOKEN_SECRET, context.clock.seconds - 600);
    const bytes = decodeBase64Url(challenge)!;
    new DataView(bytes.buffer).setBigUint64(17, BigInt(context.clock.seconds + 300));
    expect(await verifyChallenge(TOKEN_SECRET, encodeBase64Url(bytes), context.clock.seconds)).toBe(false);
  });

  it("does not accept an upload token as a challenge", async () => {
    const { token } = await makeToken(context);
    expect(await verifyChallenge(TOKEN_SECRET, token, context.clock.seconds)).toBe(false);
  });

  it("rejects malformed challenges", async () => {
    for (const value of ["A".repeat(76), "A".repeat(43), "short", "A".repeat(75) + "=", 42, null, undefined]) {
      expect(await verifyChallenge(TOKEN_SECRET, value, context.clock.seconds)).toBe(false);
    }
  });

  it("rejects an expired challenge at /v1/attest", async () => {
    const response = await context.fetch(new Request(`${BASE}/v1/challenge`, { method: "POST" }));
    const { challenge } = (await response.json()) as { challenge: string };
    context.clock.advance(301);
    const built = await buildAttestation({ pki: context.pki, challenge, appId: APP_ID, nowMs: context.clock.ms });
    const attest = await context.fetch(
      postJson("/v1/attest", {
        keyId: encodeBase64(built.keyId),
        attestation: encodeBase64(built.attestation),
        challenge,
      }),
    );
    expect(attest.status).toBe(400);
    expect(await attest.json()).toEqual({ error: "bad_challenge" });
    expect(await env.DB.prepare("SELECT count(*) AS n FROM attest_keys").first("n")).toBe(0);
  });

  it("cannot be used to register the same key twice", async () => {
    const response = await context.fetch(new Request(`${BASE}/v1/challenge`, { method: "POST" }));
    const { challenge } = (await response.json()) as { challenge: string };
    const built = await buildAttestation({ pki: context.pki, challenge, appId: APP_ID, nowMs: context.clock.ms });
    const request = () =>
      postJson("/v1/attest", {
        keyId: encodeBase64(built.keyId),
        attestation: encodeBase64(built.attestation),
        challenge,
      });
    expect((await context.fetch(request())).status).toBe(200);
    const replay = await context.fetch(request());
    expect(replay.status).toBe(409);
    expect(await replay.json()).toEqual({ error: "key_exists" });
    expect(await env.DB.prepare("SELECT count(*) AS n FROM attest_keys").first("n")).toBe(1);
  });
});
