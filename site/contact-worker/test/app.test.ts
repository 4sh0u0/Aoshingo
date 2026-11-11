// SPDX-License-Identifier: Apache-2.0

import { describe, expect, it, vi } from "vitest";
import appSource from "../src/app.ts?raw";
import indexSource from "../src/index.ts?raw";
import { type Env, type Fetcher, handleRequest, MAX_BODY_BYTES, PATH, SITEVERIFY_URL, TURNSTILE_ACTION } from "../src/app";

const SITE = "https://aoshingo.4sh.es";
const ENDPOINT = `https://aoshingo-contact.example.workers.dev${PATH}`;
const EMAIL = "contact@example.com";
const TOKEN = "XXXX.DUMMY.TOKEN.XXXX";

function makeEnv(overrides: Partial<Env> = {}, allowReveal = true) {
  const limit = vi.fn(async (_options: { key: string }) => ({ success: allowReveal }));
  const env: Env = {
    TURNSTILE_SECRET_KEY: "1x0000000000000000000000000000000AA",
    CONTACT_EMAIL: EMAIL,
    ALLOWED_ORIGINS: SITE,
    ALLOWED_HOSTNAMES: "aoshingo.4sh.es",
    REVEAL_RATE_LIMITER: { limit },
    ...overrides,
  };
  return { env, limit };
}

function siteverify(result: unknown, status = 200) {
  return vi.fn<Fetcher>(async () => new Response(JSON.stringify(result), { status }));
}

const passed = { success: true, hostname: "aoshingo.4sh.es", action: TURNSTILE_ACTION };

function post(body: string = new URLSearchParams({ token: TOKEN }).toString(), headers: Record<string, string> = {}) {
  return new Request(ENDPOINT, {
    method: "POST",
    headers: { origin: SITE, "content-type": "application/x-www-form-urlencoded;charset=UTF-8", ...headers },
    body,
  });
}

async function errorOf(response: Response) {
  return ((await response.json()) as { error?: string }).error;
}

describe("POST /v1/email", () => {
  it("returns the address after a successful verification", async () => {
    const { env, limit } = makeEnv();
    const fetcher = siteverify(passed);
    const response = await handleRequest(post(), env, fetcher);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ email: EMAIL });
    expect(response.headers.get("access-control-allow-origin")).toBe(SITE);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("vary")).toBe("Origin");
    expect(limit).toHaveBeenCalledWith({ key: "reveal" });
  });

  it("sends only the secret and the token to Siteverify", async () => {
    const { env } = makeEnv();
    const fetcher = siteverify(passed);
    await handleRequest(post(), env, fetcher);

    expect(fetcher).toHaveBeenCalledTimes(1);
    const [url, init] = fetcher.mock.calls[0]!;
    expect(url).toBe(SITEVERIFY_URL);
    expect(init.method).toBe("POST");
    const sent = init.body as URLSearchParams;
    expect([...sent.keys()].sort()).toEqual(["response", "secret"]);
    expect(sent.get("response")).toBe(TOKEN);
    expect(sent.get("secret")).toBe(env.TURNSTILE_SECRET_KEY);
  });

  it.each([
    ["a failed challenge", { success: false, "error-codes": ["invalid-input-response"] }],
    ["another action", { ...passed, action: "login" }],
    ["no action", { success: true, hostname: "aoshingo.4sh.es" }],
    ["another hostname", { ...passed, hostname: "evil.example" }],
    ["no hostname", { success: true, action: TURNSTILE_ACTION }],
    ["a non-object body", "ok"],
  ])("rejects %s without showing the address", async (_name, result) => {
    const { env, limit } = makeEnv();
    const response = await handleRequest(post(), env, siteverify(result));

    expect(response.status).toBe(403);
    expect(await errorOf(response)).toBe("verification_failed");
    expect(limit).not.toHaveBeenCalled();
  });

  it("answers 502 when Siteverify cannot be reached or fails", async () => {
    const { env } = makeEnv();
    const throwing = vi.fn<Fetcher>(async () => {
      throw new TypeError("network");
    });
    const notJson = vi.fn<Fetcher>(async () => new Response("<html>", { status: 200 }));
    for (const fetcher of [throwing, siteverify(passed, 500), notJson]) {
      const response = await handleRequest(post(), env, fetcher);
      expect(response.status).toBe(502);
      expect(await errorOf(response)).toBe("verification_unavailable");
      expect(response.headers.get("access-control-allow-origin")).toBe(SITE);
    }
  });

  it("answers 429 when the rate limit is reached", async () => {
    const { env } = makeEnv({}, false);
    const response = await handleRequest(post(), env, siteverify(passed));

    expect(response.status).toBe(429);
    expect(await errorOf(response)).toBe("rate_limited");
    expect(response.headers.get("retry-after")).toBe("60");
  });

  it("rejects other origins without CORS headers", async () => {
    const { env } = makeEnv();
    for (const headers of [{ origin: "https://evil.example" }, { origin: "null" }]) {
      const fetcher = siteverify(passed);
      const response = await handleRequest(post(undefined, headers), env, fetcher);
      expect(response.status).toBe(403);
      expect(await errorOf(response)).toBe("forbidden_origin");
      expect(response.headers.get("access-control-allow-origin")).toBeNull();
      expect(fetcher).not.toHaveBeenCalled();
    }
    const withoutOrigin = new Request(ENDPOINT, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: `token=${TOKEN}`,
    });
    expect((await handleRequest(withoutOrigin, env, siteverify(passed))).status).toBe(403);
  });

  it("accepts every origin in the list", async () => {
    const { env } = makeEnv({ ALLOWED_ORIGINS: `${SITE}, https://aoshingo.example` });
    const response = await handleRequest(post(undefined, { origin: "https://aoshingo.example" }), env, siteverify(passed));
    expect(response.status).toBe(200);
    expect(response.headers.get("access-control-allow-origin")).toBe("https://aoshingo.example");
  });

  it("rejects bodies that are not a form", async () => {
    const { env } = makeEnv();
    const fetcher = siteverify(passed);
    const response = await handleRequest(
      post(JSON.stringify({ token: TOKEN }), { "content-type": "application/json" }),
      env,
      fetcher,
    );
    expect(response.status).toBe(415);
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("rejects missing, empty and oversized tokens and bodies", async () => {
    const { env } = makeEnv();
    const fetcher = siteverify(passed);
    for (const body of ["", "token=", "other=1", `token=${"a".repeat(2049)}`]) {
      const response = await handleRequest(post(body), env, fetcher);
      expect(response.status).toBe(400);
      expect(await errorOf(response)).toBe("invalid_request");
    }
    const large = await handleRequest(post(`token=${"a".repeat(MAX_BODY_BYTES)}`), env, fetcher);
    expect(large.status).toBe(413);
    expect(fetcher).not.toHaveBeenCalled();
  });

  it.each([
    ["no secret key", { TURNSTILE_SECRET_KEY: undefined }],
    ["no address", { CONTACT_EMAIL: undefined }],
    ["an invalid address", { CONTACT_EMAIL: "not an address" }],
    ["no hostnames", { ALLOWED_HOSTNAMES: "" }],
  ])("answers 500 with %s, without calling Siteverify", async (_name, overrides) => {
    const { env } = makeEnv(overrides);
    const fetcher = siteverify(passed);
    const response = await handleRequest(post(), env, fetcher);
    expect(response.status).toBe(500);
    expect(await errorOf(response)).toBe("server_misconfigured");
    expect(fetcher).not.toHaveBeenCalled();
  });
});

describe("other requests", () => {
  it("answers the CORS preflight for the website only", async () => {
    const { env } = makeEnv();
    const preflight = (origin: string) =>
      handleRequest(new Request(ENDPOINT, { method: "OPTIONS", headers: { origin } }), env, siteverify(passed));

    const allowed = await preflight(SITE);
    expect(allowed.status).toBe(204);
    expect(allowed.headers.get("access-control-allow-origin")).toBe(SITE);
    expect(allowed.headers.get("access-control-allow-methods")).toBe("POST");

    const denied = await preflight("https://evil.example");
    expect(denied.status).toBe(403);
    expect(denied.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("answers 405 to other methods and 404 to other paths", async () => {
    const { env } = makeEnv();
    const get = await handleRequest(new Request(ENDPOINT, { headers: { origin: SITE } }), env, siteverify(passed));
    expect(get.status).toBe(405);
    expect(get.headers.get("allow")).toBe("POST, OPTIONS");

    const other = await handleRequest(new Request("https://aoshingo-contact.example.workers.dev/"), env, siteverify(passed));
    expect(other.status).toBe(404);
  });
});

describe("privacy", () => {
  it("never reads the visitor's IP address or location and never logs", () => {
    // Comments may name the headers; the code may not.
    const withoutComments = (source: string) => source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
    for (const source of [appSource, indexSource].map(withoutComments)) {
      expect(source).toMatch(/handleRequest/);
      expect(source).not.toMatch(/cf-connecting-ip|x-forwarded-for|x-real-ip|cf-ipcountry|true-client-ip/i);
      expect(source).not.toMatch(/\.cf\b|remoteip:/);
      expect(source).not.toMatch(/console\./);
    }
  });
});
