// SPDX-License-Identifier: Apache-2.0

// A minimal, strict DER reader: single-byte tags, definite minimal lengths, no trailing data.
// It is only used on certificates whose signatures are verified against the pinned root, and on
// ECDSA signatures.

export class DerError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DerError";
  }
}

export const TAG = {
  BOOLEAN: 0x01,
  INTEGER: 0x02,
  BIT_STRING: 0x03,
  OCTET_STRING: 0x04,
  NULL: 0x05,
  OID: 0x06,
  UTC_TIME: 0x17,
  GENERALIZED_TIME: 0x18,
  SEQUENCE: 0x30,
  SET: 0x31,
} as const;

/** Context-specific constructed tag `[n]`. */
export function contextTag(n: number): number {
  return 0xa0 | n;
}

export interface DerNode {
  readonly tag: number;
  /** The complete encoding (tag, length and contents). */
  readonly raw: Uint8Array;
  /** The contents octets. */
  readonly content: Uint8Array;
}

function readNodeAt(input: Uint8Array, offset: number): { node: DerNode; next: number } {
  const end = input.byteLength;
  if (offset + 2 > end) throw new DerError("truncated header");
  const tag = input[offset]!;
  if ((tag & 0x1f) === 0x1f) throw new DerError("high tag numbers are not supported");
  let position = offset + 1;
  const first = input[position++]!;
  let length: number;
  if (first < 0x80) {
    length = first;
  } else {
    const count = first & 0x7f;
    if (count === 0) throw new DerError("indefinite length");
    if (count > 4) throw new DerError("length too large");
    if (position + count > end) throw new DerError("truncated length");
    if (input[position] === 0) throw new DerError("non-minimal length");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + input[position++]!;
    if (length < 0x80) throw new DerError("non-minimal length");
  }
  if (position + length > end) throw new DerError("truncated contents");
  return {
    node: {
      tag,
      raw: input.subarray(offset, position + length),
      content: input.subarray(position, position + length),
    },
    next: position + length,
  };
}

/** Parses exactly one DER element that spans the whole input. */
export function parseDer(input: Uint8Array): DerNode {
  const { node, next } = readNodeAt(input, 0);
  if (next !== input.byteLength) throw new DerError("trailing data");
  return node;
}

/** Parses the contents of a constructed element into its children. */
export function children(node: DerNode): DerNode[] {
  if ((node.tag & 0x20) === 0) throw new DerError("not a constructed element");
  const result: DerNode[] = [];
  let offset = 0;
  while (offset < node.content.byteLength) {
    const { node: child, next } = readNodeAt(node.content, offset);
    result.push(child);
    offset = next;
  }
  return result;
}

export function expectTag(node: DerNode | undefined, tag: number): DerNode {
  if (node === undefined) throw new DerError("missing element");
  if (node.tag !== tag) throw new DerError(`unexpected tag 0x${node.tag.toString(16)}`);
  return node;
}

export function decodeOid(node: DerNode): string {
  expectTag(node, TAG.OID);
  const bytes = node.content;
  if (bytes.byteLength === 0) throw new DerError("empty OID");
  const arcs: number[] = [];
  let value = 0;
  let started = false;
  for (let i = 0; i < bytes.byteLength; i++) {
    const byte = bytes[i]!;
    if (!started && byte === 0x80) throw new DerError("non-minimal OID arc");
    started = true;
    value = value * 128 + (byte & 0x7f);
    if (value > Number.MAX_SAFE_INTEGER / 128) throw new DerError("OID arc too large");
    if ((byte & 0x80) === 0) {
      arcs.push(value);
      value = 0;
      started = false;
    }
  }
  if (started) throw new DerError("truncated OID");
  const first = arcs.shift()!;
  const head = first < 40 ? [0, first] : first < 80 ? [1, first - 40] : [2, first - 80];
  return [...head, ...arcs].join(".");
}

/** Contents of a BIT STRING that must have no unused bits. */
export function bitStringBytes(node: DerNode): Uint8Array {
  expectTag(node, TAG.BIT_STRING);
  if (node.content.byteLength === 0 || node.content[0] !== 0) {
    throw new DerError("BIT STRING with unused bits");
  }
  return node.content.subarray(1);
}

export function decodeBoolean(node: DerNode): boolean {
  expectTag(node, TAG.BOOLEAN);
  if (node.content.byteLength !== 1) throw new DerError("bad BOOLEAN");
  if (node.content[0] === 0xff) return true;
  if (node.content[0] === 0x00) return false;
  throw new DerError("non-DER BOOLEAN");
}

/** Decodes UTCTime or GeneralizedTime in the `...Z` forms required by RFC 5280; returns ms. */
export function decodeTime(node: DerNode): number {
  const text = String.fromCharCode(...node.content);
  let match: RegExpExecArray | null;
  let year: number;
  if (node.tag === TAG.UTC_TIME) {
    match = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
    if (!match) throw new DerError("bad UTCTime");
    const yy = Number(match[1]);
    year = yy >= 50 ? 1900 + yy : 2000 + yy;
  } else if (node.tag === TAG.GENERALIZED_TIME) {
    match = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
    if (!match) throw new DerError("bad GeneralizedTime");
    year = Number(match[1]);
  } else {
    throw new DerError("unexpected time type");
  }
  const [month, day, hour, minute, second] = match.slice(2).map(Number) as [
    number,
    number,
    number,
    number,
    number,
  ];
  const ms = Date.UTC(year, month - 1, day, hour, minute, second);
  const check = new Date(ms);
  if (
    check.getUTCMonth() !== month - 1 ||
    check.getUTCDate() !== day ||
    check.getUTCHours() !== hour ||
    check.getUTCMinutes() !== minute ||
    check.getUTCSeconds() !== second
  ) {
    throw new DerError("invalid date");
  }
  return ms;
}

/** Strips the DER sign padding from a positive INTEGER. */
function positiveIntegerBytes(node: DerNode): Uint8Array {
  expectTag(node, TAG.INTEGER);
  const bytes = node.content;
  if (bytes.byteLength === 0) throw new DerError("empty INTEGER");
  if (bytes[0]! & 0x80) throw new DerError("negative INTEGER");
  if (bytes[0] === 0 && bytes.byteLength > 1) {
    if ((bytes[1]! & 0x80) === 0) throw new DerError("non-minimal INTEGER");
    return bytes.subarray(1);
  }
  return bytes;
}

/**
 * Converts a DER `ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER }` into the fixed-size
 * `r || s` form WebCrypto expects.
 */
export function ecdsaDerToRaw(signature: Uint8Array, componentSize: number): Uint8Array {
  const sequence = expectTag(parseDer(signature), TAG.SEQUENCE);
  const parts = children(sequence);
  if (parts.length !== 2) throw new DerError("bad ECDSA signature");
  const out = new Uint8Array(componentSize * 2);
  parts.forEach((part, index) => {
    const value = positiveIntegerBytes(part);
    if (value.byteLength > componentSize) throw new DerError("ECDSA component too large");
    out.set(value, componentSize * (index + 1) - value.byteLength);
  });
  return out;
}
