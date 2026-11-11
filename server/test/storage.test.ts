// SPDX-License-Identifier: Apache-2.0

// The daily storage budget counts rowStorageBytes() per report row. Check that estimate against
// what the local D1 actually uses (size_after counts pages in use), so that the README's bound on
// the database size holds.

import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { validateReport, type Report } from "../src/report";
import { aggregateItems, DEFAULT_FOLD_LIMITS, reportPayloads, rowStorageBytes, storeReport } from "../src/storage";
import { resetDatabase } from "./helpers/context";

beforeEach(async () => {
  await resetDatabase();
});

async function databaseSize(): Promise<number> {
  return (await env.DB.prepare("SELECT 1").all()).meta.size_after;
}

/** Stores `rows` report rows with `observations` observations each; returns bytes per row. */
async function measure(observations: number, rows: number): Promise<{ payload: number; perRow: number }> {
  const before = await databaseSize();
  const t = 1_794_290_000;
  let payload = 0;
  for (let stored = 0; stored < rows; stored += 50) {
    const report: Report = {
      schema: 1,
      client: "aoshingo-ios/0.1.0",
      intersections: Array.from({ length: 50 }, (_, i) => {
        const id = (0x60000000 + stored + i).toString(16).toUpperCase();
        return {
          id,
          serviceUUIDs: [],
          emitters: 1,
          observations: Array.from({ length: observations }, (_, k) => ({
            t: t + k,
            raw: `CE010000022A0000${id}311384848484`,
            rssi: -70,
            bearing: 3,
            heading: null,
          })),
          transitions: [],
        };
      }),
    };
    payload = reportPayloads(report)[0]!.length;
    await storeReport(env.DB, report, Date.UTC(2026, 10, 1 + (stored % 7)));
  }
  return { payload, perRow: ((await databaseSize()) - before) / rows };
}

describe("rowStorageBytes", () => {
  // Payloads of about 170 B, 1 KB, 2.1 KB (a leaf page per row), 5.5 KB, 6.2 KB (an overflow page
  // and a leaf page per row) and 40 KB. A full sweep from 150 B to 60 KB stayed at or below 0.999.
  it.each([1, 9, 20, 54, 61, 400])("is at least the space a row with %i observations takes", async (observations) => {
    const { payload, perRow } = await measure(observations, observations > 100 ? 100 : 300);
    expect(perRow).toBeGreaterThan(payload);
    expect(perRow / rowStorageBytes(payload)).toBeLessThan(1.03);
  });

  it("follows SQLite's page layout", () => {
    // Small rows: payload plus 500 bytes.
    expect(rowStorageBytes(150)).toBe(650);
    // Up to a page, twice the record, as a row larger than half a page gets a leaf page to itself.
    expect(rowStorageBytes(1000)).toBe(2 * 1100 + 100);
    expect(rowStorageBytes(2100)).toBe(4200);
    // One overflow page plus a leaf part larger than half a page.
    expect(rowStorageBytes(6200)).toBe(4096 + 4200);
    // Large rows: whole overflow pages and the leaf part.
    expect(rowStorageBytes(40_000)).toBe(9 * 4096 + 4200);
  });
});

describe("aggregateItems", () => {
  const now = 1_794_290_000;
  const raw = "CE010000022A00001234ABCD311384848484";

  /** A validated report with one intersection of the given sizes. */
  function sized(schema: 1 | 2, counts: { observations: number; transitions: number; steps?: number; labels?: number }) {
    const intersection: Record<string, unknown> = {
      id: "1234ABCD",
      serviceUUIDs: [],
      emitters: 0,
      observations: Array(counts.observations).fill({ t: now, raw }),
      transitions: Array(counts.transitions).fill({ t: now, slot: 1, from: "Red", to: "Green" }),
    };
    if (schema === 2) {
      intersection.steps = Array(counts.steps ?? 0).fill({ t: now, slot: 1, state: "Red", from: 2, to: 1 });
      intersection.labels = Array(counts.labels ?? 0).fill({ t: now, kind: "button" });
    }
    const result = validateReport({ schema, intersections: [intersection] }, now);
    if (!result.ok) throw new Error(result.reason);
    return result.report;
  }

  it("counts each schema 1 observation and transition once", () => {
    expect(aggregateItems(sized(1, { observations: 3, transitions: 2 }))).toEqual([5]);
  });

  it("counts what each schema 2 item can reach", () => {
    // Observation: observation_counts and range_counts. Transition: transition_counts and
    // duration_counts twice. Step and label: one row each.
    expect(aggregateItems(sized(2, { observations: 3, transitions: 2, steps: 4, labels: 5 }))).toEqual([
      2 * 3 + 3 * 2 + 4 + 5,
    ]);
    expect(aggregateItems(sized(2, { observations: 0, transitions: 0, steps: 1 }))).toEqual([1]);
  });

  it("keeps the largest row within one chunk", () => {
    const [largest] = aggregateItems(sized(2, { observations: 600, transitions: 300, steps: 600, labels: 20 }));
    expect(largest).toBe(2720);
    expect(largest).toBeLessThanOrEqual(DEFAULT_FOLD_LIMITS.chunkItems);
  });
});
