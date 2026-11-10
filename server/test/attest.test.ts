// SPDX-License-Identifier: Apache-2.0

import { createExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { APPLE_APP_ATTESTATION_ROOT_CA_DER } from "../src/apple-root";
import { verifyAttestation, VerificationError, type AttestationInput } from "../src/appattest";
import { encodeBase64, randomBytes, toHex } from "../src/encoding";
import { verifyToken } from "../src/token";
import {
  AAGUID_DEVELOPMENT,
  buildAttestation,
  createFakePki,
  generateKeyPair,
  makeCertificate,
  name,
  type AttestationOptions,
  type FakePki,
} from "./helpers/appattest";
import { encodeCbor } from "./helpers/cbor-encoder";
import {
  APP_ID,
  createContext,
  getChallenge,
  postJson,
  registerKey,
  resetDatabase,
  TOKEN_SECRET,
  type TestContext,
} from "./helpers/context";

const CHALLENGE = "Vx8yQd2mZbqk0b3tq3l1wQ9lq0b1rS5mX0c2Yz7kP4A";
const DAY = 86_400_000;

let pki: FakePki;
const now = Date.now();

beforeAll(async () => {
  pki = await createFakePki(now);
});

async function attest(
  options: Partial<AttestationOptions> = {},
  input: Partial<AttestationInput> = {},
): Promise<Awaited<ReturnType<typeof verifyAttestation>>> {
  const built = await buildAttestation({ pki, challenge: CHALLENGE, appId: APP_ID, nowMs: now, ...options });
  return verifyAttestation({
    attestation: built.attestation,
    keyId: built.keyId,
    challenge: CHALLENGE,
    appId: APP_ID,
    allowDevelopment: false,
    nowMs: now,
    trustedRoot: pki.rootDer,
    ...input,
  });
}

async function expectReason(promise: Promise<unknown>, reason: string): Promise<void> {
  await expect(promise).rejects.toBeInstanceOf(VerificationError);
  await expect(promise).rejects.toMatchObject({ reason });
}

describe("verifyAttestation", () => {
  it("accepts a valid production attestation", async () => {
    const built = await buildAttestation({ pki, challenge: CHALLENGE, appId: APP_ID, nowMs: now });
    const result = await verifyAttestation({
      attestation: built.attestation,
      keyId: built.keyId,
      challenge: CHALLENGE,
      appId: APP_ID,
      allowDevelopment: false,
      nowMs: now,
      trustedRoot: pki.rootDer,
    });
    expect(result.environment).toBe("production");
    expect(toHex(result.publicKey)).toBe(toHex(built.publicKey));
  });

  it("accepts a development attestation only when allowed", async () => {
    await expect(attest({ aaguid: AAGUID_DEVELOPMENT }, { allowDevelopment: true })).resolves.toMatchObject({
      environment: "development",
    });
    await expectReason(attest({ aaguid: AAGUID_DEVELOPMENT }), "development_not_allowed");
  });

  it("rejects a nonce computed for another challenge", async () => {
    await expectReason(attest({ challenge: "a-different-challenge" }), "nonce_mismatch");
  });

  it("rejects a nonce extension with the wrong value", async () => {
    await expectReason(attest({ nonce: randomBytes(32) }), "nonce_mismatch");
  });

  it("rejects a credential certificate without the nonce extension", async () => {
    await expectReason(attest({ omitNonceExtension: true }), "nonce_extension_missing");
  });

  it("rejects a keyId that does not match the certificate key", async () => {
    await expectReason(attest({}, { keyId: randomBytes(32) }), "key_id_mismatch");
  });

  it("rejects a wrong rpIdHash", async () => {
    await expectReason(attest({ appId: "TEAMID1234.com.example.other" }), "rp_id_mismatch");
    await expectReason(attest({}, { appId: "OTHERTEAM1.io.github.4sh0u0.aoshingo" }), "rp_id_mismatch");
  });

  it("rejects a non-zero counter", async () => {
    await expectReason(attest({ counter: 1 }), "counter_not_zero");
  });

  it("rejects an unknown AAGUID", async () => {
    await expectReason(attest({ aaguid: new Uint8Array(16) }), "bad_aaguid");
    await expectReason(attest({ aaguid: AAGUID_DEVELOPMENT.map((byte, i) => (i === 15 ? 0 : byte)) }), "bad_aaguid");
  });

  it("rejects a credential ID that differs from keyId", async () => {
    await expectReason(attest({ credentialId: randomBytes(32) }), "credential_id_mismatch");
    await expectReason(attest({ credentialId: randomBytes(16) }), "credential_id_mismatch");
  });

  it("rejects a wrong format", async () => {
    await expectReason(attest({ fmt: "packed" }), "bad_format");
  });

  it("rejects malformed CBOR and structures", async () => {
    await expectReason(attest({}, { attestation: new Uint8Array(100).fill(0xff) }), "cbor_malformed");
    await expectReason(attest({}, { attestation: encodeCbor([1, 2]) }), "cbor_not_map");
    await expectReason(
      attest({}, { attestation: encodeCbor({ fmt: "apple-appattest", attStmt: {}, authData: "x" }) }),
      "bad_structure",
    );
  });

  it("fails closed with a VerificationError on corrupted input", async () => {
    const built = await buildAttestation({ pki, challenge: CHALLENGE, appId: APP_ID, nowMs: now });
    // Deterministic pseudo-random byte flips (xorshift32) and truncations.
    let state = 0x2545f491;
    const next = () => {
      state ^= state << 13;
      state ^= state >>> 17;
      state ^= state << 5;
      return (state >>> 0) / 2 ** 32;
    };
    for (let i = 0; i < 300; i++) {
      const corrupted = built.attestation.slice();
      if (i % 10 === 0) {
        corrupted.fill(0, Math.floor(next() * corrupted.byteLength));
      } else {
        corrupted[Math.floor(next() * corrupted.byteLength)]! ^= 1 + Math.floor(next() * 255);
      }
      const outcome = await verifyAttestation({
        attestation: corrupted,
        keyId: built.keyId,
        challenge: CHALLENGE,
        appId: APP_ID,
        allowDevelopment: false,
        nowMs: now,
        trustedRoot: pki.rootDer,
      }).then(
        () => "accepted",
        (error: unknown) => (error instanceof VerificationError ? "rejected" : `threw ${String(error)}`),
      );
      // A flip inside the receipt (not covered by any check) may still verify; nothing may crash.
      expect(["accepted", "rejected"], `iteration ${i}`).toContain(outcome);
    }
  });

  describe("certificate chain", () => {
    it("rejects an x5c with the wrong number of certificates", async () => {
      await expectReason(attest({ x5c: ([leaf]) => [leaf] }), "bad_x5c");
      await expectReason(attest({ x5c: ([leaf, ca]) => [leaf, ca, pki.rootDer] }), "bad_x5c");
    });

    it("rejects certificates in the wrong order", async () => {
      await expectReason(attest({ x5c: ([leaf, ca]) => [ca, leaf] }), "bad_chain");
    });

    it("rejects a chain that does not end in the trusted root", async () => {
      await expectReason(attest({}, { trustedRoot: APPLE_APP_ATTESTATION_ROOT_CA_DER }), "bad_chain");
      const otherPki = await createFakePki(now);
      await expectReason(attest({}, { trustedRoot: otherPki.rootDer }), "bad_chain");
    });

    it("rejects an intermediate from another root with the same name", async () => {
      const otherPki = await createFakePki(now);
      // Same names, different keys: only the signature check can catch this.
      await expectReason(
        attest({ pki: { ...otherPki, intermediateName: pki.intermediateName } }, { trustedRoot: pki.rootDer }),
        "bad_chain",
      );
    });

    it("rejects a credential certificate signed by an untrusted key", async () => {
      const rogue = await generateKeyPair("P-384");
      await expectReason(attest({ leafSigningKey: rogue.privateKey }), "bad_chain");
    });

    it("rejects an expired or not yet valid credential certificate", async () => {
      await expectReason(attest({ leafNotBefore: now - 10 * DAY, leafNotAfter: now - DAY }), "bad_chain");
      await expectReason(attest({ leafNotBefore: now + DAY, leafNotAfter: now + 10 * DAY }), "bad_chain");
    });

    it("rejects an expired intermediate", async () => {
      await expectReason(attest({}, { nowMs: now + 400 * DAY }), "bad_chain");
    });

    it("rejects an intermediate that is not a CA", async () => {
      const intermediateDer = await makeCertificate({
        serial: 9,
        issuer: pki.rootName,
        subject: pki.intermediateName,
        notBefore: now - DAY,
        notAfter: now + DAY,
        subjectPublicKey: pki.intermediate.publicKey,
        signingKey: pki.root.privateKey,
        hash: "SHA-384",
        isCA: false,
      });
      await expectReason(attest({ pki: { ...pki, intermediateDer } }), "bad_chain");
    });

    it("rejects an issuer name mismatch", async () => {
      await expectReason(attest({ pki: { ...pki, intermediateName: name("Someone else") } }), "bad_chain");
    });

    it("rejects garbage certificates", async () => {
      await expectReason(attest({ x5c: ([, ca]) => [new Uint8Array(300).fill(0x30), ca] }), "bad_chain");
    });
  });
});

describe("POST /v1/attest", () => {
  let context: TestContext;

  beforeEach(async () => {
    await resetDatabase();
    context = await createContext();
  });

  async function post(body: Record<string, unknown>, ctx = context): Promise<Response> {
    return ctx.fetch(postJson("/v1/attest", body));
  }

  it("registers the key and returns a token", async () => {
    const challenge = await getChallenge(context);
    const built = await buildAttestation({ pki: context.pki, challenge, appId: APP_ID });
    const response = await post({
      keyId: encodeBase64(built.keyId),
      attestation: encodeBase64(built.attestation),
      challenge,
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as { token: string; expiresAt: number };
    expect(Object.keys(body).sort()).toEqual(["expiresAt", "token"]);
    expect(body.expiresAt).toBe(context.clock.seconds + 21600);
    const claims = await verifyToken(TOKEN_SECRET, body.token, context.clock.seconds);
    expect(claims?.environment).toBe("production");
    expect(claims?.expiresAt).toBe(body.expiresAt);

    const row = await env.DB.prepare("SELECT * FROM attest_keys").first();
    expect(row).toEqual({
      key_id: toHex(built.keyId),
      public_key: toHex(built.publicKey),
      sign_count: 0,
      environment: "production",
      created_day: new Date(context.clock.ms).toISOString().slice(0, 10),
    });
    expect(context.authLimiter.keys).toEqual(["challenge", "attest"]);
  });

  it("returns 409 key_exists for an already registered key", async () => {
    const key = await registerKey(context);
    const challenge = await getChallenge(context);
    const again = await buildAttestation({
      pki: context.pki,
      challenge,
      appId: APP_ID,
      credentialKey: key.credentialKey,
    });
    expect(toHex(again.keyId)).toBe(toHex(key.keyId));
    const response = await post({
      keyId: encodeBase64(again.keyId),
      attestation: encodeBase64(again.attestation),
      challenge,
    });
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "key_exists" });
    expect(await env.DB.prepare("SELECT count(*) AS n FROM attest_keys").first("n")).toBe(1);
  });

  it("returns 401 attestation_invalid for a failing attestation", async () => {
    const challenge = await getChallenge(context);
    const built = await buildAttestation({ pki: context.pki, challenge, appId: APP_ID, counter: 3 });
    const response = await post({
      keyId: encodeBase64(built.keyId),
      attestation: encodeBase64(built.attestation),
      challenge,
    });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "attestation_invalid" });
    expect(await env.DB.prepare("SELECT count(*) AS n FROM attest_keys").first("n")).toBe(0);
  });

  it("rejects development keys unless ALLOW_DEVELOPMENT_ATTESTATION is true", async () => {
    const challenge = await getChallenge(context);
    const built = await buildAttestation({ pki: context.pki, challenge, appId: APP_ID, aaguid: AAGUID_DEVELOPMENT });
    const response = await post({
      keyId: encodeBase64(built.keyId),
      attestation: encodeBase64(built.attestation),
      challenge,
    });
    expect(response.status).toBe(401);

    const devContext = await createContext({ ALLOW_DEVELOPMENT_ATTESTATION: "true" });
    const key = await registerKey(devContext, { aaguid: AAGUID_DEVELOPMENT });
    expect((await verifyToken(TOKEN_SECRET, key.token, devContext.clock.seconds))?.environment).toBe(
      "development",
    );
    const row = await env.DB.prepare("SELECT environment FROM attest_keys WHERE key_id = ?1")
      .bind(toHex(key.keyId))
      .first("environment");
    expect(row).toBe("development");
  });

  it("returns 400 bad_request for malformed requests", async () => {
    const challenge = await getChallenge(context);
    const built = await buildAttestation({ pki: context.pki, challenge, appId: APP_ID });
    const valid = {
      keyId: encodeBase64(built.keyId),
      attestation: encodeBase64(built.attestation),
      challenge,
    };
    const cases: Request[] = [
      postJson("/v1/attest", { ...valid, keyId: undefined }),
      postJson("/v1/attest", { ...valid, keyId: "not base64!" }),
      postJson("/v1/attest", { ...valid, keyId: encodeBase64(randomBytes(31)) }),
      postJson("/v1/attest", { ...valid, keyId: toHex(built.keyId) }),
      postJson("/v1/attest", { ...valid, attestation: "" }),
      postJson("/v1/attest", { ...valid, attestation: 5 }),
      postJson("/v1/attest", { ...valid, challenge: undefined }),
      postJson("/v1/attest", "not json"),
      postJson("/v1/attest", [valid]),
      postJson("/v1/attest", valid, { "content-type": "text/plain" }),
      postJson("/v1/attest", { ...valid, padding: "x".repeat(70 * 1024) }),
    ];
    for (const request of cases) {
      const response = await context.fetch(request);
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "bad_request" });
    }
    // None of those consumed the challenge.
    const response = await post(valid);
    expect(response.status).toBe(200);
  });

  it("returns 400 bad_challenge for an unknown challenge", async () => {
    const built = await buildAttestation({ pki: context.pki, challenge: CHALLENGE, appId: APP_ID });
    const response = await post({
      keyId: encodeBase64(built.keyId),
      attestation: encodeBase64(built.attestation),
      challenge: CHALLENGE,
    });
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "bad_challenge" });
  });

  it("reports server_misconfigured without consuming the challenge", async () => {
    for (const overrides of [{ APPLE_TEAM_ID: "REPLACE_WITH_TEAM_ID" }, { TOKEN_SECRET: undefined }]) {
      const broken = await createContext(overrides);
      const challenge = await getChallenge(broken);
      const response = await broken.fetch(postJson("/v1/attest", { keyId: "", attestation: "", challenge }));
      expect(response.status).toBe(500);
      expect(await response.json()).toEqual({ error: "server_misconfigured" });
      expect(
        await env.DB.prepare("SELECT count(*) AS n FROM challenges WHERE challenge = ?1").bind(challenge).first("n"),
      ).toBe(1);
    }
  });

  it("uses the pinned Apple root in production, so a fake chain is rejected", async () => {
    const { createApp } = await import("../src/app");
    const production = createApp();
    const challenge = await getChallenge(context);
    const built = await buildAttestation({ pki: context.pki, challenge, appId: APP_ID });
    const response = await production.fetch(
      postJson("/v1/attest", {
        keyId: encodeBase64(built.keyId),
        attestation: encodeBase64(built.attestation),
        challenge,
      }),
      context.env,
      createExecutionContext(),
    );
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "attestation_invalid" });
  });
});
