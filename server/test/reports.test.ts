// SPDX-License-Identifier: Apache-2.0

import { env } from "cloudflare:workers";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { validateReport } from "../src/report";
import { createContext, exampleReport, makeToken, reportRequest, resetDatabase, type TestContext } from "./helpers/context";

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
  ["schema 2", (r) => set(r as never, "schema", 2)],
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
