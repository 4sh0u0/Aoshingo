// SPDX-License-Identifier: Apache-2.0

// Validation of POST /v1/reports bodies (docs/field-data-api.md, "POST /v1/reports"). Schema 1,
// 2 and 3 bodies are accepted; a body must not carry any field that a later schema added. Schema 3
// is schema 2 plus observations[].activity. The validated report is rebuilt from known fields only,
// so nothing unexpected can reach storage.

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
 * uploads a packet only when that parser accepts it and its type is one the parser decodes
 * (ReportContract.isUploadable in FieldDataKit), so the server accepts exactly those packets:
 * the 10-byte common header, plus for type 0 (name) bytes 10..<24, type 1 (position) bytes
 * 10..<18 and type 2 (signals) at least one signal byte. Other message types are rejected
 * (`null`), because the server could not tell what their bytes contain. Update both together.
 */
export function picsMinimumLength(messageType: number): number | null {
  switch (messageType) {
    case 0:
      return 24;
    case 1:
      return 18;
    case 2:
      return 11;
    default:
      return null;
  }
}
const MAX_FUTURE_SECONDS = 300;

// Schema 2 buckets ("アプリ側で行う丸めと間引き"). The app rounds to these values, so anything else
// is not from the app and could carry more precise data than the contract allows.
/** Lower bounds (m) of the distance from the intersection's coordinates to the user. */
const DISTANCE_BUCKETS: readonly number[] = [0, 10, 20, 40, 80, 160];
/** Upper bounds (m) of the horizontal accuracy of the user's location. */
const ACCURACY_BUCKETS: readonly number[] = [5, 10, 20, 30];
/** Lower bounds of the number of other Bluetooth devices seen in the last 30 seconds. */
const NEARBY_BUCKETS: readonly number[] = [0, 1, 5, 10, 20, 50, 100];
const LABEL_KINDS = new Set(["crosswalk", "button"]);
/** Schema 3: how the user was moving, from iOS's motion activity classifier. */
const ACTIVITIES = new Set(["stationary", "walking", "running", "cycling", "automotive"]);
/** Longest `held`, `cycle` and `steps[].held` (ms); the app sends null beyond an hour. */
const MAX_DURATION_MS = 3_600_000;

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

/** A schema 1 intersection; schema 2 adds the fields of Schema2Intersection. */
export interface IntersectionReport {
  id: string;
  serviceUUIDs: string[];
  emitters: number;
  observations: Observation[];
  transitions: Transition[];
}

export interface Schema2Observation extends Observation {
  /** Index into the intersection's emitterInfo. */
  emitter: number | null;
  distance: number | null;
  accuracy: number | null;
  course: number | null;
  speed: number | null;
  nearby: number | null;
}

export type Activity = "stationary" | "walking" | "running" | "cycling" | "automotive";

export interface Schema3Observation extends Schema2Observation {
  activity: Activity | null;
}

export interface Schema2Transition extends Transition {
  emitter: number | null;
  /** Milliseconds, multiples of 100. */
  gap: number | null;
  held: number | null;
  cycle: number | null;
}

export interface EmitterInfo {
  txPower: number | null;
  connectable: boolean | null;
}

/** A change of the remaining-time step (1-8) while the signal state stays the same. */
export interface Step {
  t: number;
  slot: number;
  state: string;
  from: number | null;
  to: number | null;
  emitter: number | null;
  held: number | null;
}

/** Reception statistics of one emitter and message type, before thinning. */
export interface PacketStats {
  emitter: number;
  type: number;
  count: number;
  /** Milliseconds, multiples of 10. */
  minInterval: number | null;
  medianInterval: number | null;
}

/** A span (Unix seconds) in which the intersection's packets arrived at most 5 s apart. */
export interface Coverage {
  start: number;
  end: number;
}

/** A mark a tester set on site. */
export interface Label {
  t: number;
  kind: "crosswalk" | "button";
  slot: number | null;
  heading: number | null;
  bearing: number | null;
  distance: number | null;
}

export interface Schema2Intersection extends IntersectionReport {
  emitterInfo: EmitterInfo[];
  observations: Schema2Observation[];
  transitions: Schema2Transition[];
  steps: Step[];
  packets: PacketStats[];
  coverage: Coverage[];
  labels: Label[];
}

/** Schema 3 changes only the observations. */
export interface Schema3Intersection extends Schema2Intersection {
  observations: Schema3Observation[];
}

export interface Schema1Report {
  schema: 1;
  client: string | null;
  intersections: IntersectionReport[];
}

export interface Schema2Report {
  schema: 2;
  client: string | null;
  intersections: Schema2Intersection[];
}

export interface Schema3Report {
  schema: 3;
  client: string | null;
  intersections: Schema3Intersection[];
}

export type Report = Schema1Report | Schema2Report | Schema3Report;

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

/** `value` as an object with no keys outside `allowed`. */
function objectWithKeys(value: unknown, allowed: readonly string[], where: string): JsonObject {
  if (!isObject(value)) invalid(where);
  checkKeys(value, allowed, where);
  return value;
}

function isInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value);
}

function integerInRange(value: unknown, min: number, max: number): value is number {
  return isInteger(value) && value >= min && value <= max;
}

/** A required integer in min...max, with -0 normalised to 0. */
function requiredInteger(object: JsonObject, key: string, min: number, max: number, where: string): number {
  const value = object[key];
  if (!integerInRange(value, min, max)) invalid(`${where}.${key}`);
  return value + 0;
}

/**
 * `null` and an absent key are treated the same for nullable fields; Swift's synthesized
 * Encodable omits nil optionals instead of writing null. -0 is normalised to 0.
 */
function nullableInteger(object: JsonObject, key: string, min: number, max: number, where: string): number | null {
  const value = object[key];
  if (value === undefined || value === null) return null;
  if (!integerInRange(value, min, max)) invalid(`${where}.${key}`);
  return value + 0;
}

/** A nullable integer in 0...max that is a multiple of `step`. */
function nullableMultiple(
  object: JsonObject,
  key: string,
  max: number,
  step: number,
  where: string,
): number | null {
  const value = nullableInteger(object, key, 0, max, where);
  if (value !== null && value % step !== 0) invalid(`${where}.${key}`);
  return value;
}

/** A nullable integer that must be one of `allowed`. */
function nullableBucket(object: JsonObject, key: string, allowed: readonly number[], where: string): number | null {
  const value = nullableInteger(object, key, allowed[0]!, allowed[allowed.length - 1]!, where);
  if (value !== null && !allowed.includes(value)) invalid(`${where}.${key}`);
  return value;
}

function nullableBoolean(object: JsonObject, key: string, where: string): boolean | null {
  const value = object[key];
  if (value === undefined || value === null) return null;
  if (typeof value !== "boolean") invalid(`${where}.${key}`);
  return value;
}

/** An emitter index (0 ..< emitters), or null. */
function nullableEmitter(object: JsonObject, emitters: number, where: string): number | null {
  return nullableInteger(object, "emitter", 0, emitters - 1, where);
}

function checkTime(object: JsonObject, key: string, nowSeconds: number, where: string): number {
  return requiredInteger(object, key, nowSeconds - MAX_PAST_SECONDS, nowSeconds + MAX_FUTURE_SECONDS, where);
}

function signalState(object: JsonObject, key: string, where: string): string {
  const value = object[key];
  if (typeof value !== "string" || !SIGNAL_STATES.has(value)) invalid(`${where}.${key}`);
  return value;
}

function array(object: JsonObject, key: string, max: number, where: string): unknown[] {
  const value = object[key];
  if (!Array.isArray(value) || value.length > max) invalid(`${where}.${key}`);
  return value;
}

/** Schema 2's added lists may be left out (treated as empty), but never null. */
function optionalArray(object: JsonObject, key: string, max: number, where: string): unknown[] {
  return object[key] === undefined ? [] : array(object, key, max, where);
}

const OBSERVATION_KEYS = ["t", "raw", "rssi", "bearing", "heading"];
const SCHEMA2_OBSERVATION_KEYS = [...OBSERVATION_KEYS, "emitter", "distance", "accuracy", "course", "speed", "nearby"];
const SCHEMA3_OBSERVATION_KEYS = [...SCHEMA2_OBSERVATION_KEYS, "activity"];
const TRANSITION_KEYS = ["t", "slot", "from", "to"];
const SCHEMA2_TRANSITION_KEYS = [...TRANSITION_KEYS, "emitter", "gap", "held", "cycle"];
const INTERSECTION_KEYS = ["id", "serviceUUIDs", "emitters", "observations", "transitions"];
const SCHEMA2_INTERSECTION_KEYS = [...INTERSECTION_KEYS, "emitterInfo", "steps", "packets", "coverage", "labels"];

function observation(object: JsonObject, intersectionId: string, nowSeconds: number): Observation {
  const where = "observation";
  const t = checkTime(object, "t", nowSeconds, where);
  const raw = object.raw;
  // 24 characters: the company ID and the 10-byte PICS header.
  if (typeof raw !== "string" || raw.length < 24 || raw.length > 128 || !RAW_PATTERN.test(raw)) {
    invalid(`${where}.raw`);
  }
  // The message type is payload byte 2 (hex characters 8..<10); see picsMinimumLength.
  const minimum = picsMinimumLength(parseInt(raw.slice(8, 10), 16));
  if (minimum === null) invalid(`${where}.raw message type`);
  if ((raw.length - 4) / 2 < minimum) invalid(`${where}.raw length`);
  // Bytes 6..<10 after the two company-ID bytes, i.e. bytes 8..<12 of raw (hex characters 16..<24).
  if (raw.slice(16, 24) !== intersectionId) invalid(`${where}.raw intersection`);
  const rssi = nullableInteger(object, "rssi", -130, 0, where);
  if (rssi !== null && rssi % 5 !== 0) invalid(`${where}.rssi`);
  const bearing = nullableInteger(object, "bearing", 0, 7, where);
  const heading = nullableInteger(object, "heading", 0, 7, where);
  return { t, raw, rssi, bearing, heading };
}

function schema1Observation(value: unknown, intersectionId: string, nowSeconds: number): Observation {
  return observation(objectWithKeys(value, OBSERVATION_KEYS, "observation"), intersectionId, nowSeconds);
}

/** The fields of a schema 2 observation, from an object whose keys were already checked. */
function schema2ObservationFields(
  object: JsonObject,
  intersectionId: string,
  emitters: number,
  nowSeconds: number,
): Schema2Observation {
  const where = "observation";
  return {
    ...observation(object, intersectionId, nowSeconds),
    emitter: nullableEmitter(object, emitters, where),
    distance: nullableBucket(object, "distance", DISTANCE_BUCKETS, where),
    accuracy: nullableBucket(object, "accuracy", ACCURACY_BUCKETS, where),
    course: nullableInteger(object, "course", 0, 7, where),
    speed: nullableInteger(object, "speed", 0, 2, where),
    nearby: nullableBucket(object, "nearby", NEARBY_BUCKETS, where),
  };
}

function schema2Observation(
  value: unknown,
  intersectionId: string,
  emitters: number,
  nowSeconds: number,
): Schema2Observation {
  const object = objectWithKeys(value, SCHEMA2_OBSERVATION_KEYS, "observation");
  return schema2ObservationFields(object, intersectionId, emitters, nowSeconds);
}

function schema3Observation(
  value: unknown,
  intersectionId: string,
  emitters: number,
  nowSeconds: number,
): Schema3Observation {
  const where = "observation";
  const object = objectWithKeys(value, SCHEMA3_OBSERVATION_KEYS, where);
  const activity = object.activity;
  if (activity !== undefined && activity !== null && (typeof activity !== "string" || !ACTIVITIES.has(activity))) {
    invalid(`${where}.activity`);
  }
  return {
    ...schema2ObservationFields(object, intersectionId, emitters, nowSeconds),
    activity: (activity ?? null) as Activity | null,
  };
}

function transition(object: JsonObject, nowSeconds: number): Transition {
  const where = "transition";
  const t = checkTime(object, "t", nowSeconds, where);
  const slot = requiredInteger(object, "slot", 1, 6, where);
  const from = signalState(object, "from", where);
  const to = signalState(object, "to", where);
  if (from === to) invalid(`${where}.from equals to`);
  return { t, slot, from, to };
}

function schema1Transition(value: unknown, nowSeconds: number): Transition {
  return transition(objectWithKeys(value, TRANSITION_KEYS, "transition"), nowSeconds);
}

function schema2Transition(value: unknown, emitters: number, nowSeconds: number): Schema2Transition {
  const where = "transition";
  const object = objectWithKeys(value, SCHEMA2_TRANSITION_KEYS, where);
  return {
    ...transition(object, nowSeconds),
    emitter: nullableEmitter(object, emitters, where),
    gap: nullableMultiple(object, "gap", 5000, 100, where),
    held: nullableMultiple(object, "held", MAX_DURATION_MS, 100, where),
    cycle: nullableMultiple(object, "cycle", MAX_DURATION_MS, 100, where),
  };
}

function emitterInfo(value: unknown): EmitterInfo {
  const where = "emitterInfo";
  const object = objectWithKeys(value, ["txPower", "connectable"], where);
  return {
    txPower: nullableInteger(object, "txPower", -127, 20, where),
    connectable: nullableBoolean(object, "connectable", where),
  };
}

function step(value: unknown, emitters: number, nowSeconds: number): Step {
  const where = "step";
  const object = objectWithKeys(value, ["t", "slot", "state", "from", "to", "emitter", "held"], where);
  const t = checkTime(object, "t", nowSeconds, where);
  const slot = requiredInteger(object, "slot", 1, 6, where);
  const state = signalState(object, "state", where);
  const from = nullableInteger(object, "from", 1, 8, where);
  const to = nullableInteger(object, "to", 1, 8, where);
  // A step is a change, so null → null is not one either.
  if (from === to) invalid(`${where}.from equals to`);
  const emitter = nullableEmitter(object, emitters, where);
  const held = nullableMultiple(object, "held", MAX_DURATION_MS, 100, where);
  return { t, slot, state, from, to, emitter, held };
}

function packetStats(value: unknown, emitters: number): PacketStats {
  const where = "packets";
  const object = objectWithKeys(value, ["emitter", "type", "count", "minInterval", "medianInterval"], where);
  const emitter = requiredInteger(object, "emitter", 0, emitters - 1, where);
  const type = requiredInteger(object, "type", 0, 2, where);
  const count = requiredInteger(object, "count", 1, 100_000, where);
  const minInterval = nullableMultiple(object, "minInterval", 600_000, 10, where);
  const medianInterval = nullableMultiple(object, "medianInterval", 600_000, 10, where);
  // One packet has no interval.
  if (count === 1 && (minInterval !== null || medianInterval !== null)) invalid(`${where} interval of one packet`);
  if (minInterval !== null && medianInterval !== null && minInterval > medianInterval) {
    invalid(`${where}.minInterval above medianInterval`);
  }
  return { emitter, type, count, minInterval, medianInterval };
}

function coverage(value: unknown, nowSeconds: number): Coverage {
  const where = "coverage";
  const object = objectWithKeys(value, ["start", "end"], where);
  const start = checkTime(object, "start", nowSeconds, where);
  const end = checkTime(object, "end", nowSeconds, where);
  if (start > end) invalid(`${where}.start after end`);
  return { start, end };
}

function label(value: unknown, nowSeconds: number): Label {
  const where = "label";
  const object = objectWithKeys(value, ["t", "kind", "slot", "heading", "bearing", "distance"], where);
  const t = checkTime(object, "t", nowSeconds, where);
  const kind = object.kind;
  if (typeof kind !== "string" || !LABEL_KINDS.has(kind)) invalid(`${where}.kind`);
  const slot = nullableInteger(object, "slot", 1, 6, where);
  if (kind === "crosswalk" && slot === null) invalid(`${where}.slot`);
  return {
    t,
    kind: kind as Label["kind"],
    slot,
    heading: nullableInteger(object, "heading", 0, 7, where),
    bearing: nullableInteger(object, "bearing", 0, 7, where),
    distance: nullableBucket(object, "distance", DISTANCE_BUCKETS, where),
  };
}

/** The fields both schemas share at the start of an intersection. */
function intersectionHeader(object: JsonObject): { id: string; serviceUUIDs: string[]; emitters: number } {
  const where = "intersection";
  const id = object.id;
  if (typeof id !== "string" || !INTERSECTION_ID_PATTERN.test(id)) invalid(`${where}.id`);
  const serviceUUIDs = array(object, "serviceUUIDs", 8, where);
  for (const uuid of serviceUUIDs) {
    if (typeof uuid !== "string" || !SERVICE_UUID_PATTERN.test(uuid)) invalid(`${where}.serviceUUIDs item`);
  }
  const emitters = requiredInteger(object, "emitters", 0, 32, where);
  return { id, serviceUUIDs: serviceUUIDs as string[], emitters };
}

function schema1Intersection(value: unknown, nowSeconds: number): IntersectionReport {
  const where = "intersection";
  const object = objectWithKeys(value, INTERSECTION_KEYS, where);
  const { id, serviceUUIDs, emitters } = intersectionHeader(object);
  const observations = array(object, "observations", 600, where);
  const transitions = array(object, "transitions", 300, where);
  if (observations.length === 0 && transitions.length === 0) invalid(`${where} is empty`);
  return {
    id,
    serviceUUIDs,
    emitters,
    observations: observations.map((item) => schema1Observation(item, id, nowSeconds)),
    transitions: transitions.map((item) => schema1Transition(item, nowSeconds)),
  };
}

type ObservationParser<O> = (value: unknown, intersectionId: string, emitters: number, nowSeconds: number) => O;

/** A schema 2 or 3 intersection; they differ only in their observations. */
function laterIntersection<O extends Schema2Observation>(
  value: unknown,
  nowSeconds: number,
  parseObservation: ObservationParser<O>,
): Schema2Intersection & { observations: O[] } {
  const where = "intersection";
  const object = objectWithKeys(value, SCHEMA2_INTERSECTION_KEYS, where);
  const { id, serviceUUIDs, emitters } = intersectionHeader(object);
  const info = optionalArray(object, "emitterInfo", 32, where);
  if (info.length !== emitters) invalid(`${where}.emitterInfo length`);
  const observations = array(object, "observations", 600, where);
  const transitions = array(object, "transitions", 300, where);
  const steps = optionalArray(object, "steps", 600, where);
  const packets = optionalArray(object, "packets", 96, where);
  const spans = optionalArray(object, "coverage", 60, where);
  const labels = optionalArray(object, "labels", 20, where);
  // packets and coverage only describe reception, so they do not make an intersection non-empty.
  if (observations.length + transitions.length + steps.length + labels.length === 0) invalid(`${where} is empty`);

  const validatedPackets = packets.map((item) => packetStats(item, emitters));
  const pairs = new Set(validatedPackets.map((item) => `${item.emitter}:${item.type}`));
  if (pairs.size !== validatedPackets.length) invalid(`${where}.packets duplicate emitter and type`);

  return {
    id,
    serviceUUIDs,
    emitters,
    emitterInfo: info.map(emitterInfo),
    observations: observations.map((item) => parseObservation(item, id, emitters, nowSeconds)),
    transitions: transitions.map((item) => schema2Transition(item, emitters, nowSeconds)),
    steps: steps.map((item) => step(item, emitters, nowSeconds)),
    packets: validatedPackets,
    coverage: spans.map((item) => coverage(item, nowSeconds)),
    labels: labels.map((item) => label(item, nowSeconds)),
  };
}

export function validateReport(body: unknown, nowSeconds: number): ValidationResult {
  try {
    if (!isObject(body)) invalid("body is not an object");
    checkKeys(body, ["schema", "client", "intersections"], "report");
    const schema = body.schema;
    if (schema !== 1 && schema !== 2 && schema !== 3) invalid("schema");

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
    let report: Report;
    if (schema === 1) {
      report = { schema, client, intersections: intersections.map((item) => schema1Intersection(item, nowSeconds)) };
    } else if (schema === 2) {
      report = {
        schema,
        client,
        intersections: intersections.map((item) => laterIntersection(item, nowSeconds, schema2Observation)),
      };
    } else {
      report = {
        schema,
        client,
        intersections: intersections.map((item) => laterIntersection(item, nowSeconds, schema3Observation)),
      };
    }
    const ids = report.intersections.map((item) => item.id);
    if (new Set(ids).size !== ids.length) invalid("duplicate intersection id");

    return { ok: true, report };
  } catch (error) {
    if (error instanceof Invalid) return { ok: false, reason: error.reason };
    throw error;
  }
}
