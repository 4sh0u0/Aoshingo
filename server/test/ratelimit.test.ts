// SPDX-License-Identifier: Apache-2.0

import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { encodeBase64, encodeBase64Url, toHex } from "../src/encoding";
import { buildAssertion, buildAttestation } from "./helpers/appattest";
import {
  APP_ID,
  BASE,
  createContext,
  exampleReport,
  getChallenge,
  makeToken,
  postJson,
  registerKey,
  reportRequest,
  resetDatabase,
  tokenId,
  type TestContext,
} from "./helpers/context";

let context: TestContext;

beforeEach(async () => {
  await resetDatabase();
  context = await createContext();
});

async function expectRateLimited(response: Response): Promise<void> {
  expect(response.status).toBe(429);
  expect(await response.json()).toEqual({ error: "rate_limited" });
}

describe("rate limiting", () => {
  it("does not limit /v1/challenge, which writes nothing", async () => {
    context.authLimiter.allow = false;
    expect((await context.fetch(new Request(`${BASE}/v1/challenge`, { method: "POST" }))).status).toBe(201);
    expect(context.authLimiter.keys).toEqual([]);
  });

  it("counts only verified attestations, so junk cannot lock out genuine clients", async () => {
    context.authLimiter.allow = false;
    const challenge = await getChallenge(context);
    const junk = await context.fetch(postJson("/v1/attest", { keyId: "", attestation: "", challenge }));
    expect(junk.status).toBe(400);
    const forged = await buildAttestation({ pki: context.pki, challenge, appId: APP_ID, counter: 3 });
    const invalid = await context.fetch(
      postJson("/v1/attest", {
        keyId: encodeBase64(forged.keyId),
        attestation: encodeBase64(forged.attestation),
        challenge,
      }),
    );
    expect(invalid.status).toBe(401);
    expect(context.authLimiter.keys).toEqual([]);

    const built = await buildAttestation({ pki: context.pki, challenge, appId: APP_ID });
    await expectRateLimited(
      await context.fetch(
        postJson("/v1/attest", {
          keyId: encodeBase64(built.keyId),
          attestation: encodeBase64(built.attestation),
          challenge,
        }),
      ),
    );
    expect(context.authLimiter.keys).toEqual(["attest"]);
    expect(await env.DB.prepare("SELECT count(*) AS n FROM attest_keys").first("n")).toBe(0);
  });

  it("limits /v1/token per key, after the assertion is verified, without the keyId itself", async () => {
    const key = await registerKey(context);
    const other = await registerKey(context);
    context.authLimiter.keys.length = 0;
    const request = async (registered: typeof key, counter: number, signWith = registered.credentialKey.privateKey) => {
      const challenge = await getChallenge(context);
      const assertion = await buildAssertion({ privateKey: signWith, challenge, appId: APP_ID, counter });
      return context.fetch(
        postJson("/v1/token", {
          keyId: encodeBase64(registered.keyId),
          assertion: encodeBase64(assertion),
          challenge,
        }),
      );
    };

    // A bad signature is rejected before the limiter is asked.
    expect((await request(key, 1, other.credentialKey.privateKey)).status).toBe(401);
    expect(context.authLimiter.keys).toEqual([]);

    expect((await request(key, 1)).status).toBe(200);
    expect((await request(other, 1)).status).toBe(200);
    context.authLimiter.allow = false;
    await expectRateLimited(await request(key, 2));
    // The counter was not used up by the refused request.
    context.authLimiter.allow = true;
    expect((await request(key, 2)).status).toBe(200);

    const [first, second, third, fourth] = context.authLimiter.keys;
    expect(first).toMatch(/^token:[A-Za-z0-9_-]{22}$/);
    expect(first).not.toBe(second);
    expect([third, fourth]).toEqual([first, first]);
    for (const limitKey of context.authLimiter.keys) {
      for (const keyId of [key.keyId, other.keyId]) {
        expect(limitKey).not.toContain(toHex(keyId));
        expect(limitKey).not.toContain(encodeBase64Url(keyId));
        expect(limitKey).not.toContain(encodeBase64(keyId).replace(/=+$/, ""));
      }
    }
  });

  it("limits /v1/reports by the token's random ID, not by client address", async () => {
    const { token } = await makeToken(context);
    const report = exampleReport(context.clock.seconds);
    const headers = { "cf-connecting-ip": "203.0.113.7", "x-forwarded-for": "203.0.113.7" };
    expect((await context.fetch(reportRequest(token, report, headers))).status).toBe(202);
    context.reportsLimiter.allow = false;
    await expectRateLimited(await context.fetch(reportRequest(token, report, headers)));
    expect(context.reportsLimiter.keys).toEqual([tokenId(token), tokenId(token)]);
    expect(context.authLimiter.keys).toEqual([]);
    expect(await env.DB.prepare("SELECT count(*) AS n FROM reports").first("n")).toBe(1);
  });

  it("gives different tokens different keys", async () => {
    const a = await makeToken(context);
    const b = await makeToken(context);
    const report = exampleReport(context.clock.seconds);
    await context.fetch(reportRequest(a.token, report));
    await context.fetch(reportRequest(b.token, report));
    expect(new Set(context.reportsLimiter.keys).size).toBe(2);
  });
});
