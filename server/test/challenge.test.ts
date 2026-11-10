// SPDX-License-Identifier: Apache-2.0

import { createExecutionContext, createScheduledController } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { consumeChallenge, issueChallenge } from "../src/challenge";
import { decodeBase64Url, encodeBase64 } from "../src/encoding";
import { buildAttestation } from "./helpers/appattest";
import { APP_ID, BASE, createContext, postJson, resetDatabase, type TestContext } from "./helpers/context";

let context: TestContext;

beforeEach(async () => {
  await resetDatabase();
  context = await createContext();
});

async function challengeRow(challenge: string) {
  return env.DB.prepare("SELECT expires_at FROM challenges WHERE challenge = ?1")
    .bind(challenge)
    .first<{ expires_at: number }>();
}

describe("POST /v1/challenge", () => {
  it("issues a 32-byte base64url challenge valid for 300 s", async () => {
    const response = await context.fetch(new Request(`${BASE}/v1/challenge`, { method: "POST" }));
    expect(response.status).toBe(201);
    const body = (await response.json()) as { challenge: string; expiresAt: number };
    expect(Object.keys(body).sort()).toEqual(["challenge", "expiresAt"]);
    expect(body.challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(decodeBase64Url(body.challenge)?.byteLength).toBe(32);
    expect(body.expiresAt).toBe(context.clock.seconds + 300);
    expect((await challengeRow(body.challenge))?.expires_at).toBe(body.expiresAt);
    expect(context.authLimiter.keys).toEqual(["challenge"]);
  });

  it("accepts an empty JSON body", async () => {
    const response = await context.fetch(postJson("/v1/challenge", {}));
    expect(response.status).toBe(201);
  });

  it("issues distinct challenges", async () => {
    const a = await issueChallenge(env.DB, context.clock.seconds);
    const b = await issueChallenge(env.DB, context.clock.seconds);
    expect(a.challenge).not.toBe(b.challenge);
  });
});

describe("challenge consumption", () => {
  it("is single-use and deletes the row", async () => {
    const { challenge } = await issueChallenge(env.DB, context.clock.seconds);
    expect(await consumeChallenge(env.DB, challenge, context.clock.seconds)).toBe(true);
    expect(await challengeRow(challenge)).toBeNull();
    expect(await consumeChallenge(env.DB, challenge, context.clock.seconds)).toBe(false);
  });

  it("rejects expired challenges and removes them", async () => {
    const { challenge } = await issueChallenge(env.DB, context.clock.seconds);
    expect(await consumeChallenge(env.DB, challenge, context.clock.seconds + 300)).toBe(false);
    expect(await challengeRow(challenge)).toBeNull();
  });

  it("accepts a challenge just before expiry", async () => {
    const { challenge } = await issueChallenge(env.DB, context.clock.seconds);
    expect(await consumeChallenge(env.DB, challenge, context.clock.seconds + 299)).toBe(true);
  });

  it("rejects unknown and malformed challenges", async () => {
    for (const value of ["A".repeat(43), "short", "A".repeat(42) + "=", 42, null, undefined]) {
      expect(await consumeChallenge(env.DB, value, context.clock.seconds)).toBe(false);
    }
  });

  it("is consumed by /v1/attest even when the attestation fails, and cannot be reused", async () => {
    const response = await context.fetch(new Request(`${BASE}/v1/challenge`, { method: "POST" }));
    const { challenge } = (await response.json()) as { challenge: string };
    const built = await buildAttestation({ pki: context.pki, challenge: "other", appId: APP_ID });
    const request = () =>
      postJson("/v1/attest", {
        keyId: encodeBase64(built.keyId),
        attestation: encodeBase64(built.attestation),
        challenge,
      });
    const first = await context.fetch(request());
    expect(first.status).toBe(401);
    expect(await first.json()).toEqual({ error: "attestation_invalid" });
    const second = await context.fetch(request());
    expect(second.status).toBe(400);
    expect(await second.json()).toEqual({ error: "bad_challenge" });
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
  });
});

describe("cron cleanup", () => {
  it("deletes expired challenges and keeps live ones", async () => {
    const old = await issueChallenge(env.DB, context.clock.seconds - 600);
    const fresh = await issueChallenge(env.DB, context.clock.seconds);
    await context.app.scheduled(createScheduledController(), context.env, createExecutionContext());
    expect(await challengeRow(old.challenge)).toBeNull();
    expect(await challengeRow(fresh.challenge)).not.toBeNull();
  });
});
