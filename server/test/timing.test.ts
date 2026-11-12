// SPDX-License-Identifier: Apache-2.0

// The calendar and the fitting cron of docs/timing-estimation.md ("暦" and "当てはめ").

import { createExecutionContext, createScheduledController } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import type { Schema3Observation, Schema4Report, Schema4Transition } from "../src/report";
import { storeReport, utcDay } from "../src/storage";
import {
  dayDate,
  dayNumber,
  dayType,
  DEFAULT_TIMING_LIMITS,
  HOLIDAYS,
  isExcludedDay,
  jstDay,
  maxTimingQueries,
  phaseFit,
  PLAN_KEEP_DAYS,
  runTimingJob,
  timeBin,
  TIMING_CRON,
} from "../src/timing";
import { createContext, meteredDatabase, resetDatabase, type TestContext } from "./helpers/context";

// Friday 2026-11-27 18:30 UTC = Saturday 2026-11-28 03:30 JST, when the timing cron runs.
const NOW = Date.UTC(2026, 10, 27, 18, 30);
const TODAY = "2026-11-27";
// 21 days before TODAY: plans whose last day is before this are deleted.
const KEEP_FROM = "2026-11-06";
// Seven weekdays (JST), Thursday 2026-11-12 to Friday 2026-11-20, no holidays: the fewest that
// pass the publication threshold.
const WEEKDAYS = ["2026-11-12", "2026-11-13", "2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20"];
const ID = "1234ABCD";

let context: TestContext;

beforeEach(async () => {
  await resetDatabase();
  context = await createContext();
  context.clock.ms = NOW;
});

/** Unix ms of a JST wall-clock time on `date` (YYYY-MM-DD). */
function jst(date: string, hours: number, minutes = 0, seconds = 0, ms = 0): number {
  const [year, month, day] = date.split("-").map(Number);
  return Date.UTC(year!, month! - 1, day!, hours - 9, minutes, seconds, ms);
}

/**
 * A schema 4 transition whose T (t x 1000 + ms - gap / 2) is `at`. `at` and half the gap must be
 * multiples of 100.
 */
function change(
  at: number,
  from: string,
  to: string,
  fields: { slot?: number; held?: number | null; cycle?: number | null; gap?: number | null } = {},
): Schema4Transition {
  const gap = fields.gap ?? null;
  const shifted = at + (gap ?? 0) / 2;
  return {
    t: Math.floor(shifted / 1000),
    slot: fields.slot ?? 1,
    from,
    to,
    emitter: null,
    gap,
    held: fields.held ?? null,
    cycle: fields.cycle ?? null,
    ms: shifted % 1000,
  };
}

interface Signal {
  /** ms */
  cycle: number;
  /** ms after the reference */
  phase: number;
  reference: "epoch" | "midnight";
}

const FIXED: Signal = { cycle: 120_000, phase: 37_400, reference: "epoch" };

/** Green starts of `signal` on `date` (JST) from `fromMinute` to `toMinute` after midnight. */
function greenStarts(signal: Signal, date: string, fromMinute = 7 * 60, toMinute = 7 * 60 + 30): number[] {
  const midnight = jst(date, 0);
  const start = midnight + fromMinute * 60_000;
  const end = midnight + toMinute * 60_000;
  const base = signal.reference === "epoch" ? 0 : midnight;
  const offset = (((base + signal.phase - start) % signal.cycle) + signal.cycle) % signal.cycle;
  const starts: number[] = [];
  for (let at = start + offset; at < end; at += signal.cycle) starts.push(at);
  return starts;
}

interface SignalOptions {
  slot?: number;
  /** The cycle field of the k-th green start (default: the signal's cycle). */
  cycleOf?: (k: number, at: number) => number | null;
  /** Shifts the k-th green start (a multiple of 100). */
  jitterOf?: (k: number) => number;
  /** Adds Green → BlinkGreen (held 24 s) and BlinkGreen → Red (held 6 s). Default true. */
  holds?: boolean;
  fromMinute?: number;
  toMinute?: number;
}

/** The transitions a phone near `signal` records on `date` in bin 14 (07:00-07:30 JST). */
function signalChanges(signal: Signal, date: string, options: SignalOptions = {}): Schema4Transition[] {
  const slot = options.slot ?? 1;
  const changes: Schema4Transition[] = [];
  greenStarts(signal, date, options.fromMinute, options.toMinute).forEach((start, k) => {
    const at = start + (options.jitterOf?.(k) ?? 0);
    const cycle = options.cycleOf ? options.cycleOf(k, at) : signal.cycle;
    changes.push(change(at, "Red", "Green", { slot, cycle, held: 90_000, gap: 200 }));
    if (options.holds ?? true) {
      changes.push(change(at + 24_000, "Green", "BlinkGreen", { slot, held: 24_000 }));
      changes.push(change(at + 30_000, "BlinkGreen", "Red", { slot, held: 6_000 }));
    }
  });
  return changes;
}

const OBSERVATION = {
  rssi: -70,
  bearing: null,
  heading: null,
  emitter: null,
  distance: null,
  accuracy: null,
  course: null,
  speed: null,
  nearby: null,
  activity: null,
};

/** A PICS packet of `type` from intersection `id`; `tail` makes packets of one type differ. */
function raw(id: string, type: number, tail = "00"): string {
  const length = type === 0 ? 24 : 18;
  return `CE010000${type.toString(16).padStart(2, "0")}2A0000${id}`.padEnd(4 + 2 * length - 2, "0") + tail;
}

interface StoreOptions {
  /** When the server received the report (default: a minute after its last transition). */
  received?: number;
  /** false stores the row with clock_ok = 0 (the device clock 5 s off). */
  clockOk?: boolean;
  observations?: Schema3Observation[];
}

/** Stores one schema 4 report row of intersection `id` with `transitions`. */
async function store(id: string, transitions: Schema4Transition[], options: StoreOptions = {}): Promise<void> {
  const last = Math.max(...transitions.map((x) => x.t * 1000), ...(options.observations ?? []).map((o) => o.t * 1000));
  const received = options.received ?? last + 60_000;
  const report: Schema4Report = {
    schema: 4,
    client: "aoshingo-ios/0.3.0",
    sentAt: options.clockOk === false ? received - 5_000 : received,
    intersections: [
      {
        id,
        serviceUUIDs: [],
        emitters: 0,
        emitterInfo: [],
        observations: options.observations ?? [],
        transitions,
        steps: [],
        packets: [],
        coverage: [],
        labels: [],
      },
    ],
  };
  await storeReport(env.DB, report, received);
}

/** One report row per date, each with `signal`'s transitions of that date. */
async function storeDays(id: string, signal: Signal, dates: string[], options: SignalOptions = {}): Promise<void> {
  for (const date of dates) await store(id, signalChanges(signal, date, options));
}

async function plans(id = ID): Promise<Record<string, unknown>[]> {
  return (
    await env.DB.prepare(
      `SELECT slot, day_type, bin, cycle_ms, reference, phase_ms, spread_ms, green_ms, blink_ms, last_day, updated_day
         FROM timing_plans WHERE intersection_id = ?1 ORDER BY slot, day_type, bin`,
    )
      .bind(id)
      .all<Record<string, unknown>>()
  ).results;
}

async function rows(sql: string): Promise<Record<string, unknown>[]> {
  return (await env.DB.prepare(sql).all<Record<string, unknown>>()).results;
}

async function runCron(cron: string, at = NOW): Promise<void> {
  context.clock.ms = at;
  await context.app.scheduled(createScheduledController({ cron }), context.env, createExecutionContext());
}

describe("calendar", () => {
  it("holds the holidays of 2026 and 2027 from docs/timing-estimation.md", () => {
    expect(HOLIDAYS.filter((day) => day.startsWith("2026"))).toHaveLength(18);
    expect(HOLIDAYS.filter((day) => day.startsWith("2027"))).toHaveLength(17);
    expect(HOLIDAYS).toContain("2026-05-06");
    expect(HOLIDAYS).toContain("2027-03-22");
    expect([...HOLIDAYS].sort()).toEqual(HOLIDAYS);
  });

  it("gives Monday to Friday day type 0, Saturday 1 and Sunday 2", () => {
    const week: [string, number][] = [
      ["2026-11-16", 0], // Monday
      ["2026-11-17", 0],
      ["2026-11-18", 0],
      ["2026-11-19", 0],
      ["2026-11-20", 0], // Friday
      ["2026-11-21", 1], // Saturday
      ["2026-11-22", 2], // Sunday
      ["1970-01-01", 0], // a Thursday, day 0
      ["1970-01-03", 1],
      ["1969-12-28", 2],
    ];
    for (const [date, type] of week) {
      expect(dayType(dayNumber(date)), date).toBe(type);
      const weekday = new Date(`${date}T00:00:00Z`).getUTCDay();
      expect(type, date).toBe(weekday === 0 ? 2 : weekday === 6 ? 1 : 0);
    }
  });

  it("excludes holidays, December 29 to January 3, and every day outside 2026 and 2027", () => {
    const excluded = [
      "2026-01-01",
      "2026-01-02",
      "2026-01-03",
      "2026-01-12",
      "2026-05-06",
      "2026-11-03",
      "2026-11-23",
      "2026-12-29",
      "2026-12-31",
      "2027-01-01",
      "2027-01-03",
      "2027-03-22",
      "2027-11-23",
      "2027-12-29",
      "2027-12-31",
      // Outside the holiday table, before and after.
      "2025-06-02",
      "2025-12-28",
      "2028-01-04",
      "2028-06-05",
    ];
    const included = ["2026-01-04", "2026-01-05", "2026-11-24", "2026-12-28", "2027-01-04", "2027-12-28", "2026-11-21"];
    for (const date of excluded) expect(isExcludedDay(dayNumber(date)), date).toBe(true);
    for (const date of included) expect(isExcludedDay(dayNumber(date)), date).toBe(false);
    for (const date of HOLIDAYS) expect(isExcludedDay(dayNumber(date)), date).toBe(true);
  });

  it("dates and bins by JST, at day and bin boundaries", () => {
    const cases: [number, string, number][] = [
      [jst("2026-11-20", 0), "2026-11-20", 0],
      [jst("2026-11-20", 0, 29, 59, 999), "2026-11-20", 0],
      [jst("2026-11-20", 0, 30), "2026-11-20", 1],
      [jst("2026-11-20", 7, 15), "2026-11-20", 14],
      [jst("2026-11-20", 23, 30), "2026-11-20", 47],
      [jst("2026-11-20", 23, 59, 59, 999), "2026-11-20", 47],
      // 15:00 UTC is midnight JST of the next day.
      [Date.UTC(2026, 10, 20, 14, 59, 59, 999), "2026-11-20", 47],
      [Date.UTC(2026, 10, 20, 15, 0, 0), "2026-11-21", 0],
    ];
    for (const [ms, date, bin] of cases) {
      expect(dayDate(jstDay(ms)), String(ms)).toBe(date);
      expect(timeBin(ms), String(ms)).toBe(bin);
    }
  });
});

describe("phaseFit", () => {
  it("follows the formulas of 当てはめ step 3", () => {
    // Two days with the same phase: a quarter of the cycle.
    expect(phaseFit(120_000, 2, 2, [0, 2], [0, 2])).toEqual({ rDays: 1, rEvents: 1, spread: 0, phase: 30_000 });
    // Two days whose unit vectors add up to (1, 0): R_days = 0.5.
    const fit = phaseFit(120_000, 2, 3, [1, 0], [1, 0]);
    expect(fit.rDays).toBe(0.5);
    expect(fit.rEvents).toBeCloseTo(1 / 3);
    expect(fit.spread).toBeCloseTo((120_000 / (2 * Math.PI)) * Math.sqrt(-2 * Math.log(0.5)), 6);
    expect(fit.phase).toBe(0);
    // Directions below the x axis are taken from 0 to 2π; a phase that rounds to the cycle is 0.
    expect(phaseFit(120_000, 1, 1, [0, -1], [0, -1]).phase).toBe(90_000);
    expect(phaseFit(120_000, 1, 1, [1, -1e-9], [1, -1e-9]).phase).toBe(0);
  });
});

describe("fitting", () => {
  it("publishes a fixed-time signal seen on seven weekdays", async () => {
    expect(dayDate(dayNumber(TODAY) - PLAN_KEEP_DAYS)).toBe(KEEP_FROM);
    await storeDays(ID, FIXED, WEEKDAYS);
    const result = await runTimingJob(env.DB, NOW);
    expect(result).toMatchObject({ fitted: 1, planRows: 1, expired: 0, backlog: false, waiting: 0 });
    expect(await plans()).toEqual([
      {
        slot: 1,
        day_type: 0,
        bin: 14,
        cycle_ms: 120_000,
        // 120 s divides a day and 9 hours, so both references give the same spread: epoch.
        reference: "epoch",
        phase_ms: 37_400,
        spread_ms: 0,
        green_ms: 24_000,
        blink_ms: 6_000,
        last_day: "2026-11-20",
        updated_day: TODAY,
      },
    ]);
  });

  it("finds the phase of a jittery signal", async () => {
    const jitter = [-200, 0, 200, 100, -100, 0, 300, -300];
    await storeDays(ID, FIXED, WEEKDAYS, {
      jitterOf: (k) => jitter[k % jitter.length]!,
      cycleOf: (k) => 120_000 + jitter[(k + 3) % jitter.length]!,
    });
    await runTimingJob(env.DB, NOW);
    const [plan] = await plans();
    expect(plan).toMatchObject({ cycle_ms: 120_000, reference: "epoch" });
    expect(Math.abs((plan!.phase_ms as number) - 37_400)).toBeLessThanOrEqual(100);
    expect(plan!.spread_ms as number).toBeLessThan(300);
  });

  it("chooses midnight for a signal timed from midnight whose cycle does not divide a day", async () => {
    // 86,400 s is not a multiple of 97 s, so the epoch phase moves by 70 s from day to day.
    const signal: Signal = { cycle: 97_000, phase: 12_300, reference: "midnight" };
    await storeDays(ID, signal, WEEKDAYS);
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toMatchObject([
      { cycle_ms: 97_000, reference: "midnight", phase_ms: 12_300, spread_ms: 0 },
    ]);
  });

  it("chooses epoch for a signal timed from the epoch whose cycle does not divide a day", async () => {
    const signal: Signal = { cycle: 97_000, phase: 41_100, reference: "epoch" };
    await storeDays(ID, signal, WEEKDAYS);
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toMatchObject([{ cycle_ms: 97_000, reference: "epoch", phase_ms: 41_100, spread_ms: 0 }]);
  });

  it("computes T from t, ms and half the gap, with 500 for an unknown ms", async () => {
    const signal: Signal = { ...FIXED, phase: 37_500 };
    for (const [i, date] of WEEKDAYS.entries()) {
      const changes = signalChanges(signal, date, { holds: false }).map((x) => {
        const at = x.t * 1000 + x.ms! - x.gap! / 2;
        // Odd days: no ms and no gap; T is t + 0.5 s. Even days: ms 700, gap 400.
        return i % 2 === 1
          ? { ...x, t: Math.floor(at / 1000), ms: null, gap: null }
          : { ...x, t: Math.floor((at + 200) / 1000), ms: (at + 200) % 1000, gap: 400 };
      });
      expect(changes.every((x) => x.ms === null || x.ms === 700)).toBe(true);
      await store(ID, changes);
    }
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toMatchObject([{ phase_ms: 37_500, spread_ms: 0 }]);
  });

  it("places each green start by its own JST time, at day and bin boundaries", async () => {
    // Fridays 23:59:59.9 JST (day type 0, bin 47) and the following Saturdays 00:00:00.0 JST
    // (day type 1, bin 0): the same UTC day, but different JST days.
    const fridays = ["2026-10-09", "2026-10-16", "2026-10-23", "2026-10-30", "2026-11-06", "2026-11-13", "2026-11-20"];
    for (const friday of fridays) {
      const late = jst(friday, 23, 59, 59, 900);
      const midnight = late + 100;
      await store(ID, [
        change(late, "Red", "Green", { cycle: 120_000 }),
        change(midnight, "Red", "Green", { slot: 2, cycle: 120_000 }),
      ]);
      expect(utcDay(late)).toBe(utcDay(midnight));
      expect([dayType(jstDay(late)), timeBin(late), dayType(jstDay(midnight)), timeBin(midnight)]).toEqual([0, 47, 1, 0]);
    }
    await runTimingJob(env.DB, NOW);
    const late = jst("2026-11-20", 23, 59, 59, 900);
    expect(await plans()).toMatchObject([
      { slot: 1, day_type: 0, bin: 47, phase_ms: late % 120_000, last_day: "2026-11-20" },
      { slot: 2, day_type: 1, bin: 0, phase_ms: (late + 100) % 120_000, last_day: "2026-11-21" },
    ]);
  });

  it("fits each slot, day type and bin on its own", async () => {
    await storeDays(ID, FIXED, WEEKDAYS);
    await storeDays(ID, { ...FIXED, phase: 1_000 }, WEEKDAYS, { slot: 3 });
    await storeDays(ID, { ...FIXED, phase: 5_000 }, WEEKDAYS, { fromMinute: 7 * 60 + 30, toMinute: 8 * 60 });
    const saturdays = ["2026-10-10", "2026-10-17", "2026-10-24", "2026-10-31", "2026-11-07", "2026-11-14", "2026-11-21"];
    await storeDays(ID, { ...FIXED, phase: 9_000 }, saturdays);
    await storeDays(ID, { ...FIXED, phase: 13_000 }, saturdays.map((date) => dayDate(dayNumber(date) + 1)));
    const result = await runTimingJob(env.DB, NOW);
    expect(result).toMatchObject({ fitted: 1, planRows: 5 });
    expect((await plans()).map((plan) => [plan.slot, plan.day_type, plan.bin, plan.phase_ms])).toEqual([
      [1, 0, 14, 37_400],
      [1, 0, 15, 5_000],
      [1, 1, 14, 9_000],
      [1, 2, 14, 13_000],
      [3, 0, 14, 1_000],
    ]);
  });

  it("ignores holidays and other excluded days", async () => {
    // Monday 2026-11-23 is Labour Thanksgiving Day: with it, seven dates but six days count.
    await storeDays(ID, FIXED, ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20", "2026-11-23", "2026-11-24"]);
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toEqual([]);
    await storeDays(ID, FIXED, ["2026-11-25"]);
    await runTimingJob(env.DB, NOW + 86_400_000);
    expect(await plans()).toMatchObject([{ last_day: "2026-11-25" }]);
  });

  it("publishes nothing for a signal whose cycle varies", async () => {
    await storeDays(ID, FIXED, WEEKDAYS, { cycleOf: (k) => (k % 2 === 0 ? 90_000 : 120_000) });
    expect(await runTimingJob(env.DB, NOW)).toMatchObject({ fitted: 1, planRows: 0 });
    expect(await plans()).toEqual([]);
  });

  it("takes the lower middle cycle, and needs 80% of the cycles within a second of it", async () => {
    // Half 120 s and half 121 s: the lower middle, 120 s, fits the 120 s signal; 121 s would not.
    // Eight days of 15 green starts, so that the count is even.
    let i = 0;
    await storeDays(ID, FIXED, [...WEEKDAYS, "2026-11-24"], { cycleOf: () => (i++ % 2 === 0 ? 120_000 : 121_000) });
    expect(i % 2).toBe(0);
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toMatchObject([{ cycle_ms: 120_000, spread_ms: 0 }]);

    // 4 of 5 cycles within a second of the median: published. 3 of 5: not.
    for (const [cycles, published] of [
      [[119_400, 120_000, 120_400, 121_000, 150_000], true],
      [[119_000, 120_000, 120_400, 121_600, 150_000], false],
    ] as const) {
      await resetDatabase();
      let n = 0;
      await storeDays(ID, FIXED, WEEKDAYS, { cycleOf: () => cycles[n++] ?? null });
      await runTimingJob(env.DB, NOW);
      expect((await plans()).length, String(cycles)).toBe(published ? 1 : 0);
    }
  });

  it("needs at least 3 cycles, between 30 and 300 seconds", async () => {
    const slow: Signal = { cycle: 300_000, phase: 37_400, reference: "epoch" };
    const cases: [Signal, (k: number) => number | null, number][] = [
      [FIXED, (k) => (k < 2 ? 120_000 : null), 0],
      [FIXED, (k) => (k < 3 ? 120_000 : null), 1],
      // With a cycle field of 30 s, the green starts of the 120 s signal still line up.
      [FIXED, () => 29_400, 0],
      [FIXED, () => 29_500, 1], // rounds to 30 s
      [slow, () => 300_400, 1],
      [slow, () => 300_500, 0], // rounds to 301 s
    ];
    for (const [signal, cycleOf, count] of cases) {
      await resetDatabase();
      let k = 0;
      await storeDays(ID, signal, WEEKDAYS, { cycleOf: () => cycleOf(k++) });
      await runTimingJob(env.DB, NOW);
      expect((await plans()).length, cycleOf.toString()).toBe(count);
    }
  });

  it("needs green starts on 7 days", async () => {
    await storeDays(ID, FIXED, WEEKDAYS.slice(0, 6));
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toEqual([]);
    // The seventh day, received before the next run.
    await storeDays(ID, FIXED, WEEKDAYS.slice(6));
    await runTimingJob(env.DB, NOW + 86_400_000);
    expect(await plans()).toHaveLength(1);
  });

  it("needs green starts in 2 report rows", async () => {
    await store(ID, WEEKDAYS.flatMap((date) => signalChanges(FIXED, date)));
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toEqual([]);
  });

  it("publishes nothing when the daily phases spread over more than 3 s", async () => {
    // Seven days whose phases are d before, at and after the signal's, as -d, 0, d, -d, 0, d, 0:
    // R_days = (3 + 4 cos(2π d / 120)) / 7. d = 5 s: spread about 3.79 s.
    const spreadOf = (d: number) =>
      (120_000 / (2 * Math.PI)) * Math.sqrt(-2 * Math.log((3 + 4 * Math.cos((2 * Math.PI * d) / 120)) / 7));
    const store7 = async (d: number) => {
      for (const [i, date] of WEEKDAYS.entries()) {
        const offset = i === 6 ? 0 : ((i % 3) - 1) * d;
        await storeDays(ID, { ...FIXED, phase: FIXED.phase + offset }, [date]);
      }
    };
    expect(spreadOf(5)).toBeGreaterThan(3_700);
    await store7(5_000);
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toEqual([]);
    // d = 2 s: about 1.51 s.
    await resetDatabase();
    await store7(2_000);
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toMatchObject([{ phase_ms: FIXED.phase }]);
    const spread = (await plans())[0]!.spread_ms as number;
    expect(Math.abs(spread - spreadOf(2))).toBeLessThanOrEqual(1);
  });

  it("publishes nothing when the green starts scatter within the days", async () => {
    // Every day the same two phases half a cycle apart: the days agree, the events do not.
    for (const date of WEEKDAYS) {
      await store(ID, [
        ...signalChanges(FIXED, date, { holds: false, toMinute: 7 * 60 + 10 }),
        ...signalChanges({ ...FIXED, phase: FIXED.phase + 60_000 }, date, {
          holds: false,
          fromMinute: 7 * 60 + 10,
          toMinute: 7 * 60 + 14,
        }),
      ]);
    }
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toEqual([]);
  });

  it("takes the lower middle held of Green and of BlinkGreen in the cell, or null", async () => {
    await storeDays(ID, FIXED, WEEKDAYS, { holds: false });
    const at = jst("2026-11-18", 7, 20);
    await store(ID, [
      ...[26_000, 20_000, 24_000, 22_000].map((held, i) => change(at + i * 1000, "Green", "BlinkGreen", { held })),
      ...[7_000, 5_000].map((held, i) => change(at + i * 1000, "BlinkGreen", "Red", { held })),
      change(at, "Green", "BlinkGreen", { held: null }),
      // Another bin (07:30) and another slot do not count.
      change(jst("2026-11-18", 7, 30), "Green", "BlinkGreen", { held: 1_000 }),
      change(at, "Green", "BlinkGreen", { slot: 2, held: 1_000 }),
    ]);
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toMatchObject([{ green_ms: 22_000, blink_ms: 5_000 }]);

    await resetDatabase();
    await storeDays(ID, FIXED, WEEKDAYS, { holds: false });
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toMatchObject([{ green_ms: null, blink_ms: null }]);
  });

  it("uses no row received on the day of the run", async () => {
    await storeDays(ID, FIXED, WEEKDAYS.slice(0, 6));
    // Data of Friday morning (JST) received this afternoon (UTC), the day of the run.
    await store(ID, signalChanges(FIXED, "2026-11-27"), { received: NOW - 3_600_000 });
    expect(await runTimingJob(env.DB, NOW)).toMatchObject({ fitted: 1, planRows: 0 });
    expect(await plans()).toEqual([]);
    // The next day it is used.
    await runTimingJob(env.DB, NOW + 86_400_000);
    expect(await plans()).toMatchObject([{ last_day: "2026-11-27", updated_day: "2026-11-28" }]);
  });

  it("uses only rows whose device clock was right (clock_ok = 1)", async () => {
    await storeDays(ID, FIXED, WEEKDAYS.slice(0, 6));
    await store(ID, signalChanges(FIXED, WEEKDAYS[6]!), { clockOk: false });
    expect(await rows("SELECT clock_ok, count(*) AS n FROM reports GROUP BY clock_ok ORDER BY clock_ok")).toEqual([
      { clock_ok: 0, n: 1 },
      { clock_ok: 1, n: 6 },
    ]);
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toEqual([]);
  });

  it("uses no rows of schema 1 to 3", async () => {
    await storeDays(ID, FIXED, WEEKDAYS.slice(0, 6));
    const changes = signalChanges(FIXED, WEEKDAYS[6]!);
    await storeReport(
      env.DB,
      {
        schema: 3,
        client: null,
        intersections: [
          {
            id: ID,
            serviceUUIDs: [],
            emitters: 0,
            emitterInfo: [],
            observations: [],
            transitions: changes.map(({ ms: _ms, ...x }) => x),
            steps: [],
            packets: [],
            coverage: [],
            labels: [],
          },
        ],
      },
      changes[0]!.t * 1000,
    );
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toEqual([]);
  });

  it("replaces an intersection's plans, removing cells that no longer pass", async () => {
    const stale = `INSERT INTO timing_plans VALUES (?1, 2, 1, 30, 90000, 'epoch', 0, 0, NULL, NULL, '2026-11-21', '2026-11-22')`;
    await env.DB.prepare(stale).bind(ID).run();
    await env.DB.prepare(stale).bind("0000FFFF").run();
    await storeDays(ID, FIXED, WEEKDAYS);
    const result = await runTimingJob(env.DB, NOW);
    expect(result).toMatchObject({ fitted: 1, planRows: 1 });
    // One stale row deleted, one inserted.
    expect(result.planRowsWritten).toBe(2);
    expect(await plans()).toMatchObject([{ slot: 1, day_type: 0, bin: 14 }]);
    // Other intersections keep theirs.
    expect(await plans("0000FFFF")).toHaveLength(1);

    // A later fit that publishes nothing removes the plan.
    await resetDatabase();
    await env.DB.prepare(stale).bind(ID).run();
    await storeDays(ID, FIXED, WEEKDAYS.slice(0, 6));
    await runTimingJob(env.DB, NOW);
    expect(await plans()).toEqual([]);
  });
});

describe("timing_places", () => {
  it("keeps the latest name and position by observation time, from the rows the fit uses", async () => {
    const t = Math.floor(jst("2026-11-18", 7, 10) / 1000);
    const observation = (type: number, at: number, tail: string): Schema3Observation => ({
      ...OBSERVATION,
      t: at,
      raw: raw(ID, type, tail),
    });
    // Received first, but observed later.
    await store(ID, signalChanges(FIXED, "2026-11-19"), {
      observations: [observation(0, t + 86_400, "AA"), observation(1, t, "B1")],
    });
    await store(ID, signalChanges(FIXED, "2026-11-18"), {
      observations: [observation(0, t + 10, "A1"), observation(1, t + 20, "B2"), observation(2, t + 99_999, "C0")],
      received: Date.UTC(2026, 10, 20, 0, 0),
    });
    // Neither a row received today nor one with a wrong clock counts.
    await store(ID, [], { observations: [observation(0, t + 200_000, "EE")], received: NOW - 60_000 });
    await store(ID, [], { observations: [observation(1, t + 200_000, "FF")], clockOk: false });

    await runTimingJob(env.DB, NOW);
    expect(await rows("SELECT * FROM timing_places")).toEqual([
      { intersection_id: ID, name_raw: raw(ID, 0, "AA"), position_raw: raw(ID, 1, "B2"), updated_day: TODAY },
    ]);
    expect(raw(ID, 0).length).toBe(4 + 48);
    expect(raw(ID, 1).length).toBe(4 + 36);
  });

  it("keeps an earlier name and position when the rows carry none", async () => {
    await env.DB.prepare("INSERT INTO timing_places VALUES (?1, 'CE01OLDNAME', 'CE01OLDPOSITION', '2026-11-01')").bind(ID).run();
    await storeDays(ID, FIXED, WEEKDAYS.slice(0, 1));
    await runTimingJob(env.DB, NOW);
    expect(await rows("SELECT * FROM timing_places")).toEqual([
      { intersection_id: ID, name_raw: "CE01OLDNAME", position_raw: "CE01OLDPOSITION", updated_day: TODAY },
    ]);
  });

  it("writes NULL for a never-fitted intersection without names or positions", async () => {
    await storeDays(ID, FIXED, WEEKDAYS.slice(0, 1));
    await runTimingJob(env.DB, NOW);
    expect(await rows("SELECT * FROM timing_places")).toEqual([
      { intersection_id: ID, name_raw: null, position_raw: null, updated_day: TODAY },
    ]);
  });
});

/** An intersection ID for test number `i`. */
const idOf = (i: number) => (0x50000000 + i).toString(16).toUpperCase();

/** Each place's updated_day, by intersection. */
async function days(): Promise<Record<string, unknown>> {
  return Object.fromEntries(
    (await rows("SELECT intersection_id, updated_day FROM timing_places")).map((row) => [row.intersection_id, row.updated_day]),
  );
}

describe("the timing cron", () => {
  it("fits intersections with new rows first, never-fitted ones first, then those fitted longest ago", async () => {
    // One row each, received on 2026-11-11.
    const ids = ["A0000000", "B0000000", "C0000000", "D0000000", "E0000000", "G0000000"];
    for (const id of ids) await storeDays(id, FIXED, WEEKDAYS.slice(0, 1));
    expect(await rows("SELECT DISTINCT received_day FROM reports")).toEqual([{ received_day: "2026-11-11" }]);
    // G has a row received after its last fit (on 2026-11-20, which used the rows received before).
    await store("G0000000", signalChanges(FIXED, WEEKDAYS[6]!), { received: Date.UTC(2026, 10, 20, 12) });
    const fitted = env.DB.prepare("INSERT INTO timing_places VALUES (?1, NULL, NULL, ?2)");
    await env.DB.batch([
      fitted.bind("A0000000", "2026-11-25"),
      fitted.bind("B0000000", "2026-11-12"),
      fitted.bind("D0000000", TODAY),
      fitted.bind("G0000000", "2026-11-20"),
    ]);
    // Only rows with clock_ok = 0, or received today: not candidates.
    await store("10000000", signalChanges(FIXED, WEEKDAYS[0]!), { clockOk: false });
    await store("20000000", signalChanges(FIXED, WEEKDAYS[0]!), { received: NOW - 60_000 });

    // New rows: C and E (never fitted), then G. Then B and A, fitted longest ago first. D was fitted today.
    const limits = { ...DEFAULT_TIMING_LIMITS, maxIntersections: 2 };
    expect(await runTimingJob(env.DB, NOW, limits)).toMatchObject({ fitted: 2, waiting: 1, backlog: false });
    expect(await days()).toEqual({
      A0000000: "2026-11-25",
      B0000000: "2026-11-12",
      C0000000: TODAY,
      D0000000: TODAY,
      E0000000: TODAY,
      G0000000: "2026-11-20",
    });
    expect(await runTimingJob(env.DB, NOW, limits)).toMatchObject({ fitted: 2, waiting: 0 });
    expect(await days()).toMatchObject({ A0000000: "2026-11-25", B0000000: TODAY, G0000000: TODAY });
    expect(await runTimingJob(env.DB, NOW, limits)).toMatchObject({ fitted: 1, waiting: 0 });
    expect((await days()).A0000000).toBe(TODAY);
    // Nothing is left for today.
    expect(await runTimingJob(env.DB, NOW, limits)).toMatchObject({ fitted: 0, waiting: 0 });
    expect(Object.keys(await days())).not.toContain("10000000");
    expect(Object.keys(await days())).not.toContain("20000000");
  });

  it("fits only intersections with a row received in the last 21 days", async () => {
    // Received on 2026-11-05 and 2026-11-06 (UTC): KEEP_FROM is 2026-11-06.
    await store("A0000000", signalChanges(FIXED, "2026-11-05"), { received: Date.UTC(2026, 10, 5, 12) });
    await store("B0000000", signalChanges(FIXED, "2026-11-06"), { received: Date.UTC(2026, 10, 6, 12) });
    expect(await runTimingJob(env.DB, NOW)).toMatchObject({ fitted: 1 });
    expect(Object.keys(await days())).toEqual(["B0000000"]);
  });

  it("starts no new intersection once it wrote more plan rows than the limit, and flags a backlog", async () => {
    for (const i of [0, 1, 2]) await storeDays(idOf(i), FIXED, WEEKDAYS);
    const limits = { ...DEFAULT_TIMING_LIMITS, maxPlanRowsWritten: 1 };
    // Each intersection writes one plan row: the limit is passed after the second.
    expect(await runTimingJob(env.DB, NOW, limits)).toMatchObject({ fitted: 2, planRowsWritten: 2, backlog: true, waiting: 1 });
    expect(await rows("SELECT timing_backlog FROM service_state")).toEqual([{ timing_backlog: 1 }]);
    expect(await runTimingJob(env.DB, NOW, limits)).toMatchObject({ fitted: 1, backlog: false, waiting: 0 });
    expect(await rows("SELECT count(*) AS n FROM timing_plans")).toEqual([{ n: 3 }]);
  });

  it("uses at most 28 D1 queries per run, within the Free plan's 50 per invocation, and counts its writes", async () => {
    expect(maxTimingQueries()).toBe(28);
    for (let i = 0; i < DEFAULT_TIMING_LIMITS.maxIntersections + 2; i++) await storeDays(idOf(i), FIXED, WEEKDAYS);
    const { db, meter } = meteredDatabase();
    const result = await runTimingJob(db, NOW);
    expect(result).toMatchObject({ fitted: 12, planRows: 12, waiting: 2, backlog: false });
    expect(meter.queries).toBe(maxTimingQueries());
    expect(meter.queries).toBeLessThanOrEqual(50);
    expect(result.rowsWritten).toBe(meter.rowsWritten);
    // 12 plan rows, 12 places, one snapshot chunk and the record.
    expect(result.rowsWritten).toBe(12 + 12 + 1 + 1);

    // The next day: two never-fitted intersections and ten of the others are refitted (one plan row
    // deleted and one inserted each), the old chunk is replaced.
    const next = meteredDatabase();
    const again = await runTimingJob(next.db, NOW + 86_400_000);
    expect(again).toMatchObject({ fitted: 12, planRows: 12, planRowsWritten: 2 + 10 * 2, waiting: 0 });
    expect(again.rowsWritten).toBe(next.meter.rowsWritten);
    expect(again.rowsWritten).toBe(22 + 12 + 2 + 1);
  });

  it("records what the last successful run did in service_state, without touching the daily cron's columns", async () => {
    await env.DB.prepare(
      `INSERT INTO service_state (id, cron_last_success, folded_reports, backlog, deleted_keys, rows_written, database_bytes)
       VALUES (1, '2026-11-27T18:00:00Z', 5, 0, 1, 99, 12345)`,
    ).run();
    await storeDays(ID, FIXED, WEEKDAYS);
    await storeDays("0000FFFF", FIXED, WEEKDAYS.slice(0, 1));
    await env.DB.prepare(`INSERT INTO timing_plans VALUES ('ABCDEF01', 1, 0, 14, 90000, 'epoch', 0, 0, NULL, NULL, '2026-11-05', '2026-11-06')`).run();
    const result = await runTimingJob(env.DB, NOW);
    expect(await rows("SELECT * FROM service_state")).toEqual([
      {
        id: 1,
        cron_last_success: "2026-11-27T18:00:00Z",
        folded_reports: 5,
        backlog: 0,
        deleted_keys: 1,
        rows_written: 99,
        database_bytes: 12345,
        timing_last_success: "2026-11-27T18:30:00Z",
        timing_fitted: 2,
        timing_plan_rows: 1,
        timing_expired: 1,
        timing_backlog: 0,
        timing_waiting: 0,
        timing_rows_written: result.rowsWritten,
      },
    ]);
  });

  it("creates the service_state row when the daily cron has not recorded one yet", async () => {
    await runTimingJob(env.DB, NOW);
    expect(await rows("SELECT * FROM service_state")).toEqual([
      {
        id: 1,
        cron_last_success: "",
        folded_reports: 0,
        backlog: 0,
        deleted_keys: 0,
        rows_written: 0,
        database_bytes: null,
        timing_last_success: "2026-11-27T18:30:00Z",
        timing_fitted: 0,
        timing_plan_rows: 0,
        timing_expired: 0,
        timing_backlog: 0,
        timing_waiting: 0,
        // The empty snapshot chunk and the record.
        timing_rows_written: 2,
      },
    ]);
    // The daily cron then overwrites its own columns.
    await runCron("0 18 * * *", NOW + 86_400_000 - 1_800_000);
    expect(await rows("SELECT cron_last_success, timing_last_success FROM service_state")).toEqual([
      { cron_last_success: "2026-11-28T18:00:00Z", timing_last_success: "2026-11-27T18:30:00Z" },
    ]);
  });

  it("fits the other intersections when one fails, rebuilds the snapshot, then ends with its error and records nothing", async () => {
    await runTimingJob(env.DB, NOW - 86_400_000);
    for (const id of ["A0000000", "B0000000", "C0000000"]) await storeDays(id, FIXED, WEEKDAYS);
    const failing = new Proxy(env.DB, {
      get(target, property) {
        if (property === "prepare") {
          return (query: string) => {
            const statement = target.prepare(query);
            if (!query.includes("WITH changes")) return statement;
            return new Proxy(statement, {
              get(inner, name) {
                if (name === "bind") {
                  return (...values: unknown[]) => {
                    if (values[0] === "B0000000") throw new Error("D1 limit");
                    return inner.bind(...values);
                  };
                }
                const value: unknown = Reflect.get(inner, name, inner);
                return typeof value === "function" ? value.bind(inner) : value;
              },
            });
          };
        }
        const value: unknown = Reflect.get(target, property, target);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    await expect(runTimingJob(failing, NOW)).rejects.toThrow("D1 limit");
    expect(await rows("SELECT intersection_id FROM timing_plans ORDER BY intersection_id")).toEqual([
      { intersection_id: "A0000000" },
      { intersection_id: "C0000000" },
    ]);
    expect(await snapshotIds()).toEqual(["A0000000", "C0000000"]);
    expect(await rows("SELECT timing_last_success FROM service_state")).toEqual([
      { timing_last_success: "2026-11-26T18:30:00Z" },
    ]);
    // The failed intersection is still never fitted, so the next run takes it first.
    expect(await runTimingJob(env.DB, NOW)).toMatchObject({ fitted: 1 });
    expect(await plans("B0000000")).toHaveLength(1);
  });
});

/** The intersection IDs in the snapshot, in chunk order. */
async function snapshotIds(): Promise<string[]> {
  const chunks = await rows("SELECT body FROM timing_snapshot ORDER BY chunk");
  return chunks.flatMap((row) => (JSON.parse(`[${row.body as string}]`) as { id: string }[]).map((item) => item.id));
}

/** Inserts a plan of intersection `id` whose last day is `lastDay`. */
async function insertPlan(id: string, lastDay: string, bin = 14): Promise<void> {
  await env.DB.prepare(`INSERT INTO timing_plans VALUES (?1, 1, 0, ?2, 120000, 'epoch', 37400, 0, NULL, NULL, ?3, ?3)`)
    .bind(id, bin, lastDay)
    .run();
}

describe("retention", () => {
  it("deletes the plans whose last day is more than 21 days before the run's UTC day", async () => {
    await insertPlan("A0000000", "2026-11-05");
    await insertPlan("A0000000", KEEP_FROM, 15);
    await insertPlan("B0000000", "2026-10-01");
    const result = await runTimingJob(env.DB, NOW);
    expect(result).toMatchObject({ expired: 2, planRowsWritten: 2, backlog: false });
    expect(await rows("SELECT intersection_id, bin, last_day FROM timing_plans")).toEqual([
      { intersection_id: "A0000000", bin: 15, last_day: KEEP_FROM },
    ]);
    expect(await snapshotIds()).toEqual(["A0000000"]);
    // The next day the other one goes too.
    expect(await runTimingJob(env.DB, NOW + 86_400_000)).toMatchObject({ expired: 1 });
    expect(await rows("SELECT count(*) AS n FROM timing_plans")).toEqual([{ n: 0 }]);
    expect(await rows("SELECT chunk, body, generated FROM timing_snapshot")).toEqual([
      { chunk: 0, body: "", generated: "2026-11-28" },
    ]);
  });

  it("counts expired rows against the plan row limit, before fitting", async () => {
    for (const bin of [1, 2, 3]) await insertPlan("A0000000", "2026-11-01", bin);
    await storeDays(ID, FIXED, WEEKDAYS);
    const limits = { ...DEFAULT_TIMING_LIMITS, maxPlanRowsWritten: 2 };
    // Two expired rows reach the limit without passing it: one intersection is still fitted.
    expect(await runTimingJob(env.DB, NOW, limits)).toMatchObject({ expired: 2, fitted: 1, planRowsWritten: 3, backlog: true });
    expect(await runTimingJob(env.DB, NOW, limits)).toMatchObject({ expired: 1, fitted: 0, backlog: false });
    expect(await rows("SELECT intersection_id FROM timing_plans")).toEqual([{ intersection_id: ID }]);
  });

  it("does not store cells whose last day is more than 21 days ago", async () => {
    // Seven weekdays in October in bin 14 (07:00), and seven in November in bin 15 (07:30).
    const october = ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-13", "2026-10-14"];
    await storeDays(ID, FIXED, october);
    await storeDays(ID, FIXED, WEEKDAYS, { fromMinute: 7 * 60 + 30, toMinute: 8 * 60 });
    expect(await runTimingJob(env.DB, NOW)).toMatchObject({ fitted: 1, planRows: 1, expired: 0 });
    expect(await plans()).toMatchObject([{ bin: 15, last_day: "2026-11-20" }]);

    // Fitted on 2026-10-20, the October cell is stored, and deleted 21 days after its last day,
    // together with the place: the intersection has no row received since then either.
    await resetDatabase();
    await storeDays(ID, FIXED, october);
    await runTimingJob(env.DB, Date.UTC(2026, 9, 20, 18, 30));
    expect(await plans()).toMatchObject([{ bin: 14, last_day: "2026-10-14", updated_day: "2026-10-20" }]);
    expect(await runTimingJob(env.DB, Date.UTC(2026, 10, 4, 18, 30))).toMatchObject({ expired: 0, fitted: 0 });
    expect(await plans()).toHaveLength(1);
    expect(await runTimingJob(env.DB, Date.UTC(2026, 10, 5, 18, 30))).toMatchObject({ expired: 1, fitted: 0 });
    expect(await plans()).toEqual([]);
    expect(await rows("SELECT count(*) AS n FROM timing_places")).toEqual([{ n: 0 }]);
  });

  it("deletes the places of intersections without plans and without rows received in the last 21 days", async () => {
    const place = env.DB.prepare("INSERT INTO timing_places VALUES (?1, 'CE01NAME', NULL, '2026-11-01')");
    await env.DB.batch(["A0000000", "B0000000", "C0000000", "D0000000"].map((id) => place.bind(id)));
    // A: no plans, no rows. B: a plan. C: no plans, a row received on KEEP_FROM. D: no plans, a row
    // received the day before KEEP_FROM.
    await insertPlan("B0000000", "2026-11-20");
    await store("C0000000", [], { received: Date.UTC(2026, 10, 6, 23), observations: [] });
    await store("D0000000", [], { received: Date.UTC(2026, 10, 5, 23), observations: [] });
    await runTimingJob(env.DB, NOW);
    expect(Object.keys(await days()).sort()).toEqual(["B0000000", "C0000000"]);
    // Within the limit per run.
    await resetDatabase();
    await env.DB.batch([0, 1, 2].map((i) => place.bind(idOf(i))));
    await runTimingJob(env.DB, NOW, { ...DEFAULT_TIMING_LIMITS, maxPlaceDeletes: 2 });
    expect(Object.keys(await days())).toHaveLength(1);
    await runTimingJob(env.DB, NOW);
    expect(Object.keys(await days())).toHaveLength(0);
  });
});

describe("timing_snapshot", () => {
  it("holds the response's intersections, without days, reports or dates, and the day it was built", async () => {
    await env.DB.prepare("INSERT INTO timing_places VALUES (?1, 'CE01AA', 'CE01BB', '2026-11-20')").bind(ID).run();
    await insertPlan(ID, "2026-11-20", 15);
    await insertPlan(ID, "2026-11-19", 14);
    await insertPlan("0000FFFF", "2026-11-18", 47);
    await runTimingJob(env.DB, NOW);
    const plan = (bin: number) => ({
      slot: 1, dayType: 0, bin, cycle: 120_000, reference: "epoch", phase: 37_400, spread: 0, green: null, blink: null,
    });
    expect(await rows("SELECT * FROM timing_snapshot")).toEqual([
      {
        chunk: 0,
        body: [
          JSON.stringify({ id: "0000FFFF", name: null, position: null, plans: [plan(47)] }),
          JSON.stringify({ id: ID, name: "CE01AA", position: "CE01BB", plans: [plan(14), plan(15)] }),
        ].join(","),
        generated: TODAY,
      },
    ]);
  });

  it("cuts the intersections into chunks at every multiple of the chunk size", async () => {
    const ids = Array.from({ length: 7 }, (_, i) => idOf(i));
    for (const id of ids) await insertPlan(id, "2026-11-20");
    await runTimingJob(env.DB, NOW);
    const [whole] = await rows("SELECT body FROM timing_snapshot");
    const items = (JSON.parse(`[${whole!.body as string}]`) as unknown[]).map((item) => JSON.stringify(item));
    expect(items).toHaveLength(7);
    const size = items[0]!.length + 1;
    // A chunk every 3.5 objects (with their commas): objects 0 to 3 start before 3.5 x size, objects
    // 4 to 6 before 7 x size.
    await runTimingJob(env.DB, NOW + 86_400_000, { ...DEFAULT_TIMING_LIMITS, snapshotChunkBytes: Math.floor(3.5 * size) });
    const chunks = await rows("SELECT chunk, body, generated FROM timing_snapshot ORDER BY chunk");
    expect(chunks).toEqual([
      { chunk: 0, body: items.slice(0, 4).join(","), generated: "2026-11-28" },
      { chunk: 1, body: items.slice(4, 7).join(","), generated: "2026-11-28" },
    ]);
    expect(await snapshotIds()).toEqual(ids);
  });
});

describe("scheduled() dispatch", () => {
  it("runs only the fitting for the 18:30 trigger", async () => {
    expect(TIMING_CRON).toBe("30 18 * * *");
    await storeDays(ID, FIXED, WEEKDAYS);
    // A row past retention, which the daily jobs would fold.
    await store("0000FFFF", signalChanges(FIXED, "2026-08-04"), { received: Date.UTC(2026, 7, 4) });
    await runCron("30 18 * * *");
    expect(await plans()).toHaveLength(1);
    expect(await rows("SELECT count(*) AS n FROM reports")).toEqual([{ n: 8 }]);
    expect(await rows("SELECT count(*) AS n FROM transition_counts")).toEqual([{ n: 0 }]);
    expect(await snapshotIds()).toEqual([ID]);
    expect(await rows("SELECT cron_last_success, timing_last_success FROM service_state")).toEqual([
      { cron_last_success: "", timing_last_success: "2026-11-27T18:30:00Z" },
    ]);
  });

  it("runs only the daily jobs for the 18:00 trigger", async () => {
    await storeDays(ID, FIXED, WEEKDAYS);
    await store("0000FFFF", signalChanges(FIXED, "2026-08-04"), { received: Date.UTC(2026, 7, 4) });
    await runCron("0 18 * * *", NOW - 1_800_000);
    expect(await rows("SELECT count(*) AS n FROM timing_plans")).toEqual([{ n: 0 }]);
    expect(await rows("SELECT count(*) AS n FROM timing_places")).toEqual([{ n: 0 }]);
    expect(await rows("SELECT count(*) AS n FROM timing_snapshot")).toEqual([{ n: 0 }]);
    expect(await rows("SELECT count(*) AS n FROM reports")).toEqual([{ n: 7 }]);
    expect(await rows("SELECT timing_last_success FROM service_state")).toEqual([{ timing_last_success: null }]);
  });

  it("rejects an unknown trigger and does nothing", async () => {
    await storeDays(ID, FIXED, WEEKDAYS);
    await store("0000FFFF", signalChanges(FIXED, "2026-08-04"), { received: Date.UTC(2026, 7, 4) });
    for (const cron of ["", "0 0 * * *"]) await expect(runCron(cron)).rejects.toThrow("unknown cron trigger");
    expect(await rows("SELECT count(*) AS n FROM timing_plans")).toEqual([{ n: 0 }]);
    expect(await rows("SELECT count(*) AS n FROM reports")).toEqual([{ n: 8 }]);
    expect(await rows("SELECT count(*) AS n FROM service_state")).toEqual([{ n: 0 }]);
  });
});
