// SPDX-License-Identifier: Apache-2.0

// Request routing and handlers for the field-data API (docs/field-data-api.md).
//
// Privacy: this file never reads client IP or location headers (CF-Connecting-IP,
// X-Forwarded-For, CF-IPCountry, request.cf, ...) and never logs anything.

import { APPLE_APP_ATTESTATION_ROOT_CA_DER } from "./apple-root";
import { verifyAssertion, verifyAttestation, VerificationError, type AttestEnvironment } from "./appattest";
import { deleteOldUsage, reserveWrites } from "./budget";
import { issueChallenge, verifyChallenge } from "./challenge";
import { decodeBase64, encodeBase64Url, fromHex, toHex } from "./encoding";
import {
  allowDevelopment,
  appId,
  budgetLimits,
  ConfigError,
  retentionDays,
  tokenSecret,
  tokenTtlSeconds,
  type Env,
} from "./env";
import { errorResponse, HttpError, isJsonContentType, json, parseJson, readBodyLimited } from "./http";
import { MAX_REPORT_BYTES, validateReport } from "./report";
import { foldExpiredReports, reportPayloads, ROWS_WRITTEN_PER_INTERSECTION, storeReport, utcDay } from "./storage";
import { issueToken, verifyToken } from "./token";

/** Attest/token request bodies are small; anything bigger is not a genuine client. */
const MAX_AUTH_BODY_BYTES = 64 * 1024;

/** daily_usage rows older than this many days are deleted by the cron. */
const USAGE_KEEP_DAYS = 7;

export interface AppOptions {
  /**
   * Test-only: DER of the root that attestation chains must end in. Production never sets this
   * and always uses the pinned Apple App Attestation Root CA.
   */
  attestationRootForTesting?: Uint8Array;
  /** Test-only clock in milliseconds. */
  now?: () => number;
}

export interface App {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response>;
  scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void>;
}

type Handler = (request: Request, env: Env, nowMs: number) => Promise<Response>;

interface Route {
  method: "GET" | "POST";
  handler: Handler;
}

export function createApp(options: AppOptions = {}): App {
  const now = options.now ?? (() => Date.now());
  const trustedRoot = options.attestationRootForTesting ?? APPLE_APP_ATTESTATION_ROOT_CA_DER;

  async function rateLimit(limiter: RateLimit, key: string): Promise<void> {
    const { success } = await limiter.limit({ key });
    if (!success) throw new HttpError(429, "rate_limited");
  }

  /** Reads a JSON object body for /v1/attest and /v1/token; any problem is bad_request. */
  async function readAuthBody(request: Request): Promise<Record<string, unknown>> {
    if (!isJsonContentType(request.headers.get("content-type"))) throw new HttpError(400, "bad_request");
    const body = await readBodyLimited(request, MAX_AUTH_BODY_BYTES);
    if (body === null) throw new HttpError(400, "bad_request");
    const parsed = parseJson(body);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new HttpError(400, "bad_request");
    }
    return parsed as Record<string, unknown>;
  }

  function decodeKeyId(value: unknown): Uint8Array {
    const keyId = typeof value === "string" ? decodeBase64(value) : null;
    if (keyId === null || keyId.byteLength !== 32) throw new HttpError(400, "bad_request");
    return keyId;
  }

  function decodeBlob(value: unknown): Uint8Array {
    const bytes = typeof value === "string" ? decodeBase64(value) : null;
    if (bytes === null || bytes.byteLength === 0) throw new HttpError(400, "bad_request");
    return bytes;
  }

  /** Rate-limit key for one App Attest key: a hash, so the limiter never sees the keyId itself. */
  async function keyLimitKey(keyId: Uint8Array): Promise<string> {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", keyId));
    return `token:${encodeBase64Url(digest.subarray(0, 16))}`;
  }

  async function checkChallenge(env: Env, challenge: unknown, nowMs: number): Promise<string> {
    if (typeof challenge !== "string") throw new HttpError(400, "bad_request");
    if (!(await verifyChallenge(tokenSecret(env), challenge, Math.floor(nowMs / 1000)))) {
      throw new HttpError(400, "bad_challenge");
    }
    return challenge;
  }

  async function tokenResponse(env: Env, environment: AttestEnvironment, nowMs: number): Promise<Response> {
    const { token, expiresAt } = await issueToken(
      tokenSecret(env),
      environment,
      tokenTtlSeconds(env),
      Math.floor(nowMs / 1000),
    );
    return json(200, { token, expiresAt });
  }

  const health: Handler = async () => json(200, { ok: true });

  // Signed, not stored, so it costs no D1 write and needs no rate limit: a limit keyed without
  // the client's address would only let one client lock everybody else out.
  const challenge: Handler = async (_request, env, nowMs) => {
    const issued = await issueChallenge(tokenSecret(env), Math.floor(nowMs / 1000));
    return json(201, issued);
  };

  const attest: Handler = async (request, env, nowMs) => {
    // Read the configuration first, so a misconfigured server answers 500 for every request.
    const id = appId(env);
    tokenSecret(env);
    tokenTtlSeconds(env);
    const limits = budgetLimits(env);

    const body = await readAuthBody(request);
    const keyId = decodeKeyId(body.keyId);
    const attestation = decodeBlob(body.attestation);
    const challenge = await checkChallenge(env, body.challenge, nowMs);

    let result;
    try {
      result = await verifyAttestation({
        attestation,
        keyId,
        challenge,
        appId: id,
        allowDevelopment: allowDevelopment(env),
        nowMs,
        trustedRoot,
      });
    } catch (error) {
      if (error instanceof VerificationError) throw new HttpError(401, "attestation_invalid");
      throw error;
    }

    // Only verified attestations count, so junk requests cannot lock out genuine clients.
    await rateLimit(env.AUTH_RATE_LIMITER, "attest");
    await reserveWrites(env.DB, limits, utcDay(nowMs), 1);

    // Stored apart from report data; created_day is coarse on purpose.
    const inserted = await env.DB.prepare(
      `INSERT INTO attest_keys (key_id, public_key, sign_count, environment, created_day)
       VALUES (?1, ?2, 0, ?3, ?4) ON CONFLICT (key_id) DO NOTHING`,
    )
      .bind(toHex(keyId), toHex(result.publicKey), result.environment, utcDay(nowMs))
      .run();
    if (inserted.meta.changes !== 1) throw new HttpError(409, "key_exists");

    return tokenResponse(env, result.environment, nowMs);
  };

  const token: Handler = async (request, env, nowMs) => {
    const id = appId(env);
    tokenSecret(env);
    tokenTtlSeconds(env);
    const limits = budgetLimits(env);

    const body = await readAuthBody(request);
    const keyId = decodeKeyId(body.keyId);
    const assertion = decodeBlob(body.assertion);
    const challenge = await checkChallenge(env, body.challenge, nowMs);

    const keyIdHex = toHex(keyId);
    const key = await env.DB.prepare(
      "SELECT public_key, sign_count, environment FROM attest_keys WHERE key_id = ?1",
    )
      .bind(keyIdHex)
      .first<{ public_key: string; sign_count: number; environment: AttestEnvironment }>();
    if (key === null) throw new HttpError(404, "unknown_key");
    if (key.environment === "development" && !allowDevelopment(env)) {
      throw new HttpError(401, "assertion_invalid");
    }
    const publicKey = fromHex(key.public_key);
    if (publicKey === null) throw new Error("corrupt public key");

    let counter: number;
    try {
      counter = await verifyAssertion({
        assertion,
        publicKey,
        storedSignCount: key.sign_count,
        challenge,
        appId: id,
      });
    } catch (error) {
      if (error instanceof VerificationError) throw new HttpError(401, "assertion_invalid");
      throw error;
    }

    // Per key, and only once the assertion is verified.
    await rateLimit(env.AUTH_RATE_LIMITER, await keyLimitKey(keyId));
    await reserveWrites(env.DB, limits, utcDay(nowMs), 1);

    // Compare-and-set, so two concurrent requests cannot both use the same counter value.
    const updated = await env.DB.prepare(
      "UPDATE attest_keys SET sign_count = ?1 WHERE key_id = ?2 AND sign_count < ?1",
    )
      .bind(counter, keyIdHex)
      .run();
    if (updated.meta.changes !== 1) throw new HttpError(401, "assertion_invalid");

    return tokenResponse(env, key.environment, nowMs);
  };

  const reports: Handler = async (request, env, nowMs) => {
    const nowSeconds = Math.floor(nowMs / 1000);
    const secret = tokenSecret(env);
    const limits = budgetLimits(env);
    const authorization = request.headers.get("authorization");
    const match = authorization === null ? null : /^Bearer ([^\s]+)$/i.exec(authorization);
    const claims = match === null ? null : await verifyToken(secret, match[1]!, nowSeconds);
    if (claims === null) throw new HttpError(401, "invalid_token");
    // Tokens from development attestations stop working once development is switched off.
    if (claims.environment === "development" && !allowDevelopment(env)) {
      throw new HttpError(401, "invalid_token");
    }

    await rateLimit(env.REPORTS_RATE_LIMITER, encodeBase64Url(claims.id));

    if (!isJsonContentType(request.headers.get("content-type"))) {
      throw new HttpError(415, "unsupported_media_type");
    }
    const body = await readBodyLimited(request, MAX_REPORT_BYTES);
    if (body === null) throw new HttpError(413, "too_large");
    const result = validateReport(parseJson(body), nowSeconds);
    if (!result.ok) throw new HttpError(400, "invalid_report");

    const { intersections } = result.report;
    const payloads = reportPayloads(result.report);
    await reserveWrites(
      env.DB,
      limits,
      utcDay(nowMs),
      intersections.length * ROWS_WRITTEN_PER_INTERSECTION,
      payloads.reduce((sum, payload) => sum + payload.length, 0),
    );
    await storeReport(env.DB, result.report, nowMs, payloads);
    return json(202, {
      accepted: {
        intersections: intersections.length,
        observations: intersections.reduce((sum, item) => sum + item.observations.length, 0),
        transitions: intersections.reduce((sum, item) => sum + item.transitions.length, 0),
      },
    });
  };

  const routes: Record<string, Route> = {
    "/v1/health": { method: "GET", handler: health },
    "/v1/challenge": { method: "POST", handler: challenge },
    "/v1/attest": { method: "POST", handler: attest },
    "/v1/token": { method: "POST", handler: token },
    "/v1/reports": { method: "POST", handler: reports },
  };

  return {
    async fetch(request, env) {
      const { pathname } = new URL(request.url);
      const route = Object.hasOwn(routes, pathname) ? routes[pathname] : undefined;
      if (route === undefined) return errorResponse(404, "not_found");
      if (request.method !== route.method) {
        return errorResponse(405, "method_not_allowed", { allow: route.method });
      }
      try {
        return await route.handler(request, env, now());
      } catch (error) {
        if (error instanceof HttpError) return errorResponse(error.status, error.code);
        if (error instanceof ConfigError) return errorResponse(500, "server_misconfigured");
        // Deliberately not logged: observability is off and errors could echo request data.
        return errorResponse(500, "internal_error");
      }
    },

    async scheduled(_controller, env) {
      const nowMs = now();
      await deleteOldUsage(env.DB, utcDay(nowMs - USAGE_KEEP_DAYS * 86_400_000));
      const cutoffDay = utcDay(nowMs - retentionDays(env) * 86_400_000);
      await foldExpiredReports(env.DB, cutoffDay);
    },
  };
}
