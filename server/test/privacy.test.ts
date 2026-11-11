// SPDX-License-Identifier: Apache-2.0

import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { decodeBase64Url, encodeBase64, encodeBase64Url, toHex } from "../src/encoding";
import {
  createContext,
  exampleReport,
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
      "client",
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
