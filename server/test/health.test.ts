// SPDX-License-Identifier: Apache-2.0

import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { budgetLimits } from "../src/env";
import { BASE } from "./helpers/context";

describe("routing (deployed entry point)", () => {
  it("GET /v1/health returns ok", async () => {
    const response = await exports.default.fetch(`${BASE}/v1/health`);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ ok: true });
  });

  it("rejects other methods with 405", async () => {
    const response = await exports.default.fetch(`${BASE}/v1/health`, { method: "POST" });
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("GET");
    expect(await response.json()).toEqual({ error: "method_not_allowed" });

    const challenge = await exports.default.fetch(`${BASE}/v1/challenge`);
    expect(challenge.status).toBe(405);
    expect(challenge.headers.get("allow")).toBe("POST");
  });

  it("returns 404 for unknown paths", async () => {
    for (const path of ["/", "/v1", "/v1/health/", "/v2/health", "/v1/constructor", "/v1/__proto__"]) {
      const response = await exports.default.fetch(`${BASE}${path}`);
      expect(response.status, path).toBe(404);
      expect(await response.json()).toEqual({ error: "not_found" });
    }
  });

  it("issues a challenge through the real bindings", async () => {
    const response = await exports.default.fetch(`${BASE}/v1/challenge`, { method: "POST" });
    expect(response.status).toBe(201);
    const body = (await response.json()) as { challenge: string; expiresAt: number };
    expect(body.challenge).toMatch(/^[A-Za-z0-9_-]{76}$/);
  });

  it("has the budget variables declared in wrangler.jsonc", () => {
    expect(budgetLimits(env)).toEqual({
      rowsPerDay: 30_000,
      payloadBytesPerDay: 3_000_000,
      maxDatabaseBytes: 450_000_000,
    });
  });

  it("has the rate-limit bindings declared in wrangler.jsonc", async () => {
    expect(await env.REPORTS_RATE_LIMITER.limit({ key: "probe" })).toEqual({ success: true });
    expect(await env.AUTH_RATE_LIMITER.limit({ key: "probe" })).toEqual({ success: true });
  });
});
