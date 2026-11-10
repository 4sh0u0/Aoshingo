// SPDX-License-Identifier: Apache-2.0
//
// Returns the contact email address to the website's 「メールアドレスを表示」 button, but only after
// Cloudflare Turnstile has checked that the visitor is not a bot. The address lives in a Worker
// secret, so it appears in neither the repository nor the HTML that crawlers read.
//
// Privacy: the code reads no IP address or location header (CF-Connecting-IP, X-Forwarded-For,
// request.cf, ...), does not pass the visitor's IP to Siteverify, stores nothing and never logs.
// test/app.test.ts checks the source for this.

export interface Env {
  /** Secret key of the Turnstile widget. */
  TURNSTILE_SECRET_KEY?: string;
  /** The address to show. */
  CONTACT_EMAIL?: string;
  /** Comma-separated origins of the website, for example "https://4sh0u0.github.io". */
  ALLOWED_ORIGINS?: string;
  /** Comma-separated hostnames the Turnstile widget may be solved on, for example "4sh0u0.github.io". */
  ALLOWED_HOSTNAMES?: string;
  /** Workers Rate Limiting for successful verifications. */
  REVEAL_RATE_LIMITER: RateLimit;
}

export type Fetcher = (input: string, init: RequestInit) => Promise<Response>;

export const PATH = "/v1/email";
/** Must match the `action` the page passes to turnstile.render (site/public/assets/contact.js). */
export const TURNSTILE_ACTION = "show-email";
export const SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
/** Turnstile tokens are at most 2048 characters; the form body adds the field name and escaping. */
export const MAX_BODY_BYTES = 4096;
const MAX_TOKEN_LENGTH = 2048;
const SITEVERIFY_TIMEOUT_MS = 10_000;
const EMAIL_PATTERN = /^[^\s@"<>()]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/;

const BASE_HEADERS: Record<string, string> = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
  vary: "Origin",
};

interface SiteverifyResult {
  success?: unknown;
  hostname?: unknown;
  action?: unknown;
}

export async function handleRequest(
  request: Request,
  env: Env,
  fetcher: Fetcher = (input, init) => fetch(input, init),
): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname !== PATH) return reply(404, { error: "not_found" }, null);

  const origin = request.headers.get("origin");
  const allowedOrigin = origin !== null && split(env.ALLOWED_ORIGINS).includes(origin) ? origin : null;

  if (request.method === "OPTIONS") {
    if (allowedOrigin === null) return reply(403, { error: "forbidden_origin" }, null);
    return new Response(null, {
      status: 204,
      headers: {
        ...corsHeaders(allowedOrigin),
        "access-control-allow-methods": "POST",
        "access-control-allow-headers": "Content-Type",
        "access-control-max-age": "600",
        vary: "Origin",
      },
    });
  }
  if (request.method !== "POST") {
    return reply(405, { error: "method_not_allowed" }, allowedOrigin, { allow: "POST, OPTIONS" });
  }
  // Browsers always send Origin on a cross-origin POST. Turnstile is the real gate; this keeps
  // other websites from using the endpoint from their pages.
  if (allowedOrigin === null) return reply(403, { error: "forbidden_origin" }, null);

  const secret = env.TURNSTILE_SECRET_KEY;
  const email = env.CONTACT_EMAIL?.trim();
  if (!secret || !email || email.length > 254 || !EMAIL_PATTERN.test(email) || split(env.ALLOWED_HOSTNAMES).length === 0) {
    return reply(500, { error: "server_misconfigured" }, allowedOrigin);
  }

  // A form body keeps this a CORS "simple request", so the browser sends no preflight.
  const contentType = request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase();
  if (contentType !== "application/x-www-form-urlencoded") {
    return reply(415, { error: "unsupported_media_type" }, allowedOrigin);
  }
  const body = await readBodyLimited(request, MAX_BODY_BYTES);
  if (body === null) return reply(413, { error: "payload_too_large" }, allowedOrigin);
  const token = new URLSearchParams(body).get("token");
  if (!token || token.length > MAX_TOKEN_LENGTH) return reply(400, { error: "invalid_request" }, allowedOrigin);

  let result: SiteverifyResult;
  try {
    const response = await fetcher(SITEVERIFY_URL, {
      method: "POST",
      // No remoteip: the Worker does not read the visitor's IP address.
      body: new URLSearchParams({ secret, response: token }),
      signal: AbortSignal.timeout(SITEVERIFY_TIMEOUT_MS),
    });
    if (!response.ok) return reply(502, { error: "verification_unavailable" }, allowedOrigin);
    result = (await response.json()) as SiteverifyResult;
  } catch {
    return reply(502, { error: "verification_unavailable" }, allowedOrigin);
  }
  if (
    result === null ||
    typeof result !== "object" ||
    result.success !== true ||
    result.action !== TURNSTILE_ACTION ||
    typeof result.hostname !== "string" ||
    !split(env.ALLOWED_HOSTNAMES).includes(result.hostname)
  ) {
    return reply(403, { error: "verification_failed" }, allowedOrigin);
  }

  // Counted only after a successful verification, so requests with junk tokens cannot use it up.
  // The key is fixed (not the IP address): it caps how often the address is shown per minute.
  const { success } = await env.REVEAL_RATE_LIMITER.limit({ key: "reveal" });
  if (!success) return reply(429, { error: "rate_limited" }, allowedOrigin, { "retry-after": "60" });

  return reply(200, { email }, allowedOrigin);
}

function split(list: string | undefined): string[] {
  return (list ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item !== "");
}

function corsHeaders(origin: string): Record<string, string> {
  return { "access-control-allow-origin": origin };
}

function reply(
  status: number,
  body: unknown,
  allowedOrigin: string | null,
  extra: Record<string, string> = {},
): Response {
  const cors = allowedOrigin === null ? {} : corsHeaders(allowedOrigin);
  return new Response(JSON.stringify(body), { status, headers: { ...BASE_HEADERS, ...cors, ...extra } });
}

/** Reads at most `limit` bytes of the body as UTF-8, or returns null when it is larger. */
async function readBodyLimited(request: Request, limit: number): Promise<string | null> {
  const declared = request.headers.get("content-length");
  if (declared !== null && /^[0-9]+$/.test(declared) && Number(declared) > limit) return null;
  if (request.body === null) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}
