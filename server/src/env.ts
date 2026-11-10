// SPDX-License-Identifier: Apache-2.0

/** Bindings declared in wrangler.jsonc, plus the TOKEN_SECRET secret. */
export interface Env {
  DB: D1Database;
  /** Keyed by the upload token's random ID. */
  REPORTS_RATE_LIMITER: RateLimit;
  /** Keyed by a fixed per-endpoint string ("challenge", "attest", "token"); never by IP. */
  AUTH_RATE_LIMITER: RateLimit;
  /** Set with `wrangler secret put TOKEN_SECRET`. */
  TOKEN_SECRET?: string;
  APPLE_TEAM_ID: string;
  APP_BUNDLE_ID: string;
  ALLOW_DEVELOPMENT_ATTESTATION: string;
  RETENTION_DAYS: string;
  TOKEN_TTL_SECONDS: string;
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
