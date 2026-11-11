// SPDX-License-Identifier: Apache-2.0

import type { BudgetLimits } from "./budget";

/** Bindings declared in cloudflare.config.ts (and wrangler.jsonc for the tests). */
export interface Env {
  DB: D1Database;
  /** Keyed by the upload token's random ID. */
  REPORTS_RATE_LIMITER: RateLimit;
  /**
   * Counts verified attestations ("attest") and token refreshes per key ("token:" + a hash of the
   * keyId). Checked only after verification, so junk requests cannot use it up. Never keyed by IP.
   */
  AUTH_RATE_LIMITER: RateLimit;
  /** Uploaded with `cf deploy --secrets-file`; kept by later deploys. */
  TOKEN_SECRET?: string;
  APPLE_TEAM_ID: string;
  APP_BUNDLE_ID: string;
  ALLOW_DEVELOPMENT_ATTESTATION: string;
  RETENTION_DAYS: string;
  TOKEN_TTL_SECONDS: string;
  /** Rows written per UTC day by API requests (src/budget.ts). */
  DAILY_WRITE_LIMIT: string;
  /** Estimated bytes of new rows stored per UTC day (src/budget.ts). */
  DAILY_STORAGE_LIMIT_BYTES: string;
  /** New writes (and new challenges) are refused while the D1 database is larger than this. */
  MAX_DATABASE_BYTES: string;
}

/** Raised when a variable or secret is missing or invalid; reported as 500 server_misconfigured. */
export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

function parseInteger(name: string, value: string | undefined, min: number, max: number): number {
  if (value === undefined || !/^[0-9]+$/.test(value)) throw new ConfigError(`${name} must be an integer`);
  const number = Number(value);
  if (number < min || number > max) throw new ConfigError(`${name} must be within ${min}..${max}`);
  return number;
}

export function tokenSecret(env: Env): string {
  const secret = env.TOKEN_SECRET;
  if (typeof secret !== "string" || secret.length < 32) {
    throw new ConfigError("TOKEN_SECRET must be set and at least 32 characters long");
  }
  return secret;
}

/** "<APPLE_TEAM_ID>.<APP_BUNDLE_ID>", the App Attest relying-party ID. */
export function appId(env: Env): string {
  if (!/^[A-Z0-9]{10}$/.test(env.APPLE_TEAM_ID ?? "")) {
    throw new ConfigError("APPLE_TEAM_ID must be a 10-character Apple team ID");
  }
  if (!/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(env.APP_BUNDLE_ID ?? "")) {
    throw new ConfigError("APP_BUNDLE_ID must be a bundle identifier");
  }
  return `${env.APPLE_TEAM_ID}.${env.APP_BUNDLE_ID}`;
}

export function allowDevelopment(env: Env): boolean {
  return env.ALLOW_DEVELOPMENT_ATTESTATION === "true";
}

export function retentionDays(env: Env): number {
  return parseInteger("RETENTION_DAYS", env.RETENTION_DAYS, 1, 3650);
}

export function tokenTtlSeconds(env: Env): number {
  return parseInteger("TOKEN_TTL_SECONDS", env.TOKEN_TTL_SECONDS, 60, 7 * 24 * 3600);
}

export function budgetLimits(env: Env): BudgetLimits {
  return {
    rowsPerDay: parseInteger("DAILY_WRITE_LIMIT", env.DAILY_WRITE_LIMIT, 1, 10_000_000),
    storedBytesPerDay: parseInteger("DAILY_STORAGE_LIMIT_BYTES", env.DAILY_STORAGE_LIMIT_BYTES, 1, 10_000_000_000),
    maxDatabaseBytes: parseInteger("MAX_DATABASE_BYTES", env.MAX_DATABASE_BYTES, 1, 10_000_000_000),
  };
}
