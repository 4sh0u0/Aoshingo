// SPDX-License-Identifier: Apache-2.0

import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { decodeBase64Url, encodeBase64, encodeBase64Url, toHex } from "../src/encoding";
import {
  createContext,
  exampleReport,
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
    // The row ID is random, not derived from the token.
    expect(results[0]!.id).toMatch(/^[0-9a-f]{32}$/);
    expect(results[0]!.id).not.toBe(toHex(tokenIdBytes));
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
    const response = await failing.fetch(new Request("https://reports.example/v1/challenge", { method: "POST" }));
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
