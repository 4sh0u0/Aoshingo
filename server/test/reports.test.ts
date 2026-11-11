// SPDX-License-Identifier: Apache-2.0

import { env } from "cloudflare:workers";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { validateReport } from "../src/report";
import {
  createContext,
  exampleReport,
  exampleReport2,
  makeToken,
  reportRequest,
  resetDatabase,
  type TestContext,
} from "./helpers/context";

type Report = ReturnType<typeof exampleReport>;
type Mutation = (report: Report, now: number) => void;

const ID = "1234ABCD";
const RAW = "CE010000022A00001234ABCD311384848484";
const DAY = 86_400;

let context: TestContext;
let token: string;

beforeAll(async () => {
  context = await createContext();
  token = (await makeToken(context, { expiresIn: 86_400 })).token;
});

beforeEach(async () => {
  await resetDatabase();
});

async function reportCount(): Promise<number> {
  return (await env.DB.prepare("SELECT count(*) AS n FROM reports").first<number>("n")) ?? 0;
}

async function submit(body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return context.fetch(reportRequest(token, body, headers));
}

function mutated(mutation: Mutation): Report {
  const report = exampleReport(context.clock.seconds);
  mutation(report, context.clock.seconds);
  return report;
}

const intersection = (r: Report) => r.intersections[0]!;
const observation = (r: Report) => intersection(r).observations[0]! as Record<string, unknown>;
const transition = (r: Report) => intersection(r).transitions[0]! as Record<string, unknown>;
const set = (target: Record<string, unknown>, key: string, value: unknown) => {
  if (value === undefined) delete target[key];
  else target[key] = value;
};
const rawWithId = (id: string, length = 36) => `CE010000022A0000${id}`.padEnd(length, "0");
const states = ["NoSignal", "Red", "BlinkGreen", "Green", "None", "Unknown"];

/** Each entry: [description, mutation]. All of these must be accepted. */
const ACCEPTED: [string, Mutation][] = [
  ["the contract example", () => {}],
  ["schema 1 written as 1.0", (r) => set(r as never, "schema", 1.0)],
  ["client absent", (r) => set(r as never, "client", undefined)],
  ["client null", (r) => set(r as never, "client", null)],
  ["client of exactly 40 characters", (r) => (r.client = "aoshingo-ios/" + "1".repeat(27))],
  ["client with + and - in the version", (r) => (r.client = "aoshingo-watchos/1.2.3+build-4")],
  ["50 intersections", (r) => {
    const base = intersection(r);
    r.intersections = Array.from({ length: 50 }, (_, i) => {
      const id = (0x10000000 + i).toString(16).toUpperCase();
      return { ...base, id, observations: [{ ...base.observations[0]!, raw: rawWithId(id) }] };
    });
  }],
  ["no serviceUUIDs", (r) => (intersection(r).serviceUUIDs = [])],
  ["16-bit, 32-bit and 128-bit service UUIDs", (r) => {
    intersection(r).serviceUUIDs = ["FE9F", "0000FE9F", "0000FE9F-0000-1000-8000-00805F9B34FB"];
  }],
  ["8 service UUIDs", (r) => (intersection(r).serviceUUIDs = Array(8).fill("FE9F"))],
  ["emitters 0", (r) => (intersection(r).emitters = 0)],
  ["emitters 32", (r) => (intersection(r).emitters = 32)],
  ["no observations when there is a transition", (r) => (intersection(r).observations = [])],
  ["600 observations", (r) => (intersection(r).observations = Array(600).fill(observation(r)))],
  ["observation t = now - 7 days", (r, now) => set(observation(r), "t", now - 7 * DAY)],
  ["observation t = now + 300", (r, now) => set(observation(r), "t", now + 300)],
  ["raw of 128 characters", (r) => set(observation(r), "raw", rawWithId(ID, 128))],
  ["rssi 0", (r) => set(observation(r), "rssi", 0)],
  ["rssi -130", (r) => set(observation(r), "rssi", -130)],
  ["rssi -5", (r) => set(observation(r), "rssi", -5)],
  ["rssi null", (r) => set(observation(r), "rssi", null)],
  ["rssi absent (treated as null)", (r) => set(observation(r), "rssi", undefined)],
  ["bearing 0", (r) => set(observation(r), "bearing", 0)],
  ["bearing 7", (r) => set(observation(r), "bearing", 7)],
  ["bearing null", (r) => set(observation(r), "bearing", null)],
  ["heading 0", (r) => set(observation(r), "heading", 0)],
  ["heading 7", (r) => set(observation(r), "heading", 7)],
  ["heading absent (treated as null)", (r) => set(observation(r), "heading", undefined)],
  ["no transitions when there is an observation", (r) => (intersection(r).transitions = [])],
  ["300 transitions", (r) => (intersection(r).transitions = Array(300).fill(transition(r)))],
  ["transition t = now - 7 days", (r, now) => set(transition(r), "t", now - 7 * DAY)],
  ["transition t = now + 300", (r, now) => set(transition(r), "t", now + 300)],
  ["slot 6", (r) => set(transition(r), "slot", 6)],
  ...states.flatMap((from): [string, Mutation][] =>
    states
      .filter((to) => to !== from)
      .map((to): [string, Mutation] => [`${from} → ${to}`, (r) => Object.assign(transition(r), { from, to })]),
  ),
];

/** Each entry: [description, mutation]. All of these must be rejected with 400 invalid_report. */
const REJECTED: [string, Mutation][] = [
  // schema
  ["schema 0", (r) => set(r as never, "schema", 0)],
  ["schema 3", (r) => set(r as never, "schema", 3)],
  ["a schema 1 body declared as schema 2 (no emitterInfo for its emitter)", (r) => set(r as never, "schema", 2)],
  ["schema \"1\"", (r) => set(r as never, "schema", "1")],
  ["schema missing", (r) => set(r as never, "schema", undefined)],
  // client
  ["client of 41 characters", (r) => (r.client = "aoshingo-ios/" + "1".repeat(28))],
  ["client with another prefix", (r) => (r.client = "other-ios/0.1.0")],
  ["client with uppercase platform", (r) => (r.client = "aoshingo-iOS/0.1.0")],
  ["client without version", (r) => (r.client = "aoshingo-ios")],
  ["client with a space", (r) => (r.client = "aoshingo-ios/0.1 beta")],
  ["client not a string", (r) => set(r as never, "client", 1)],
  // intersections
  ["no intersections", (r) => (r.intersections = [])],
  ["51 intersections", (r) => {
    const base = intersection(r);
    r.intersections = Array.from({ length: 51 }, (_, i) => {
      const id = (0x10000000 + i).toString(16).toUpperCase();
      return { ...base, id, observations: [{ ...base.observations[0]!, raw: rawWithId(id) }] };
    });
  }],
  ["intersections not an array", (r) => set(r as never, "intersections", {})],
  ["intersections missing", (r) => set(r as never, "intersections", undefined)],
  ["duplicate intersection ids", (r) => r.intersections.push(structuredClone(intersection(r)))],
  ["an intersection that is not an object", (r) => set(r as never, "intersections", [ID])],
  // id
  ["lowercase id", (r) => (intersection(r).id = "1234abcd")],
  ["7-digit id", (r) => (intersection(r).id = "1234ABC")],
  ["9-digit id", (r) => (intersection(r).id = "1234ABCD0")],
  ["non-hex id", (r) => (intersection(r).id = "1234ABCG")],
  ["numeric id", (r) => set(intersection(r) as never, "id", 12345678)],
  // serviceUUIDs
  ["9 service UUIDs", (r) => (intersection(r).serviceUUIDs = Array(9).fill("FE9F"))],
  ["lowercase service UUID", (r) => (intersection(r).serviceUUIDs = ["fe9f"])],
  ["3-digit service UUID", (r) => (intersection(r).serviceUUIDs = ["FE9"])],
  ["128-bit UUID without dashes", (r) => (intersection(r).serviceUUIDs = ["0000FE9F00001000800000805F9B34FB"])],
  ["lowercase 128-bit UUID", (r) => (intersection(r).serviceUUIDs = ["0000fe9f-0000-1000-8000-00805f9b34fb"])],
  ["serviceUUIDs not an array", (r) => set(intersection(r) as never, "serviceUUIDs", "FE9F")],
  ["serviceUUIDs missing", (r) => set(intersection(r) as never, "serviceUUIDs", undefined)],
  ["numeric service UUID", (r) => set(intersection(r) as never, "serviceUUIDs", [0xfe9f])],
  // emitters
  ["emitters 33", (r) => (intersection(r).emitters = 33)],
  ["emitters -1", (r) => (intersection(r).emitters = -1)],
  ["emitters 1.5", (r) => (intersection(r).emitters = 1.5)],
  ["emitters \"1\"", (r) => set(intersection(r) as never, "emitters", "1")],
  ["emitters null", (r) => set(intersection(r) as never, "emitters", null)],
  ["emitters missing", (r) => set(intersection(r) as never, "emitters", undefined)],
  // observations
  ["601 observations", (r) => (intersection(r).observations = Array(601).fill(observation(r)))],
  ["observations not an array", (r) => set(intersection(r) as never, "observations", {})],
  ["observations missing", (r) => set(intersection(r) as never, "observations", undefined)],
  ["observation not an object", (r) => set(intersection(r) as never, "observations", [RAW])],
  ["observation t = now - 7 days - 1", (r, now) => set(observation(r), "t", now - 7 * DAY - 1)],
  ["observation t = now + 301", (r, now) => set(observation(r), "t", now + 301)],
  ["observation t not an integer", (r, now) => set(observation(r), "t", now + 0.5)],
  ["observation t as a string", (r, now) => set(observation(r), "t", String(now))],
  ["observation t missing", (r) => set(observation(r), "t", undefined)],
  ["lowercase raw", (r) => set(observation(r), "raw", RAW.toLowerCase())],
  ["raw of odd length", (r) => set(observation(r), "raw", RAW + "0")],
  ["raw of 22 characters", (r) => set(observation(r), "raw", RAW.slice(0, 22))],
  ["raw of 130 characters", (r) => set(observation(r), "raw", rawWithId(ID, 130))],
  ["raw with another company ID", (r) => set(observation(r), "raw", "CF01" + RAW.slice(4))],
  ["raw with big-endian company ID", (r) => set(observation(r), "raw", "01CE" + RAW.slice(4))],
  ["raw with non-hex characters", (r) => set(observation(r), "raw", RAW.slice(0, -2) + "ZZ")],
  ["raw for another intersection", (r) => set(observation(r), "raw", rawWithId("1234ABCE"))],
  ["raw missing", (r) => set(observation(r), "raw", undefined)],
  ["rssi -135", (r) => set(observation(r), "rssi", -135)],
  ["rssi 5", (r) => set(observation(r), "rssi", 5)],
  ["rssi -67 (not a multiple of 5)", (r) => set(observation(r), "rssi", -67)],
  ["rssi -70.5", (r) => set(observation(r), "rssi", -70.5)],
  ["rssi as a string", (r) => set(observation(r), "rssi", "-70")],
  ["bearing 8", (r) => set(observation(r), "bearing", 8)],
  ["bearing -1", (r) => set(observation(r), "bearing", -1)],
  ["bearing 1.5", (r) => set(observation(r), "bearing", 1.5)],
  ["heading 8", (r) => set(observation(r), "heading", 8)],
  ["heading -1", (r) => set(observation(r), "heading", -1)],
  ["heading as a string", (r) => set(observation(r), "heading", "3")],
  // transitions
  ["301 transitions", (r) => (intersection(r).transitions = Array(301).fill(transition(r)))],
  ["transitions not an array", (r) => set(intersection(r) as never, "transitions", {})],
  ["transitions missing", (r) => set(intersection(r) as never, "transitions", undefined)],
  ["transition t = now - 7 days - 1", (r, now) => set(transition(r), "t", now - 7 * DAY - 1)],
  ["transition t = now + 301", (r, now) => set(transition(r), "t", now + 301)],
  ["transition t not an integer", (r, now) => set(transition(r), "t", now - 0.5)],
  ["slot 0", (r) => set(transition(r), "slot", 0)],
  ["slot 7", (r) => set(transition(r), "slot", 7)],
  ["slot 1.5", (r) => set(transition(r), "slot", 1.5)],
  ["slot missing", (r) => set(transition(r), "slot", undefined)],
  ["unknown from state", (r) => set(transition(r), "from", "Yellow")],
  ["lowercase to state", (r) => set(transition(r), "to", "green")],
  ["to missing", (r) => set(transition(r), "to", undefined)],
  ["from equals to", (r) => set(transition(r), "to", "Red")],
  // intersection content
  ["an intersection with neither observations nor transitions", (r) => {
    intersection(r).observations = [];
    intersection(r).transitions = [];
  }],
  // unexpected fields
  ["an unexpected top-level field", (r) => set(r as never, "latitude", 35.68)],
  ["an unexpected intersection field", (r) => set(intersection(r) as never, "location", [35.68, 139.76])],
  ["an unexpected observation field", (r) => set(observation(r), "deviceModel", "iPhone")],
  ["an unexpected transition field", (r) => set(transition(r), "note", "x")],
  // fields that schema 2 added, even when null or empty
  ...(
    [
      ["emitterInfo", [{ txPower: null, connectable: null }]],
      ["emitterInfo", []],
      ["steps", []],
      ["packets", []],
      ["coverage", []],
      ["labels", []],
    ] as const
  ).map(([key, value]): [string, Mutation] => [
    `schema 1 with intersection.${key} = ${JSON.stringify(value)}`,
    (r) => set(intersection(r) as never, key, value),
  ]),
  ...(["emitter", "distance", "accuracy", "course", "speed", "nearby"] as const).flatMap((key): [string, Mutation][] => [
    [`schema 1 with observation.${key} = 0`, (r) => set(observation(r), key, 0)],
    [`schema 1 with observation.${key} = null`, (r) => set(observation(r), key, null)],
  ]),
  ...(["emitter", "gap", "held", "cycle"] as const).flatMap((key): [string, Mutation][] => [
    [`schema 1 with transition.${key} = 0`, (r) => set(transition(r), key, 0)],
    [`schema 1 with transition.${key} = null`, (r) => set(transition(r), key, null)],
  ]),
];

describe("report validation table", () => {
  it.each(ACCEPTED)("accepts %s", async (_name, mutation) => {
    const report = mutated(mutation);
    const response = await submit(report);
    expect(response.status, JSON.stringify(await response.clone().json())).toBe(202);
    const intersections = report.intersections;
    expect(await response.json()).toEqual({
      accepted: {
        intersections: intersections.length,
        observations: intersections.reduce((n, i) => n + i.observations.length, 0),
        transitions: intersections.reduce((n, i) => n + i.transitions.length, 0),
      },
    });
    expect(await reportCount()).toBe(intersections.length);
  });

  it.each(REJECTED)("rejects %s", async (_name, mutation) => {
    const report = mutated(mutation);
    // The validator must reject it on its own merits...
    expect(validateReport(JSON.parse(JSON.stringify(report)), context.clock.seconds).ok).toBe(false);
    // ...and the endpoint must store nothing.
    const response = await submit(report);
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_report" });
    expect(await reportCount()).toBe(0);
  });

  it("rejects the whole report when only one intersection is invalid", async () => {
    const report = mutated((r) => {
      const second = structuredClone(intersection(r));
      second.id = "0000FFFF";
      r.intersections.push(second); // raw still carries 1234ABCD
    });
    expect((await submit(report)).status).toBe(400);
    expect(await reportCount()).toBe(0);
  });
});

type Report2 = ReturnType<typeof exampleReport2>;
type Mutation2 = (report: Report2, now: number) => void;
type Item = Record<string, unknown>;

function mutated2(mutation: Mutation2): Report2 {
  const report = exampleReport2(context.clock.seconds);
  mutation(report, context.clock.seconds);
  return report;
}

const at = (r: Report2) => r.intersections[0]! as unknown as Item;
const first = (r: Report2, key: string) => (at(r)[key] as Item[])[0]!;
/** Sets `key` on the first item of the list `list` of the first intersection. */
const setFirst = (list: string, key: string, value: unknown): Mutation2 => (r) => set(first(r, list), key, value);
const emitterInfoOf = (n: number) => Array.from({ length: n }, () => ({ txPower: null, connectable: null }));
const SCHEMA2_LISTS = ["emitterInfo", "steps", "packets", "coverage", "labels"];
const NULLABLE_FIELDS: [string, string[]][] = [
  ["observations", ["rssi", "bearing", "heading", "emitter", "distance", "accuracy", "course", "speed", "nearby"]],
  ["transitions", ["emitter", "gap", "held", "cycle"]],
  ["steps", ["from", "emitter", "held"]],
  ["packets", ["minInterval", "medianInterval"]],
  ["labels", ["heading", "bearing", "distance"]],
  ["emitterInfo", ["txPower", "connectable"]],
];

/** Each entry: [description, mutation]. All of these must be accepted. */
const ACCEPTED_2: [string, Mutation2][] = [
  ["the schema 2 contract example", () => {}],
  ["every nullable field null", (r) => {
    for (const [list, keys] of NULLABLE_FIELDS) for (const key of keys) set(first(r, list), key, null);
  }],
  ["every nullable field absent (treated as null)", (r) => {
    for (const [list, keys] of NULLABLE_FIELDS) for (const key of keys) set(first(r, list), key, undefined);
  }],
  ["the added lists absent with no emitters", (r) => {
    for (const key of SCHEMA2_LISTS) set(at(r), key, undefined);
    at(r).emitters = 0;
    set(first(r, "observations"), "emitter", null);
    set(first(r, "transitions"), "emitter", null);
  }],
  ["only steps", (r) => Object.assign(at(r), { observations: [], transitions: [], labels: [] })],
  ["only labels", (r) => Object.assign(at(r), { observations: [], transitions: [], steps: [] })],
  ["only a transition", (r) => Object.assign(at(r), { observations: [], steps: [], labels: [] })],
  ["32 emitters, the last one referenced", (r) => {
    Object.assign(at(r), { emitters: 32, emitterInfo: emitterInfoOf(32) });
    set(first(r, "observations"), "emitter", 31);
    set(first(r, "packets"), "emitter", 31);
  }],
  ["600 steps", (r) => (at(r).steps = Array(600).fill(first(r, "steps")))],
  ["96 packets, one per emitter and type", (r) => {
    Object.assign(at(r), { emitters: 32, emitterInfo: emitterInfoOf(32) });
    at(r).packets = Array.from({ length: 96 }, (_, i) => ({ emitter: i % 32, type: Math.floor(i / 32), count: 1 }));
  }],
  ["60 coverage spans", (r) => (at(r).coverage = Array(60).fill(first(r, "coverage")))],
  ["20 labels", (r) => (at(r).labels = Array(20).fill(first(r, "labels")))],
  ["txPower -127 and connectable true", (r) => Object.assign(first(r, "emitterInfo"), { txPower: -127, connectable: true })],
  ["txPower 20", setFirst("emitterInfo", "txPower", 20)],
  ...[0, 10, 20, 40, 80, 160].map((value): [string, Mutation2] => [`distance ${value}`, setFirst("observations", "distance", value)]),
  ...[5, 10, 20, 30].map((value): [string, Mutation2] => [`accuracy ${value}`, setFirst("observations", "accuracy", value)]),
  ...[0, 1, 5, 10, 20, 50, 100].map((value): [string, Mutation2] => [`nearby ${value}`, setFirst("observations", "nearby", value)]),
  ...[0, 1, 2].map((value): [string, Mutation2] => [`speed ${value}`, setFirst("observations", "speed", value)]),
  ["course 0", setFirst("observations", "course", 0)],
  ["course 7", setFirst("observations", "course", 7)],
  ["gap 0", setFirst("transitions", "gap", 0)],
  ["gap 5000", setFirst("transitions", "gap", 5000)],
  ["held 0", setFirst("transitions", "held", 0)],
  ["held 3600000", setFirst("transitions", "held", 3_600_000)],
  ["cycle 3600000", setFirst("transitions", "cycle", 3_600_000)],
  ["a step from unknown to 1", (r) => Object.assign(first(r, "steps"), { from: null, to: 1 })],
  ["a step from 8 to unknown", (r) => Object.assign(first(r, "steps"), { from: 8, to: null })],
  ["a step held 3600000", setFirst("steps", "held", 3_600_000)],
  ["a step of state NoSignal", setFirst("steps", "state", "NoSignal")],
  ["a step at slot 6", setFirst("steps", "slot", 6)],
  ["a packet counted once, without intervals", (r) => Object.assign(first(r, "packets"), { count: 1, minInterval: null, medianInterval: null })],
  ["a packet with only a median interval", setFirst("packets", "minInterval", null)],
  ["equal min and median intervals", (r) => Object.assign(first(r, "packets"), { minInterval: 600_000, medianInterval: 600_000 })],
  ["intervals of 0", (r) => Object.assign(first(r, "packets"), { minInterval: 0, medianInterval: 0 })],
  ["packet count 100000, type 0", (r) => Object.assign(first(r, "packets"), { count: 100_000, type: 0 })],
  ["coverage of one instant", (r, now) => Object.assign(first(r, "coverage"), { start: now, end: now })],
  ["coverage from now - 7 days to now + 300", (r, now) => Object.assign(first(r, "coverage"), { start: now - 7 * DAY, end: now + 300 })],
  ["a button label without slot or position", (r) => {
    at(r).labels = [{ t: first(r, "labels").t, kind: "button" }];
  }],
  ["a button label with a slot", setFirst("labels", "kind", "button")],
  ["a crosswalk label at slot 6 without heading, bearing or distance", (r) => {
    at(r).labels = [{ t: first(r, "labels").t, kind: "crosswalk", slot: 6 }];
  }],
  ["label distance 160", setFirst("labels", "distance", 160)],
];

/** Each entry: [description, mutation]. All of these must be rejected with 400 invalid_report. */
const REJECTED_2: [string, Mutation2][] = [
  // intersection
  ["an empty intersection (only packets and coverage)", (r) => {
    Object.assign(at(r), { observations: [], transitions: [], steps: [], labels: [] });
  }],
  ["an empty intersection (lists absent)", (r) => {
    for (const key of ["steps", "labels"]) set(at(r), key, undefined);
    Object.assign(at(r), { observations: [], transitions: [] });
  }],
  ["observations missing", (r) => set(at(r), "observations", undefined)],
  ["transitions missing", (r) => set(at(r), "transitions", undefined)],
  ...SCHEMA2_LISTS.map((key): [string, Mutation2] => [`${key} null`, (r) => set(at(r), key, null)]),
  ...SCHEMA2_LISTS.map((key): [string, Mutation2] => [`${key} not an array`, (r) => set(at(r), key, {})]),
  ...SCHEMA2_LISTS.map((key): [string, Mutation2] => [`a ${key} item that is not an object`, (r) => set(at(r), key, [1])]),
  ["an unexpected intersection field", (r) => set(at(r), "location", [35.68, 139.76])],
  // emitterInfo
  ["emitterInfo longer than emitters", (r) => (at(r).emitterInfo = emitterInfoOf(2))],
  ["emitterInfo shorter than emitters", (r) => (at(r).emitters = 2)],
  ["emitterInfo absent with an emitter", (r) => set(at(r), "emitterInfo", undefined)],
  ["txPower -128", setFirst("emitterInfo", "txPower", -128)],
  ["txPower 21", setFirst("emitterInfo", "txPower", 21)],
  ["txPower 1.5", setFirst("emitterInfo", "txPower", 1.5)],
  ["connectable as a string", setFirst("emitterInfo", "connectable", "true")],
  ["connectable as a number", setFirst("emitterInfo", "connectable", 1)],
  ["an unexpected emitterInfo field", setFirst("emitterInfo", "name", "PICS")],
  // observations
  ["observation emitter = emitters", setFirst("observations", "emitter", 1)],
  ["observation emitter -1", setFirst("observations", "emitter", -1)],
  ["observation emitter with no emitters", (r) => {
    Object.assign(at(r), { emitters: 0, emitterInfo: [], packets: [] });
    set(first(r, "transitions"), "emitter", null);
    set(first(r, "steps"), "emitter", null);
  }],
  ["distance 15", setFirst("observations", "distance", 15)],
  ["distance 27 (not rounded)", setFirst("observations", "distance", 27)],
  ["distance 320", setFirst("observations", "distance", 320)],
  ["distance -10", setFirst("observations", "distance", -10)],
  ["distance as a string", setFirst("observations", "distance", "20")],
  ["accuracy 0", setFirst("observations", "accuracy", 0)],
  ["accuracy 7", setFirst("observations", "accuracy", 7)],
  ["accuracy 40", setFirst("observations", "accuracy", 40)],
  ["course 8", setFirst("observations", "course", 8)],
  ["course -1", setFirst("observations", "course", -1)],
  ["speed 3", setFirst("observations", "speed", 3)],
  ["speed 1.5", setFirst("observations", "speed", 1.5)],
  ["nearby 2", setFirst("observations", "nearby", 2)],
  ["nearby 200", setFirst("observations", "nearby", 200)],
  ["an unexpected observation field", setFirst("observations", "latitude", 35.68)],
  // transitions
  ["transition emitter = emitters", setFirst("transitions", "emitter", 1)],
  ["gap 50", setFirst("transitions", "gap", 50)],
  ["gap 5100", setFirst("transitions", "gap", 5100)],
  ["gap -100", setFirst("transitions", "gap", -100)],
  ["held 150", setFirst("transitions", "held", 150)],
  ["held 3600100", setFirst("transitions", "held", 3_600_100)],
  ["cycle 3600100", setFirst("transitions", "cycle", 3_600_100)],
  ["cycle -100", setFirst("transitions", "cycle", -100)],
  ["cycle as a string", setFirst("transitions", "cycle", "98700")],
  ["an unexpected transition field", setFirst("transitions", "note", "x")],
  // steps
  ["601 steps", (r) => (at(r).steps = Array(601).fill(first(r, "steps")))],
  ["a step from 5 to 5", (r) => Object.assign(first(r, "steps"), { from: 5, to: 5 })],
  ["a step from unknown to unknown", (r) => Object.assign(first(r, "steps"), { from: null, to: null })],
  ["a step from 0", setFirst("steps", "from", 0)],
  ["a step to 9", setFirst("steps", "to", 9)],
  ["a step at slot 0", setFirst("steps", "slot", 0)],
  ["a step at slot 7", setFirst("steps", "slot", 7)],
  ["a step without slot", setFirst("steps", "slot", undefined)],
  ["a step of an unknown state", setFirst("steps", "state", "Yellow")],
  ["a step without state", setFirst("steps", "state", undefined)],
  ["a step held 150", setFirst("steps", "held", 150)],
  ["a step held 3600100", setFirst("steps", "held", 3_600_100)],
  ["a step emitter = emitters", setFirst("steps", "emitter", 1)],
  ["a step t = now - 7 days - 1", (r, now) => set(first(r, "steps"), "t", now - 7 * DAY - 1)],
  ["a step t = now + 301", (r, now) => set(first(r, "steps"), "t", now + 301)],
  ["a step without t", setFirst("steps", "t", undefined)],
  ["an unexpected step field", setFirst("steps", "note", "x")],
  // packets
  ["97 packets", (r) => {
    Object.assign(at(r), { emitters: 32, emitterInfo: emitterInfoOf(32) });
    at(r).packets = Array.from({ length: 97 }, (_, i) => ({ emitter: i % 32, type: Math.floor(i / 32) % 3, count: 1 }));
  }],
  ["two packets of the same emitter and type", (r) => {
    at(r).packets = [first(r, "packets"), { ...first(r, "packets"), count: 2, minInterval: null, medianInterval: null }];
  }],
  ["packet emitter = emitters", setFirst("packets", "emitter", 1)],
  ["packet emitter null", setFirst("packets", "emitter", null)],
  ["packet emitter missing", setFirst("packets", "emitter", undefined)],
  ["packet type 3", setFirst("packets", "type", 3)],
  ["packet type -1", setFirst("packets", "type", -1)],
  ["packet type missing", setFirst("packets", "type", undefined)],
  ["packet count 0", setFirst("packets", "count", 0)],
  ["packet count 100001", setFirst("packets", "count", 100_001)],
  ["packet count missing", setFirst("packets", "count", undefined)],
  ["minInterval 95 (not a multiple of 10)", setFirst("packets", "minInterval", 95)],
  ["medianInterval 600010", setFirst("packets", "medianInterval", 600_010)],
  ["minInterval -10", setFirst("packets", "minInterval", -10)],
  ["minInterval above medianInterval", (r) => Object.assign(first(r, "packets"), { minInterval: 210, medianInterval: 200 })],
  ["intervals for a packet counted once", (r) => Object.assign(first(r, "packets"), { count: 1 })],
  ["a median interval for a packet counted once", (r) => Object.assign(first(r, "packets"), { count: 1, minInterval: null })],
  ["a min interval for a packet counted once", (r) => Object.assign(first(r, "packets"), { count: 1, medianInterval: null })],
  ["an unexpected packets field", setFirst("packets", "rssi", -70)],
  // coverage
  ["61 coverage spans", (r) => (at(r).coverage = Array(61).fill(first(r, "coverage")))],
  ["coverage start after end", (r, now) => Object.assign(first(r, "coverage"), { start: now - 10, end: now - 11 })],
  ["coverage start = now - 7 days - 1", (r, now) => set(first(r, "coverage"), "start", now - 7 * DAY - 1)],
  ["coverage end = now + 301", (r, now) => set(first(r, "coverage"), "end", now + 301)],
  ["coverage without end", setFirst("coverage", "end", undefined)],
  ["coverage start null", setFirst("coverage", "start", null)],
  ["an unexpected coverage field", setFirst("coverage", "t", 1)],
  // labels
  ["21 labels", (r) => (at(r).labels = Array(21).fill(first(r, "labels")))],
  ["a crosswalk label with slot null", setFirst("labels", "slot", null)],
  ["a crosswalk label without slot", setFirst("labels", "slot", undefined)],
  ["a label of another kind", setFirst("labels", "kind", "signal")],
  ["a label without kind", setFirst("labels", "kind", undefined)],
  ["a label at slot 7", setFirst("labels", "slot", 7)],
  ["a label heading 8", setFirst("labels", "heading", 8)],
  ["a label bearing -1", setFirst("labels", "bearing", -1)],
  ["a label distance 15", setFirst("labels", "distance", 15)],
  ["a label t = now + 301", (r, now) => set(first(r, "labels"), "t", now + 301)],
  ["a label without t", setFirst("labels", "t", undefined)],
  ["an unexpected label field", setFirst("labels", "note", "crossing 1")],
];

describe("schema 2 validation table", () => {
  it.each(ACCEPTED_2)("accepts %s", async (_name, mutation) => {
    const report = mutated2(mutation);
    const response = await submit(report);
    expect(response.status, JSON.stringify(await response.clone().json())).toBe(202);
    const intersections = report.intersections;
    expect(await response.json()).toEqual({
      accepted: {
        intersections: intersections.length,
        observations: intersections.reduce((n, i) => n + i.observations.length, 0),
        transitions: intersections.reduce((n, i) => n + i.transitions.length, 0),
      },
    });
    expect(await reportCount()).toBe(intersections.length);
  });

  it.each(REJECTED_2)("rejects %s", async (_name, mutation) => {
    const report = mutated2(mutation);
    expect(validateReport(JSON.parse(JSON.stringify(report)), context.clock.seconds).ok).toBe(false);
    const response = await submit(report);
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_report" });
    expect(await reportCount()).toBe(0);
  });

  it("normalises -0 to 0", () => {
    const text = JSON.stringify(exampleReport2(context.clock.seconds))
      .replace('"bearing":3', '"bearing":-0')
      .replace('"distance":20', '"distance":-0');
    const result = validateReport(JSON.parse(text), context.clock.seconds);
    expect(result.ok).toBe(true);
    const observation = result.ok && result.report.schema === 2 ? result.report.intersections[0]!.observations[0]! : null;
    expect(Object.is(observation?.bearing, 0)).toBe(true);
    expect(Object.is(observation?.distance, 0)).toBe(true);
  });
});

describe("schema 2 storage", () => {
  it("stores every field written out, null when unknown, and the lists even when absent", async () => {
    const report = mutated2((r, now) => {
      r.intersections.push({
        id: "0000FFFF",
        serviceUUIDs: ["FE9F"],
        emitters: 0,
        observations: [{ t: now - 1, raw: rawWithId("0000FFFF") }],
        transitions: [{ t: now - 2, slot: 2, from: "Green", to: "BlinkGreen" }],
      } as never);
    });
    expect((await submit(report)).status).toBe(202);

    const { results } = await env.DB.prepare(
      `SELECT intersection_id, schema, client, observation_count, transition_count, aggregate_items, payload
         FROM reports ORDER BY intersection_id`,
    ).all<Record<string, unknown>>();
    const { id: _id, ...example } = report.intersections[0]!;
    const now = context.clock.seconds;
    expect(results).toEqual([
      {
        intersection_id: "0000FFFF",
        schema: 2,
        client: "aoshingo-ios/0.2.0",
        observation_count: 1,
        transition_count: 1,
        // 2 x 1 observation + 3 x 1 transition.
        aggregate_items: 5,
        payload: JSON.stringify({
          serviceUUIDs: ["FE9F"],
          emitters: 0,
          emitterInfo: [],
          observations: [
            {
              t: now - 1,
              raw: rawWithId("0000FFFF"),
              rssi: null,
              bearing: null,
              heading: null,
              emitter: null,
              distance: null,
              accuracy: null,
              course: null,
              speed: null,
              nearby: null,
            },
          ],
          transitions: [
            { t: now - 2, slot: 2, from: "Green", to: "BlinkGreen", emitter: null, gap: null, held: null, cycle: null },
          ],
          steps: [],
          packets: [],
          coverage: [],
          labels: [],
        }),
      },
      {
        intersection_id: "1234ABCD",
        schema: 2,
        client: "aoshingo-ios/0.2.0",
        observation_count: 1,
        transition_count: 1,
        // 2 x 1 observation + 3 x 1 transition + 1 step + 1 label.
        aggregate_items: 7,
        // The example spells out every field, in the stored order.
        payload: JSON.stringify(example),
      },
    ]);
  });

  it("stores absent fields of the added items as null", async () => {
    const report = mutated2((r) => {
      for (const [list, keys] of NULLABLE_FIELDS) for (const key of keys) set(first(r, list), key, undefined);
      at(r).labels = [{ t: first(r, "labels").t, kind: "button" }];
    });
    expect((await submit(report)).status).toBe(202);
    const payload = JSON.parse((await env.DB.prepare("SELECT payload FROM reports").first<string>("payload"))!);
    expect(payload.emitterInfo).toEqual([{ txPower: null, connectable: null }]);
    expect(payload.steps[0]).toMatchObject({ from: null, to: 7, emitter: null, held: null });
    expect(payload.packets[0]).toEqual({ emitter: 0, type: 2, count: 1180, minInterval: null, medianInterval: null });
    expect(payload.labels[0]).toEqual({
      t: report.intersections[0]!.labels[0]!.t,
      kind: "button",
      slot: null,
      heading: null,
      bearing: null,
      distance: null,
    });
  });

  it("weighs a schema 1 row by its observations and transitions", async () => {
    expect((await submit(exampleReport(context.clock.seconds))).status).toBe(202);
    expect(await env.DB.prepare("SELECT aggregate_items FROM reports").first("aggregate_items")).toBe(2);
  });
});

/**
 * A PICS packet as iOS delivers it ("CE01" + payload), built like packet(type:length:) in
 * Packages/AoshingoKit/Tests/PICSKitTests/PICSParserTests.swift: message ID 42 and intersection
 * 1234ABCD, everything else zero unless `fill` sets it.
 */
function pics(type: number, length: number, fill: Record<number, number[]> = {}): string {
  const bytes = new Array<number>(length).fill(0);
  bytes[2] = type;
  bytes[3] = 42;
  bytes.splice(6, 4, 0x12, 0x34, 0xab, 0xcd);
  for (const [offset, values] of Object.entries(fill)) bytes.splice(Number(offset), values.length, ...values);
  return "CE01" + bytes.map((byte) => byte.toString(16).padStart(2, "0")).join("").toUpperCase();
}

const utf8 = (text: string) => [...new TextEncoder().encode(text)];
const int32 = (value: number) => {
  const view = new DataView(new ArrayBuffer(4));
  view.setInt32(0, value);
  return [...new Uint8Array(view.buffer)];
};

/** Packets of a known type that PICSParser.parse(manufacturerData:) accepts; the app uploads them, so the server must accept them all. */
const PARSER_ACCEPTS: [string, string][] = [
  // Vectors of PICSParserTests.swift.
  ["type 0 with a UTF-8 name (24 bytes)", pics(0, 24, { 10: utf8("交差点A") })],
  ["type 1 with coordinates (18 bytes)", pics(1, 18, { 10: [...int32(-35_123_456), ...int32(139_654_321)] })],
  ["type 2 with seven signal bytes (24 bytes)", pics(2, 24, { 10: [0x00, 0x71, 0x82, 0xf3, 0x24, 0x0f, 0x33] })],
  ["type 2 with one signal (11 bytes)", pics(2, 11, { 10: [0x13] })],
  ["type 2 with two signals (12 bytes)", pics(2, 12, { 10: [0x83, 0x21] })],
  ["type 2 as iOS delivers it (16 bytes)", pics(2, 16)],
  ["type 0 with NUL, an invalid byte and a BOM in the name", pics(0, 24, { 10: [0xef, 0xbb, 0xbf, 0x58, 0x00, 0xff] })],
  // Lengths the parser accepts beyond what it reads.
  ["type 0 longer than 24 bytes", pics(0, 31)],
  ["type 1 longer than 18 bytes", pics(1, 25)],
  ["the longest raw the server takes (62 payload bytes)", pics(2, 62)],
];

/** Packets that PICSParser rejects (too short for their type); the app never uploads them. */
const PARSER_REJECTS: [string, string][] = [
  ["type 0 one byte short (23 bytes)", pics(0, 23)],
  ["type 1 one byte short (17 bytes)", pics(1, 17)],
  ["type 2 without a signal byte (10 bytes)", pics(2, 10)],
  // Types the parser does not decode; the app does not upload them (ReportContract.isUploadable).
  ["unknown type 99 with only the header (10 bytes)", pics(99, 10)],
  ["unknown type 3 with a body (20 bytes)", pics(3, 20)],
];

describe("raw PICS packets (rules of PICSParser in PICSPacket.swift)", () => {
  const withRaw = (raw: string) => mutated((r) => set(observation(r), "raw", raw));

  it.each(PARSER_ACCEPTS)("accepts %s", async (_name, raw) => {
    expect(validateReport(withRaw(raw), context.clock.seconds)).toMatchObject({ ok: true });
    expect((await submit(withRaw(raw))).status).toBe(202);
  });

  it.each(PARSER_REJECTS)("rejects %s", async (_name, raw) => {
    expect(validateReport(withRaw(raw), context.clock.seconds).ok).toBe(false);
    const response = await submit(withRaw(raw));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_report" });
    expect(await reportCount()).toBe(0);
  });

  it("accepts every packet of the app's demo mode (DemoAdvertiser.swift)", async () => {
    const demo = (type: number, length: number, fill: Record<number, number[]>) => {
      const raw = pics(type, length, fill);
      // Demo packets use intersection 00000001 and message ID = step.
      return raw.slice(0, 10) + "00" + raw.slice(12, 16) + "00000001" + raw.slice(24);
    };
    const packets = [
      demo(0, 24, { 10: utf8("DEMO CROSSING") }),
      demo(1, 18, { 10: [...int32(35_681_236), ...int32(139_767_125)] }),
      demo(2, 16, { 10: [0x73, 0x71, 0x84, 0x84, 0x84, 0x84] }),
    ];
    const report = mutated((r) => {
      intersection(r).id = "00000001";
      intersection(r).observations = packets.map((raw) => ({ ...intersection(r).observations[0]!, raw }));
    });
    expect((await submit(report)).status).toBe(202);
  });
});

describe("report body handling", () => {
  it("rejects bodies that are not a JSON object", async () => {
    for (const body of ["", "not json", "[]", "null", "1", '{"schema":1', "\"text\""]) {
      const response = await submit(body);
      expect(response.status, body).toBe(400);
      expect(await response.json()).toEqual({ error: "invalid_report" });
    }
  });

  it("rejects invalid UTF-8", async () => {
    const valid = new TextEncoder().encode(JSON.stringify(exampleReport(context.clock.seconds)));
    // An invalid two-byte sequence inside the "client" string.
    const body = new Uint8Array([...valid.subarray(0, 25), 0xc3, 0x28, ...valid.subarray(25)]);
    const invalid = await context.fetch(
      new Request("https://reports.example/v1/reports", {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body,
      }),
    );
    expect(invalid.status).toBe(400);
    expect(await invalid.json()).toEqual({ error: "invalid_report" });
  });

  it("returns 415 for non-JSON content types", async () => {
    const report = exampleReport(context.clock.seconds);
    for (const contentType of ["text/plain", "application/x-www-form-urlencoded", "application/json; charset=iso-8859-1", "application/jsonx"]) {
      const response = await submit(report, { "content-type": contentType });
      expect(response.status, contentType).toBe(415);
      expect(await response.json()).toEqual({ error: "unsupported_media_type" });
    }
    const missing = new Request("https://reports.example/v1/reports", {
      method: "POST",
      headers: { authorization: `Bearer ${token}` },
      body: new TextEncoder().encode(JSON.stringify(report)),
    });
    expect((await context.fetch(missing)).status).toBe(415);
    for (const contentType of ["application/json; charset=utf-8", "Application/JSON; charset=\"UTF-8\""]) {
      expect((await submit(report, { "content-type": contentType })).status, contentType).toBe(202);
    }
  });

  it("accepts exactly 256 KiB and rejects one byte more with 413", async () => {
    const json = JSON.stringify(exampleReport(context.clock.seconds));
    const limit = 256 * 1024;
    const exact = json + " ".repeat(limit - json.length);
    expect(new TextEncoder().encode(exact).byteLength).toBe(limit);
    expect((await submit(exact)).status).toBe(202);

    const over = await submit(exact + " ");
    expect(over.status).toBe(413);
    expect(await over.json()).toEqual({ error: "too_large" });
  });

  it("enforces the limit on streamed bodies without Content-Length", async () => {
    const chunk = new TextEncoder().encode(" ".repeat(64 * 1024));
    let sent = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (sent >= 5) controller.close();
        else {
          sent++;
          controller.enqueue(chunk);
        }
      },
    });
    const request = new Request("https://reports.example/v1/reports", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: stream,
    });
    expect(request.headers.get("content-length")).toBeNull();
    const response = await context.fetch(request);
    expect(response.status).toBe(413);
  });

  it("stores one row per intersection with the validated payload", async () => {
    const report = exampleReport(context.clock.seconds);
    const second = structuredClone(report.intersections[0]!);
    second.id = "0000FFFF";
    second.observations[0]!.raw = rawWithId("0000FFFF");
    second.transitions = [];
    report.intersections.push(second);
    expect((await submit(report)).status).toBe(202);

    const { results } = await env.DB.prepare(
      "SELECT intersection_id, received_day, schema, client, observation_count, transition_count, payload FROM reports ORDER BY intersection_id",
    ).all<Record<string, unknown>>();
    const day = new Date(context.clock.ms).toISOString().slice(0, 10);
    expect(results).toEqual([
      {
        intersection_id: "0000FFFF",
        received_day: day,
        schema: 1,
        client: "aoshingo-ios/0.1.0",
        observation_count: 1,
        transition_count: 0,
        payload: JSON.stringify({
          serviceUUIDs: [],
          emitters: 1,
          observations: second.observations,
          transitions: [],
        }),
      },
      {
        intersection_id: "1234ABCD",
        received_day: day,
        schema: 1,
        client: "aoshingo-ios/0.1.0",
        observation_count: 1,
        transition_count: 1,
        payload: JSON.stringify({
          serviceUUIDs: [],
          emitters: 1,
          observations: report.intersections[0]!.observations,
          transitions: report.intersections[0]!.transitions,
        }),
      },
    ]);
  });

  it("stores absent nullable fields and client as null", async () => {
    const report = mutated((r) => {
      set(r as never, "client", undefined);
      set(observation(r), "rssi", undefined);
      set(observation(r), "bearing", undefined);
      set(observation(r), "heading", undefined);
    });
    expect((await submit(report)).status).toBe(202);
    const row = await env.DB.prepare("SELECT client, payload FROM reports").first<{ client: null; payload: string }>();
    expect(row?.client).toBeNull();
    expect(JSON.parse(row!.payload).observations[0]).toEqual({
      t: report.intersections[0]!.observations[0]!.t,
      raw: RAW,
      rssi: null,
      bearing: null,
      heading: null,
    });
  });
});
