// SPDX-License-Identifier: Apache-2.0

// Validation of POST /v1/reports bodies (docs/field-data-api.md, "Validation"). The validated
// report is rebuilt from known fields only, so nothing unexpected can reach storage.

export const MAX_REPORT_BYTES = 256 * 1024;

const SIGNAL_STATES = new Set(["NoSignal", "Red", "BlinkGreen", "Green", "None", "Unknown"]);
const CLIENT_PATTERN = /^aoshingo-[a-z]+\/[0-9A-Za-z.+-]+$/;
const INTERSECTION_ID_PATTERN = /^[0-9A-F]{8}$/;
const SERVICE_UUID_PATTERN =
  /^(?:[0-9A-F]{4}|[0-9A-F]{8}|[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})$/;
const RAW_PATTERN = /^CE01(?:[0-9A-F]{2})+$/;
const MAX_PAST_SECONDS = 7 * 24 * 3600;

/**
 * Smallest PICS payload (the bytes after the company ID) per message type, from
 * PICSParser.minimumLength in Packages/AoshingoKit/Sources/PICSKit/PICSPacket.swift. The app
 * uploads a packet only when that parser accepts it, so the server accepts exactly the same
 * packets: the 10-byte common header, plus for type 0 (name) bytes 10..<24, type 1 (position)
 * bytes 10..<18 and type 2 (signals) at least one signal byte. Other message types carry only
 * the header as far as the parser knows; the app still uploads them, so they are accepted.
 * Update both together.
 */
export function picsMinimumLength(messageType: number): number {
  switch (messageType) {
    case 0:
      return 24;
    case 1:
      return 18;
    case 2:
      return 11;
    default:
      return 10;
  }
}
const MAX_FUTURE_SECONDS = 300;

export interface Observation {
  t: number;
  raw: string;
  rssi: number | null;
  bearing: number | null;
  heading: number | null;
}

export interface Transition {
  t: number;
  slot: number;
  from: string;
  to: string;
}

export interface IntersectionReport {
  id: string;
  serviceUUIDs: string[];
  emitters: number;
  observations: Observation[];
  transitions: Transition[];
}

export interface Report {
  schema: 1;
  client: string | null;
  intersections: IntersectionReport[];
}

export type ValidationResult = { ok: true; report: Report } | { ok: false; reason: string };

class Invalid extends Error {
  constructor(readonly reason: string) {
    super(reason);
  }
}

function invalid(reason: string): never {
  throw new Invalid(reason);
}

type JsonObject = Record<string, unknown>;

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Rejects keys outside `allowed`, so no unexpected data (e.g. a location) is silently accepted. */
function checkKeys(object: JsonObject, allowed: readonly string[], where: string): void {
  for (const key of Object.keys(object)) {
    if (!allowed.includes(key)) invalid(`${where}: unexpected field`);
  }
}

function isInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value);
}

function integerInRange(value: unknown, min: number, max: number): value is number {
  return isInteger(value) && value >= min && value <= max;
}

/**
 * `null` and an absent key are treated the same for nullable fields; Swift's synthesized
 * Encodable omits nil optionals instead of writing null.
 */
function nullableInteger(object: JsonObject, key: string, min: number, max: number, where: string): number | null {
  const value = object[key];
  if (value === undefined || value === null) return null;
  if (!integerInRange(value, min, max)) invalid(`${where}.${key}`);
  return value;
}

function checkTime(value: unknown, nowSeconds: number, where: string): number {
  if (!integerInRange(value, nowSeconds - MAX_PAST_SECONDS, nowSeconds + MAX_FUTURE_SECONDS)) {
    invalid(`${where}.t`);
  }
  return value;
}

function validateObservation(value: unknown, intersectionId: string, nowSeconds: number): Observation {
  const where = "observation";
  if (!isObject(value)) invalid(where);
  checkKeys(value, ["t", "raw", "rssi", "bearing", "heading"], where);
  const t = checkTime(value.t, nowSeconds, where);
  const raw = value.raw;
  // 24 characters: the company ID and the 10-byte PICS header.
  if (typeof raw !== "string" || raw.length < 24 || raw.length > 128 || !RAW_PATTERN.test(raw)) {
    invalid(`${where}.raw`);
  }
  // The message type is payload byte 2 (hex characters 8..<10); see picsMinimumLength.
  if ((raw.length - 4) / 2 < picsMinimumLength(parseInt(raw.slice(8, 10), 16))) invalid(`${where}.raw length`);
  // Bytes 6..<10 after the two company-ID bytes, i.e. bytes 8..<12 of raw (hex characters 16..<24).
  if (raw.slice(16, 24) !== intersectionId) invalid(`${where}.raw intersection`);
  const rssi = nullableInteger(value, "rssi", -130, 0, where);
  if (rssi !== null && rssi % 5 !== 0) invalid(`${where}.rssi`);
  const bearing = nullableInteger(value, "bearing", 0, 7, where);
  const heading = nullableInteger(value, "heading", 0, 7, where);
  // Normalise -0 to 0.
  return { t, raw, rssi: rssi === null ? null : rssi + 0, bearing, heading };
}

function validateTransition(value: unknown, nowSeconds: number): Transition {
  const where = "transition";
  if (!isObject(value)) invalid(where);
  checkKeys(value, ["t", "slot", "from", "to"], where);
  const t = checkTime(value.t, nowSeconds, where);
  if (!integerInRange(value.slot, 1, 6)) invalid(`${where}.slot`);
  const { from, to } = value;
  if (typeof from !== "string" || !SIGNAL_STATES.has(from)) invalid(`${where}.from`);
  if (typeof to !== "string" || !SIGNAL_STATES.has(to)) invalid(`${where}.to`);
  if (from === to) invalid(`${where}.from equals to`);
  return { t, slot: value.slot, from, to };
}

function validateIntersection(value: unknown, nowSeconds: number): IntersectionReport {
  const where = "intersection";
  if (!isObject(value)) invalid(where);
  checkKeys(value, ["id", "serviceUUIDs", "emitters", "observations", "transitions"], where);
  const id = value.id;
  if (typeof id !== "string" || !INTERSECTION_ID_PATTERN.test(id)) invalid(`${where}.id`);

  const serviceUUIDs = value.serviceUUIDs;
  if (!Array.isArray(serviceUUIDs) || serviceUUIDs.length > 8) invalid(`${where}.serviceUUIDs`);
  for (const uuid of serviceUUIDs) {
    if (typeof uuid !== "string" || !SERVICE_UUID_PATTERN.test(uuid)) invalid(`${where}.serviceUUIDs item`);
  }

  if (!integerInRange(value.emitters, 0, 32)) invalid(`${where}.emitters`);

  const observations = value.observations;
  if (!Array.isArray(observations) || observations.length > 600) invalid(`${where}.observations`);
  const transitions = value.transitions;
  if (!Array.isArray(transitions) || transitions.length > 300) invalid(`${where}.transitions`);
  if (observations.length === 0 && transitions.length === 0) invalid(`${where} is empty`);

  return {
    id,
    serviceUUIDs: serviceUUIDs as string[],
    emitters: value.emitters,
    observations: observations.map((item) => validateObservation(item, id, nowSeconds)),
    transitions: transitions.map((item) => validateTransition(item, nowSeconds)),
  };
}

export function validateReport(body: unknown, nowSeconds: number): ValidationResult {
  try {
    if (!isObject(body)) invalid("body is not an object");
    checkKeys(body, ["schema", "client", "intersections"], "report");
    if (body.schema !== 1) invalid("schema");

    let client: string | null = null;
    if (body.client !== undefined && body.client !== null) {
      if (typeof body.client !== "string" || body.client.length > 40 || !CLIENT_PATTERN.test(body.client)) {
        invalid("client");
      }
      client = body.client;
    }

    const intersections = body.intersections;
    if (!Array.isArray(intersections) || intersections.length < 1 || intersections.length > 50) {
      invalid("intersections");
    }
    const validated = intersections.map((item) => validateIntersection(item, nowSeconds));
    if (new Set(validated.map((item) => item.id)).size !== validated.length) invalid("duplicate intersection id");

    return { ok: true, report: { schema: 1, client, intersections: validated } };
  } catch (error) {
    if (error instanceof Invalid) return { ok: false, reason: error.reason };
    throw error;
  }
}
