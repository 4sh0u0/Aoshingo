// SPDX-License-Identifier: Apache-2.0

import { describe, expect, it } from "vitest";
import {
  APPLE_APP_ATTESTATION_ROOT_CA_DER,
  APPLE_APP_ATTESTATION_ROOT_CA_SHA256,
} from "../src/apple-root";
import { sha256, toHex } from "../src/encoding";
import { parseCertificate, verifySignedBy } from "../src/x509";

describe("pinned Apple App Attestation Root CA", () => {
  it("has the published SHA-256 fingerprint", async () => {
    const fingerprint = toHex(await sha256(APPLE_APP_ATTESTATION_ROOT_CA_DER));
    // openssl x509 -in Apple_App_Attestation_Root_CA.pem -noout -fingerprint -sha256
    expect(fingerprint).toBe(
      "1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32"
        .replaceAll(":", "")
        .toLowerCase(),
    );
    expect(fingerprint).toBe(APPLE_APP_ATTESTATION_ROOT_CA_SHA256);
  });

  it("parses as a self-signed P-384 CA valid until 2045", async () => {
    const root = parseCertificate(APPLE_APP_ATTESTATION_ROOT_CA_DER);
    expect(root.curve).toBe("P-384");
    expect(root.signatureHash).toBe("SHA-384");
    expect(root.isCA).toBe(true);
    expect(new Date(root.notBefore).toISOString()).toBe("2020-03-18T18:32:53.000Z");
    expect(new Date(root.notAfter).toISOString()).toBe("2045-03-15T00:00:00.000Z");
    expect(toHex(root.issuer)).toBe(toHex(root.subject));
    expect(await verifySignedBy(root, root)).toBe(true);
  });
});
