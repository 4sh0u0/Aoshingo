// SPDX-License-Identifier: Apache-2.0

// Test-only DER encoder used to build fake certificate chains.

import { concatBytes, utf8 } from "../../src/encoding";

export function tlv(tag: number, ...contents: Uint8Array[]): Uint8Array {
  const body = concatBytes(...contents);
  const length = body.byteLength;
  let header: number[];
  if (length < 0x80) header = [tag, length];
  else if (length < 0x100) header = [tag, 0x81, length];
  else if (length < 0x10000) header = [tag, 0x82, length >> 8, length & 0xff];
  else header = [tag, 0x83, length >> 16, (length >> 8) & 0xff, length & 0xff];
  return concatBytes(Uint8Array.from(header), body);
}

export const seq = (...contents: Uint8Array[]) => tlv(0x30, ...contents);
export const set = (...contents: Uint8Array[]) => tlv(0x31, ...contents);
export const explicit = (n: number, ...contents: Uint8Array[]) => tlv(0xa0 | n, ...contents);
export const octetString = (bytes: Uint8Array) => tlv(0x04, bytes);
export const bitString = (bytes: Uint8Array) => tlv(0x03, Uint8Array.of(0), bytes);
export const bool = (value: boolean) => tlv(0x01, Uint8Array.of(value ? 0xff : 0x00));
export const utf8String = (text: string) => tlv(0x0c, utf8(text));

/** A non-negative INTEGER from big-endian magnitude bytes. */
export function integerBytes(magnitude: Uint8Array): Uint8Array {
  let start = 0;
  while (start < magnitude.byteLength - 1 && magnitude[start] === 0) start++;
  let value = magnitude.subarray(start);
  if (value.byteLength === 0) value = Uint8Array.of(0);
  if (value[0]! & 0x80) value = concatBytes(Uint8Array.of(0), value);
  return tlv(0x02, value);
}

export function integer(value: number): Uint8Array {
  const bytes: number[] = [];
  let rest = value;
  do {
    bytes.unshift(rest & 0xff);
    rest = Math.floor(rest / 256);
  } while (rest > 0);
  return integerBytes(Uint8Array.from(bytes));
}

export function oid(dotted: string): Uint8Array {
  const arcs = dotted.split(".").map(Number);
  const values = [arcs[0]! * 40 + arcs[1]!, ...arcs.slice(2)];
  const out: number[] = [];
  for (const value of values) {
    const groups: number[] = [];
    let rest = value;
    do {
      groups.unshift(rest & 0x7f);
      rest = Math.floor(rest / 128);
    } while (rest > 0);
    groups.forEach((group, index) => out.push(index < groups.length - 1 ? group | 0x80 : group));
  }
  return tlv(0x06, Uint8Array.from(out));
}

export function time(ms: number): Uint8Array {
  const iso = new Date(ms).toISOString();
  const digits = iso.slice(0, 19).replace(/[-T:]/g, "");
  const year = new Date(ms).getUTCFullYear();
  if (year >= 1950 && year < 2050) return tlv(0x17, utf8(`${digits.slice(2)}Z`));
  return tlv(0x18, utf8(`${digits}Z`));
}

/** Converts a WebCrypto `r || s` ECDSA signature into DER. */
export function ecdsaRawToDer(raw: Uint8Array): Uint8Array {
  const half = raw.byteLength / 2;
  return seq(integerBytes(raw.subarray(0, half)), integerBytes(raw.subarray(half)));
}
