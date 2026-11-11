// SPDX-License-Identifier: Apache-2.0

import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { verifyAssertion, VerificationError } from "../src/appattest";
import { encodeBase64, randomBytes, toHex } from "../src/encoding";
import { verifyToken } from "../src/token";
import { AAGUID_DEVELOPMENT, buildAssertion, exportRaw, generateKeyPair } from "./helpers/appattest";
import { encodeCbor } from "./helpers/cbor-encoder";
import {
  APP_ID,
  createContext,
  getChallenge,
  postJson,
  registerKey,
  resetDatabase,
  TOKEN_SECRET,
  type RegisteredKey,
  type TestContext,
} from "./helpers/context";

const CHALLENGE = "c2FtcGxlLWNoYWxsZW5nZS1zdHJpbmctZm9yLXRlc3Q";

describe("verifyAssertion", () => {
  let key: CryptoKeyPair;
  let publicKey: Uint8Array;

  beforeEach(async () => {
    key = await generateKeyPair("P-256");
    publicKey = await exportRaw(key.publicKey);
  });

  async function verify(options: { counter?: number; stored?: number; signWith?: CryptoKey; challenge?: string; appId?: string } = {}) {
    const assertion = await buildAssertion({
      privateKey: options.signWith ?? key.privateKey,
      challenge: options.challenge ?? CHALLENGE,
      appId: options.appId ?? APP_ID,
      counter: options.counter ?? 1,
    });
    return verifyAssertion({
      assertion,
      publicKey,
      storedSignCount: options.stored ?? 0,
      challenge: CHALLENGE,
      appId: APP_ID,
    });
  }

  async function expectReason(promise: Promise<unknown>, reason: string) {
    await expect(promise).rejects.toBeInstanceOf(VerificationError);
    await expect(promise).rejects.toMatchObject({ reason });
  }

  it("accepts a valid assertion and returns its counter", async () => {
    await expect(verify({ counter: 5, stored: 4 })).resolves.toBe(5);
  });

  it("rejects a signature by another key", async () => {
    const other = await generateKeyPair("P-256");
    await expectReason(verify({ signWith: other.privateKey }), "bad_signature");
  });

  it("rejects a signature over another challenge", async () => {
    await expectReason(verify({ challenge: "another-challenge" }), "bad_signature");
  });

  it("rejects a non-increasing counter", async () => {
    await expectReason(verify({ counter: 4, stored: 4 }), "counter_not_increasing");
    await expectReason(verify({ counter: 3, stored: 4 }), "counter_not_increasing");
  });

  it("rejects a wrong rpIdHash", async () => {
    await expectReason(verify({ appId: "TEAMID1234.com.example.other" }), "rp_id_mismatch");
  });

  it("fails closed with a VerificationError on corrupted input", async () => {
    const assertion = await buildAssertion({ privateKey: key.privateKey, challenge: CHALLENGE, appId: APP_ID, counter: 1 });
    for (let i = 0; i < assertion.byteLength; i++) {
      const corrupted = assertion.slice();
      corrupted[i]! ^= 0x41;
      const outcome = await verifyAssertion({
        assertion: corrupted,
        publicKey,
        storedSignCount: 0,
        challenge: CHALLENGE,
        appId: APP_ID,
      }).then(
        () => "accepted",
        (error: unknown) => (error instanceof VerificationError ? "rejected" : `threw ${String(error)}`),
      );
      expect(outcome, `byte ${i}`).toBe("rejected");
    }
  });

  it("rejects malformed assertions", async () => {
    const run = (assertion: Uint8Array) =>
      verifyAssertion({ assertion, publicKey, storedSignCount: 0, challenge: CHALLENGE, appId: APP_ID });
    await expectReason(run(new Uint8Array(40).fill(0xff)), "cbor_malformed");
    await expectReason(run(encodeCbor({ signature: randomBytes(70) })), "bad_structure");
    await expectReason(
      run(encodeCbor({ signature: randomBytes(70), authenticatorData: randomBytes(36) })),
      "auth_data_too_short",
    );
    await expectReason(
      run(encodeCbor({ signature: new Uint8Array(70), authenticatorData: randomBytes(37) })),
      "bad_signature_encoding",
    );
  });
});

describe("POST /v1/token", () => {
  let context: TestContext;
  let registered: RegisteredKey;

  beforeEach(async () => {
    await resetDatabase();
    context = await createContext();
    registered = await registerKey(context);
  });

  async function refresh(
    options: { counter: number; key?: RegisteredKey; signWith?: CryptoKey; ctx?: TestContext },
  ): Promise<Response> {
    const ctx = options.ctx ?? context;
    const key = options.key ?? registered;
    const challenge = await getChallenge(ctx);
    const assertion = await buildAssertion({
      privateKey: options.signWith ?? key.credentialKey.privateKey,
      challenge,
      appId: APP_ID,
      counter: options.counter,
    });
    return ctx.fetch(
      postJson("/v1/token", {
        keyId: encodeBase64(key.keyId),
        assertion: encodeBase64(assertion),
        challenge,
      }),
    );
  }

  async function storedCount(keyId: Uint8Array): Promise<number | null> {
    return env.DB.prepare("SELECT sign_count FROM attest_keys WHERE key_id = ?1")
      .bind(toHex(keyId))
      .first<number>("sign_count");
  }

  it("returns a new token and stores the counter", async () => {
    const response = await refresh({ counter: 1 });
    expect(response.status).toBe(200);
    const body = (await response.json()) as { token: string; expiresAt: number };
    expect(body.expiresAt).toBe(context.clock.seconds + 21600);
    expect(await verifyToken(TOKEN_SECRET, body.token, context.clock.seconds)).not.toBeNull();
    expect(body.token).not.toBe(registered.token);
    expect(await storedCount(registered.keyId)).toBe(1);

    expect((await refresh({ counter: 7 })).status).toBe(200);
    expect(await storedCount(registered.keyId)).toBe(7);
    expect(context.authLimiter.keys.filter((key) => key.startsWith("token:"))).toHaveLength(2);
  });

  it("rejects a non-increasing counter", async () => {
    expect((await refresh({ counter: 2 })).status).toBe(200);
    for (const counter of [2, 1, 0]) {
      const response = await refresh({ counter });
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "assertion_invalid" });
    }
    expect(await storedCount(registered.keyId)).toBe(2);
  });

  it("lets only one of two concurrent requests use the same counter", async () => {
    const requests = await Promise.all(
      [0, 1].map(async () => {
        const challenge = await getChallenge(context);
        const assertion = await buildAssertion({
          privateKey: registered.credentialKey.privateKey,
          challenge,
          appId: APP_ID,
          counter: 1,
        });
        return postJson("/v1/token", {
          keyId: encodeBase64(registered.keyId),
          assertion: encodeBase64(assertion),
          challenge,
        });
      }),
    );
    const statuses = (await Promise.all(requests.map((request) => context.fetch(request)))).map((r) => r.status);
    expect(statuses.sort()).toEqual([200, 401]);
    expect(await storedCount(registered.keyId)).toBe(1);
  });

  it("rejects a bad signature", async () => {
    const other = await generateKeyPair("P-256");
    const response = await refresh({ counter: 1, signWith: other.privateKey });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "assertion_invalid" });
    expect(await storedCount(registered.keyId)).toBe(0);
  });

  it("returns 404 unknown_key for an unregistered key", async () => {
    const stranger = await generateKeyPair("P-256");
    const strangerKeyId = randomBytes(32);
    const response = await refresh({
      counter: 1,
      key: { ...registered, keyId: strangerKeyId, credentialKey: stranger },
    });
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "unknown_key" });
  });

  it("rejects a replayed request: the counter, not the challenge, stops replays", async () => {
    const challenge = await getChallenge(context);
    const assertion = await buildAssertion({
      privateKey: registered.credentialKey.privateKey,
      challenge,
      appId: APP_ID,
      counter: 1,
    });
    const body = { keyId: encodeBase64(registered.keyId), assertion: encodeBase64(assertion), challenge };
    expect((await context.fetch(postJson("/v1/token", body))).status).toBe(200);
    const replayed = await context.fetch(postJson("/v1/token", body));
    expect(replayed.status).toBe(401);
    expect(await replayed.json()).toEqual({ error: "assertion_invalid" });
    expect(await storedCount(registered.keyId)).toBe(1);
  });

  it("returns 400 bad_challenge for a challenge the server did not issue", async () => {
    const assertion = await buildAssertion({
      privateKey: registered.credentialKey.privateKey,
      challenge: CHALLENGE,
      appId: APP_ID,
      counter: 1,
    });
    const response = await context.fetch(
      postJson("/v1/token", { keyId: encodeBase64(registered.keyId), assertion: encodeBase64(assertion), challenge: CHALLENGE }),
    );
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "bad_challenge" });
    expect(await storedCount(registered.keyId)).toBe(0);
  });

  it("returns 400 bad_request for malformed requests", async () => {
    const challenge = await getChallenge(context);
    for (const body of [
      { keyId: encodeBase64(registered.keyId), challenge },
      { keyId: "???", assertion: "AAAA", challenge },
      { keyId: encodeBase64(registered.keyId), assertion: "AAAA" },
      { keyId: encodeBase64(registered.keyId), assertion: "AAA", challenge },
    ]) {
      const response = await context.fetch(postJson("/v1/token", body));
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "bad_request" });
    }
  });

  it("stops refreshing development keys once development is switched off", async () => {
    const devContext = await createContext({ ALLOW_DEVELOPMENT_ATTESTATION: "true" });
    const devKey = await registerKey(devContext, { aaguid: AAGUID_DEVELOPMENT });
    const ok = await refresh({ counter: 1, key: devKey, ctx: devContext });
    expect(ok.status).toBe(200);
    const token = ((await ok.json()) as { token: string }).token;
    expect((await verifyToken(TOKEN_SECRET, token, devContext.clock.seconds))?.environment).toBe("development");

    const response = await refresh({ counter: 2, key: devKey });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "assertion_invalid" });
  });
});
