// SPDX-License-Identifier: Apache-2.0

import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { encodeBase64 } from "../src/encoding";
import { buildAssertion } from "./helpers/appattest";
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
  it("limits /v1/challenge with a fixed global key and stores nothing", async () => {
    context.authLimiter.allow = false;
    await expectRateLimited(await context.fetch(new Request(`${BASE}/v1/challenge`, { method: "POST" })));
    expect(context.authLimiter.keys).toEqual(["challenge"]);
    expect(await env.DB.prepare("SELECT count(*) AS n FROM challenges").first("n")).toBe(0);
  });

  it("limits /v1/attest with a fixed global key before consuming the challenge", async () => {
    const challenge = await getChallenge(context);
    context.authLimiter.allow = false;
    await expectRateLimited(
      await context.fetch(postJson("/v1/attest", { keyId: "", attestation: "", challenge })),
    );
    expect(context.authLimiter.keys).toEqual(["challenge", "attest"]);
    expect(await env.DB.prepare("SELECT count(*) AS n FROM challenges").first("n")).toBe(1);
  });

  it("limits /v1/token with a fixed global key", async () => {
    const key = await registerKey(context);
    const challenge = await getChallenge(context);
    const assertion = await buildAssertion({
      privateKey: key.credentialKey.privateKey,
      challenge,
      appId: APP_ID,
      counter: 1,
    });
    context.authLimiter.allow = false;
    await expectRateLimited(
      await context.fetch(
        postJson("/v1/token", { keyId: encodeBase64(key.keyId), assertion: encodeBase64(assertion), challenge }),
      ),
    );
    expect(context.authLimiter.keys).toEqual(["challenge", "attest", "challenge", "token"]);
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
