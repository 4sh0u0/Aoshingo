// SPDX-License-Identifier: Apache-2.0

// A small, strict CBOR (RFC 8949) decoder covering what App Attest produces: unsigned and negative
// integers, byte strings, text strings, arrays, maps and the simple values false/true/null.
// Indefinite lengths, tags, floats and duplicate map keys are rejected. The whole input must be
// consumed.

export type CborValue =
  | number
  | Uint8Array
  | string
  | CborValue[]
  | CborMap
  | boolean
  | null;

export type CborMap = Map<string | number, CborValue>;

export class CborError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CborError";
  }
}

const MAX_DEPTH = 16;
const textDecoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

export function decodeCbor(input: Uint8Array): CborValue {
  const view = new DataView(input.buffer, input.byteOffset, input.byteLength);
  let offset = 0;

  function need(count: number): void {
    if (count < 0 || offset + count > input.byteLength) throw new CborError("unexpected end of input");
  }

  function readArgument(info: number): number {
    if (info < 24) return info;
    switch (info) {
      case 24:
        need(1);
        return view.getUint8(offset++);
      case 25: {
        need(2);
        const value = view.getUint16(offset);
        offset += 2;
        return value;
      }
      case 26: {
        need(4);
        const value = view.getUint32(offset);
        offset += 4;
        return value;
      }
      case 27: {
        need(8);
        const value = view.getBigUint64(offset);
        offset += 8;
        if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new CborError("integer too large");
        return Number(value);
      }
      default:
        // 28..30 are reserved, 31 is the indefinite-length marker.
        throw new CborError("unsupported additional information");
    }
  }

  function readItem(depth: number): CborValue {
    if (depth > MAX_DEPTH) throw new CborError("nesting too deep");
    need(1);
    const initial = view.getUint8(offset++);
    const major = initial >> 5;
    const info = initial & 0x1f;

    switch (major) {
      case 0:
        return readArgument(info);
      case 1:
        return -1 - readArgument(info);
      case 2: {
        const length = readArgument(info);
        need(length);
        const bytes = input.slice(offset, offset + length);
        offset += length;
        return bytes;
      }
      case 3: {
        const length = readArgument(info);
        need(length);
        let text: string;
        try {
          text = textDecoder.decode(input.subarray(offset, offset + length));
        } catch {
          throw new CborError("invalid UTF-8 in text string");
        }
        offset += length;
        return text;
      }
      case 4: {
        const count = readArgument(info);
        // Every item takes at least one byte, so this bounds allocation by the input size.
        need(count);
        const items: CborValue[] = [];
        for (let i = 0; i < count; i++) items.push(readItem(depth + 1));
        return items;
      }
      case 5: {
        const count = readArgument(info);
        need(count * 2);
        const map: CborMap = new Map();
        for (let i = 0; i < count; i++) {
          const key = readItem(depth + 1);
          if (typeof key !== "string" && typeof key !== "number") {
            throw new CborError("unsupported map key type");
          }
          if (map.has(key)) throw new CborError("duplicate map key");
          map.set(key, readItem(depth + 1));
        }
        return map;
      }
      case 7:
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        throw new CborError("unsupported simple value or float");
      default:
        // Major type 6 (tags) is not used by App Attest.
        throw new CborError("unsupported major type");
    }
  }

  const value = readItem(0);
  if (offset !== input.byteLength) throw new CborError("trailing bytes after CBOR item");
  return value;
}

export function isCborMap(value: CborValue | undefined): value is CborMap {
  return value instanceof Map;
}

export function isBytes(value: CborValue | undefined): value is Uint8Array {
  return value instanceof Uint8Array;
}
