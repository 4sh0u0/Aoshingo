// SPDX-License-Identifier: Apache-2.0

import { describe, expect, it } from "vitest";
import { CborError, decodeCbor } from "../src/cbor";
import { DerError, ecdsaDerToRaw, parseDer } from "../src/der";
import { decodeBase64, decodeBase64Url, encodeBase64Url, fromHex } from "../src/encoding";
import { encodeCbor } from "./helpers/cbor-encoder";

const hex = (text: string) => fromHex(text.replaceAll(" ", ""))!;

describe("CBOR decoder", () => {
  it("decodes the shapes App Attest uses", () => {
    const value = decodeCbor(
      encodeCbor({ fmt: "apple-appattest", attStmt: { x5c: [Uint8Array.of(1, 2)] }, n: -7, big: 70000 }),
    );
    expect(value).toBeInstanceOf(Map);
    const map = value as Map<string, unknown>;
    expect(map.get("fmt")).toBe("apple-appattest");
    expect(map.get("n")).toBe(-7);
    expect(map.get("big")).toBe(70000);
    expect(((map.get("attStmt") as Map<string, unknown>).get("x5c") as Uint8Array[])[0]).toEqual(
      Uint8Array.of(1, 2),
    );
    expect(decodeCbor(hex("f4"))).toBe(false);
    expect(decodeCbor(hex("f5"))).toBe(true);
    expect(decodeCbor(hex("f6"))).toBe(null);
    expect(decodeCbor(hex("1b 0000000100000000"))).toBe(2 ** 32);
  });

  it.each([
    ["empty input", ""],
    ["trailing bytes", "01 02"],
    ["truncated byte string", "44 0102"],
    ["indefinite-length byte string", "5f 41 01 ff"],
    ["indefinite-length map", "bf ff"],
    ["tag", "c0 01"],
    ["float", "f9 3c00"],
    ["duplicate map key", "a2 61 61 01 61 61 02"],
    ["byte-string map key", "a1 41 00 01"],
    ["invalid UTF-8", "62 c3 28"],
    ["huge declared array", "9a ffffffff"],
    ["integer beyond 2^53", "1b ffffffffffffffff"],
    ["deep nesting", "81".repeat(40) + "01"],
  ])("rejects %s", (_name, input) => {
    expect(() => decodeCbor(hex(input))).toThrow(CborError);
  });
});

describe("DER reader", () => {
  it("rejects non-DER lengths and trailing data", () => {
    expect(() => parseDer(hex("30 80 0000"))).toThrow(DerError); // indefinite
    expect(() => parseDer(hex("04 81 01 00"))).toThrow(DerError); // non-minimal long form
    expect(() => parseDer(hex("04 82 0001 00"))).toThrow(DerError); // leading zero length byte
    expect(() => parseDer(hex("04 01 00 00"))).toThrow(DerError); // trailing data
    expect(() => parseDer(hex("04 05 00"))).toThrow(DerError); // truncated
    expect(() => parseDer(hex("1f 01 00"))).toThrow(DerError); // high tag number
  });

  it("converts ECDSA signatures to fixed-size r||s", () => {
    // r = 0x80 (needs a sign byte), s = 0x01
    const raw = ecdsaDerToRaw(hex("30 07 02 02 0080 02 01 01"), 4);
    expect(Array.from(raw)).toEqual([0, 0, 0, 0x80, 0, 0, 0, 1]);
    expect(() => ecdsaDerToRaw(hex("30 06 02 01 80 02 01 01"), 4)).toThrow(DerError); // negative
    expect(() => ecdsaDerToRaw(hex("30 07 02 02 0001 02 01 01"), 4)).toThrow(DerError); // padded
    expect(() => ecdsaDerToRaw(hex("30 08 02 03 010203 02 01 01"), 2)).toThrow(DerError); // too long
  });
});

describe("base64", () => {
  it("accepts only canonical padded standard base64", () => {
    expect(decodeBase64("AQID")).toEqual(Uint8Array.of(1, 2, 3));
    expect(decodeBase64("AQI=")).toEqual(Uint8Array.of(1, 2));
    expect(decodeBase64("AQI")).toBeNull();
    expect(decodeBase64("AQ-_")).toBeNull();
    expect(decodeBase64("AQ ID")).toBeNull();
  });

  it("round-trips unpadded base64url", () => {
    const bytes = Uint8Array.of(0xfb, 0xff, 0xfe, 0x01);
    const text = encodeBase64Url(bytes);
    expect(text).toBe("-__-AQ");
    expect(decodeBase64Url(text)).toEqual(bytes);
    expect(decodeBase64Url("-__-AQ==")).toBeNull();
    expect(decodeBase64Url("+//+AQ")).toBeNull();
    expect(decodeBase64Url("A")).toBeNull();
  });
});
