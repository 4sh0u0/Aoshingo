// SPDX-License-Identifier: Apache-2.0

import { beforeEach, describe, expect, it } from "vitest";
import { decodeBase64Url, encodeBase64Url } from "../src/encoding";
import { issueToken, signToken, verifyToken } from "../src/token";
import {
  createContext,
  exampleReport,
  makeToken,
  registerKey,
  reportRequest,
  resetDatabase,
  TOKEN_SECRET,
  type TestContext,
} from "./helpers/context";

const NOW = 1_794_290_000;

describe("upload tokens", () => {
  it("round-trips claims and expires at expiresAt", async () => {
    const { token, expiresAt } = await issueToken(TOKEN_SECRET, "production", 21600, NOW);
    expect(expiresAt).toBe(NOW + 21600);
    expect(token).toMatch(/^[A-Za-z0-9_-]{78}$/);
    const claims = await verifyToken(TOKEN_SECRET, token, NOW + 21599);
    expect(claims?.expiresAt).toBe(expiresAt);
    expect(claims?.environment).toBe("production");
    expect(claims?.id.byteLength).toBe(16);
    expect(await verifyToken(TOKEN_SECRET, token, NOW + 21600)).toBeNull();
    expect(await verifyToken(TOKEN_SECRET, token, NOW + 99999)).toBeNull();
  });

  it("uses a fresh random ID for every token", async () => {
    const a = await verifyToken(TOKEN_SECRET, (await issueToken(TOKEN_SECRET, "production", 60, NOW)).token, NOW);
    const b = await verifyToken(TOKEN_SECRET, (await issueToken(TOKEN_SECRET, "production", 60, NOW)).token, NOW);
    expect(encodeBase64Url(a!.id)).not.toBe(encodeBase64Url(b!.id));
  });

  it("rejects any modified byte", async () => {
    const { token } = await issueToken(TOKEN_SECRET, "production", 3600, NOW);
    const bytes = decodeBase64Url(token)!;
    for (let i = 0; i < bytes.byteLength; i++) {
      const tampered = bytes.slice();
      tampered[i]! ^= 0x01;
      expect(await verifyToken(TOKEN_SECRET, encodeBase64Url(tampered), NOW), `byte ${i}`).toBeNull();
    }
  });

  it("rejects a later expiry or another environment re-signed with a different secret", async () => {
    const forged = await signToken("another-secret-that-is-long-enough-123", {
      id: new Uint8Array(16),
      expiresAt: NOW + 10 ** 6,
      environment: "production",
    });
    expect(await verifyToken(TOKEN_SECRET, forged, NOW)).toBeNull();
  });

  it("rejects malformed tokens", async () => {
    const { token } = await issueToken(TOKEN_SECRET, "production", 3600, NOW);
    for (const value of ["", token.slice(0, -1), `${token}A`, `${token.slice(0, -2)}==`, token.replace(/.$/, "+")]) {
      expect(await verifyToken(TOKEN_SECRET, value, NOW)).toBeNull();
    }
  });

  it("does not contain the App Attest keyId", async () => {
    await resetDatabase();
    const context = await createContext();
    const key = await registerKey(context);
    const bytes = decodeBase64Url(key.token)!;
    const haystack = Array.from(bytes).join(",");
    for (let length = 4; length <= 32; length += 4) {
      for (let offset = 0; offset + length <= 32; offset += 4) {
        expect(haystack).not.toContain(Array.from(key.keyId.subarray(offset, offset + length)).join(","));
      }
    }
  });
});

describe("Authorization on /v1/reports", () => {
  let context: TestContext;

  beforeEach(async () => {
    await resetDatabase();
    context = await createContext();
  });

  async function status(headers: Record<string, string>): Promise<{ status: number; body: unknown }> {
    const response = await context.fetch(
      new Request("https://reports.example/v1/reports", {
        method: "POST",
        headers: { "content-type": "application/json", ...headers },
        body: JSON.stringify(exampleReport(context.clock.seconds)),
      }),
    );
    return { status: response.status, body: await response.json() };
  }

  it("accepts a valid bearer token", async () => {
    const { token } = await makeToken(context);
    expect((await status({ authorization: `Bearer ${token}` })).status).toBe(202);
    expect((await status({ authorization: `bearer ${token}` })).status).toBe(202);
  });

  it("returns 401 invalid_token for missing, malformed, tampered, foreign or expired tokens", async () => {
    const { token } = await makeToken(context);
    const expired = await makeToken(context, { expiresIn: 0 });
    const foreign = await signToken("some-other-deployment-secret-0123456789", {
      id: new Uint8Array(16),
      expiresAt: context.clock.seconds + 60,
      environment: "production",
    });
    const tampered = token.slice(0, 10) + (token[10] === "A" ? "B" : "A") + token.slice(11);
    const cases: Record<string, string>[] = [
      {},
      { authorization: token },
      { authorization: `Basic ${token}` },
      { authorization: `Bearer ${token} extra` },
      { authorization: `Bearer ${tampered}` },
      { authorization: `Bearer ${foreign}` },
      { authorization: `Bearer ${expired.token}` },
    ];
    for (const headers of cases) {
      const result = await status(headers);
      expect(result.status).toBe(401);
      expect(result.body).toEqual({ error: "invalid_token" });
    }
    expect(context.reportsLimiter.keys).toEqual([]);
  });

  it("accepts a token until it expires", async () => {
    const { token } = await makeToken(context, { expiresIn: 10 });
    expect((await status({ authorization: `Bearer ${token}` })).status).toBe(202);
    context.clock.advance(10);
    expect((await status({ authorization: `Bearer ${token}` })).status).toBe(401);
  });

  it("rejects development tokens unless development is allowed", async () => {
    const { token } = await makeToken(context, { environment: "development" });
    expect((await status({ authorization: `Bearer ${token}` })).status).toBe(401);
    const devContext = await createContext({ ALLOW_DEVELOPMENT_ATTESTATION: "true" });
    const response = await devContext.fetch(reportRequest(token, exampleReport(devContext.clock.seconds)));
    expect(response.status).toBe(202);
  });
});
