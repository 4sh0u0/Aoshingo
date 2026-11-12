// SPDX-License-Identifier: Apache-2.0

// The deploy configuration (cloudflare.config.ts, read by `cf`) and the test configuration
// (wrangler.jsonc, read by @cloudflare/vitest-plugin) must describe the same Worker, or the tests
// would check something other than what gets deployed. CI also runs `cf build`, which fails on an
// invalid deploy configuration.

import { describe, expect, it } from "vitest";
import deployConfig from "../cloudflare.config";
import packageJson from "../package.json";
import { DAILY_CRON } from "../src/cron";
import { TIMING_CRON } from "../src/timing";
import wranglerText from "../wrangler.jsonc?raw";

/** Parses JSON with comments and trailing commas (JSONC), as wrangler.jsonc uses. */
function parseJsonc(text: string): unknown {
  let out = "";
  let inString = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i]!;
    if (inString) {
      out += char;
      if (char === "\\") out += text[++i] ?? "";
      else if (char === '"') inString = false;
    } else if (char === '"') {
      inString = true;
      out += char;
    } else if (char === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++;
      out += "\n";
    } else if (char === "/" && text[i + 1] === "*") {
      i = text.indexOf("*/", i + 2) + 1;
      if (i === 0) throw new Error("unterminated comment");
    } else {
      out += char;
    }
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
}

interface Wrangler {
  name: string;
  main: string;
  compatibility_date: string;
  compatibility_flags?: string[];
  workers_dev: boolean;
  preview_urls: boolean;
  routes: { pattern: string; custom_domain: boolean }[];
  observability: unknown;
  d1_databases: { binding: string; database_name: string; database_id: string; migrations_dir: string }[];
  ratelimits: { name: string; namespace_id: string; simple: { limit: number; period: number } }[];
  vars: Record<string, string>;
  triggers: { crons: string[] };
}

type Binding =
  | { type: "text"; value: string }
  | { type: "secret" }
  | { type: "d1"; name: string; id: string }
  | { type: "rate-limit"; namespace: string; simple: { limit: number; period: number } };

const wrangler = parseJsonc(wranglerText) as Wrangler;
const worker = (deployConfig as unknown as {
  worker: {
    name: string;
    entrypoint: string;
    compatibilityDate: string;
    compatibilityFlags?: string[];
    workersDev: boolean;
    previewUrls: boolean;
    domains: string[];
    observability: { enabled: boolean; logs: { enabled: boolean; invocationLogs: boolean }; traces: { enabled: boolean } };
    triggers: { type: string; schedule?: string }[];
    env: Record<string, Binding>;
  };
}).worker;
const bindings = Object.entries(worker.env);

function ofType<T extends Binding["type"]>(type: T): [string, Extract<Binding, { type: T }>][] {
  return bindings.filter((entry): entry is [string, Extract<Binding, { type: T }>] => entry[1].type === type);
}

describe("cloudflare.config.ts and wrangler.jsonc", () => {
  it("name the same Worker, entry point and compatibility settings", () => {
    expect(wrangler.name).toBe(worker.name);
    expect(wrangler.main).toBe(worker.entrypoint);
    expect(wrangler.compatibility_date).toBe(worker.compatibilityDate);
    expect(wrangler.compatibility_flags ?? []).toEqual(worker.compatibilityFlags ?? []);
    expect(wrangler.workers_dev).toBe(worker.workersDev);
    expect(wrangler.preview_urls).toBe(worker.previewUrls);
  });

  it("serve the same custom domain, and keep workers.dev on for builds made before it", () => {
    expect(worker.domains).toEqual(["api.aoshingo.4sh.es"]);
    expect(wrangler.routes).toEqual(worker.domains.map((pattern) => ({ pattern, custom_domain: true })));
    expect(worker.workersDev).toBe(true);
  });

  it("both turn off logs, invocation logs and traces", () => {
    expect(worker.observability).toEqual({
      enabled: false,
      logs: { enabled: false, invocationLogs: false },
      traces: { enabled: false },
    });
    expect(wrangler.observability).toEqual({
      enabled: false,
      logs: { enabled: false, invocation_logs: false },
      traces: { enabled: false },
    });
  });

  it("have the same variables", () => {
    expect(wrangler.vars).toEqual(Object.fromEntries(ofType("text").map(([name, binding]) => [name, binding.value])));
  });

  it("declare TOKEN_SECRET only as a secret", () => {
    expect(ofType("secret").map(([name]) => name)).toEqual(["TOKEN_SECRET"]);
    expect(wrangler.vars).not.toHaveProperty("TOKEN_SECRET");
  });

  it("bind the same D1 database, and the deploy script migrates that one from migrations/", () => {
    const d1 = ofType("d1");
    expect(d1).toHaveLength(1);
    const [binding, database] = d1[0]!;
    expect(wrangler.d1_databases).toEqual([
      { binding, database_name: database.name, database_id: database.id, migrations_dir: "migrations" },
    ]);
    expect(packageJson.scripts.deploy).toBe(`cf d1 migrations apply ${database.id} --dir migrations && cf deploy`);
  });

  it("have the same rate limits", () => {
    const expected = ofType("rate-limit").map(([name, binding]) => ({
      name,
      namespace_id: binding.namespace,
      simple: binding.simple,
    }));
    expect(expected).toHaveLength(2);
    expect(wrangler.ratelimits).toEqual(expected);
  });

  it("have the same cron triggers and nothing else, the two that scheduled() dispatches on", () => {
    expect(worker.triggers.every((trigger) => trigger.type === "scheduled")).toBe(true);
    expect(wrangler.triggers.crons).toEqual(worker.triggers.map((trigger) => trigger.schedule));
    expect(wrangler.triggers.crons).toEqual(["0 18 * * *", "30 18 * * *"]);
    expect(wrangler.triggers.crons).toEqual([DAILY_CRON, TIMING_CRON]);
  });

  it("declare every binding in one of the checks above", () => {
    expect(new Set(bindings.map(([, binding]) => binding.type))).toEqual(new Set(["text", "secret", "d1", "rate-limit"]));
    const wranglerKeys = Object.keys(wrangler).sort();
    expect(wranglerKeys).toEqual(
      [
        "$schema",
        "compatibility_date",
        "d1_databases",
        "main",
        "name",
        "observability",
        "preview_urls",
        "ratelimits",
        "routes",
        "triggers",
        "vars",
        "workers_dev",
      ].sort(),
    );
  });
});
