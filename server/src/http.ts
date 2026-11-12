// SPDX-License-Identifier: Apache-2.0

const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
};

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return jsonText(status, JSON.stringify(body), headers);
}

/** A response whose body is already JSON text. */
export function jsonText(status: number, body: string, headers: Record<string, string> = {}): Response {
  return new Response(body, { status, headers: { ...JSON_HEADERS, ...headers } });
}

export function errorResponse(status: number, code: string, headers?: Record<string, string>): Response {
  return json(status, { error: code }, headers);
}

/** Carries an HTTP error out of nested helpers. */
export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
    this.name = "HttpError";
  }
}

/** True for `application/json`, optionally with `charset=utf-8`. */
export function isJsonContentType(header: string | null): boolean {
  if (header === null) return false;
  const [type, ...parameters] = header.split(";").map((part) => part.trim().toLowerCase());
  if (type !== "application/json") return false;
  for (const parameter of parameters) {
    const [name, value] = parameter.split("=").map((part) => part.trim());
    if (name === "charset" && value?.replace(/^"|"$/g, "") !== "utf-8") return false;
  }
  return true;
}

/**
 * Reads at most `limit` bytes of the body. Returns null when the body (or its declared
 * Content-Length) is larger, without buffering the excess.
 */
export async function readBodyLimited(request: Request, limit: number): Promise<Uint8Array | null> {
  const declared = request.headers.get("content-length");
  if (declared !== null && /^[0-9]+$/.test(declared) && Number(declared) > limit) return null;
  if (request.body === null) return new Uint8Array(0);
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
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

const strictUtf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });

/** Parses a UTF-8 JSON body; returns undefined when it is not valid UTF-8 or JSON. */
export function parseJson(body: Uint8Array): unknown {
  try {
    return JSON.parse(strictUtf8.decode(body));
  } catch {
    return undefined;
  }
}
