// SPDX-License-Identifier: Apache-2.0

// Test-only CBOR encoder for building attestation and assertion objects.

import { concatBytes, utf8 } from "../../src/encoding";

export type CborInput = number | string | Uint8Array | CborInput[] | { [key: string]: CborInput };

function head(major: number, value: number): Uint8Array {
  if (value < 24) return Uint8Array.of((major << 5) | value);
  if (value < 0x100) return Uint8Array.of((major << 5) | 24, value);
  if (value < 0x10000) return Uint8Array.of((major << 5) | 25, value >> 8, value & 0xff);
  const out = new Uint8Array(5);
  out[0] = (major << 5) | 26;
  new DataView(out.buffer).setUint32(1, value);
  return out;
}

export function encodeCbor(value: CborInput): Uint8Array {
  if (typeof value === "number") {
    return value >= 0 ? head(0, value) : head(1, -1 - value);
  }
  if (typeof value === "string") {
    const bytes = utf8(value);
    return concatBytes(head(3, bytes.byteLength), bytes);
  }
  if (value instanceof Uint8Array) return concatBytes(head(2, value.byteLength), value);
  if (Array.isArray(value)) return concatBytes(head(4, value.length), ...value.map(encodeCbor));
  const entries = Object.entries(value);
  return concatBytes(
    head(5, entries.length),
    ...entries.flatMap(([key, item]) => [encodeCbor(key), encodeCbor(item)]),
  );
}
