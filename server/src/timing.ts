// SPDX-License-Identifier: Apache-2.0

// Timing plans (docs/timing-estimation.md): the JST calendar, the fitting cron (30 18 * * * UTC =
// 03:30 JST) and the data that GET /v1/plans serves.
//
// The cron fits the cells (intersection x slot x day type x half-hour bin) of up to 12 intersections
// per run from report rows with clock_ok = 1 received before the run's UTC day, never-fitted
// intersections first, then those fitted longest ago. The heavy part runs in D1: one query per
// intersection extracts its transitions with json_each, places them in the calendar, finds each
// cell's cycle and sums the unit vectors of the green starts' phases per JST day. The Worker only
// turns those sums into plans, so it parses no payload and stays far below the Free plan's 10 ms
// of CPU per invocation. Each intersection's plans are then replaced in one batch (one
// transaction), together with its name and position (timing_places). A failure of one intersection
// does not stop the others; like the daily cron (src/cron.ts), a run with a failure records
// nothing in service_state and ends with that failure's error.
//
// Free plan limits per run: D1 queries 1 (candidates) + 2 per intersection (the fit query and one
// batch) x 12 + 1 (record) = 26 of 50. No new intersection is started once the run has written more
// than 4,000 plan rows (deleted and inserted); one intersection has at most 6 x 3 x 48 = 864 cells,
// so a run writes at most 4,000 + 2 x 864 plan rows, 12 timing_places rows and the record: 5,741
// rows. Its reads go through the partial index reports_for_timing (migration 0005).

import { utcDay } from "./storage";

const DAY_MS = 86_400_000;
const JST_OFFSET_MS = 9 * 3_600_000;
const BIN_MS = 30 * 60_000;

/** The cron expression of the fitting cron, as declared in cloudflare.config.ts and wrangler.jsonc. */
export const TIMING_CRON = "30 18 * * *";

// ---------------------------------------------------------------------------------------------
// Calendar ("暦：日の種類と時間帯")

/**
 * National holidays and substitute holidays, from the Cabinet Office's syukujitsu.csv. Update
 * every February with the next year (and the app's list too), and move CALENDAR_LAST_DAY.
 */
export const HOLIDAYS: readonly string[] = [
  // 2026
  "2026-01-01", "2026-01-12", "2026-02-11", "2026-02-23", "2026-03-20", "2026-04-29", "2026-05-03",
  "2026-05-04", "2026-05-05", "2026-05-06", "2026-07-20", "2026-08-11", "2026-09-21", "2026-09-22",
  "2026-09-23", "2026-10-12", "2026-11-03", "2026-11-23",
  // 2027
  "2027-01-01", "2027-01-11", "2027-02-11", "2027-02-23", "2027-03-21", "2027-03-22", "2027-04-29",
  "2027-05-03", "2027-05-04", "2027-05-05", "2027-07-19", "2027-08-11", "2027-09-20", "2027-09-23",
  "2027-10-11", "2027-11-03", "2027-11-23",
];

/** The range of the holiday table; every day outside it is excluded. */
export const CALENDAR_FIRST_DAY = "2026-01-01";
export const CALENDAR_LAST_DAY = "2027-12-31";

/** 0 = Monday to Friday, 1 = Saturday, 2 = Sunday. */
export type DayType = 0 | 1 | 2;

/** Days since 1970-01-01 of a YYYY-MM-DD date. */
export function dayNumber(date: string): number {
  return Date.UTC(Number(date.slice(0, 4)), Number(date.slice(5, 7)) - 1, Number(date.slice(8, 10))) / DAY_MS;
}

/** YYYY-MM-DD of a day number. */
export function dayDate(day: number): string {
  return new Date(day * DAY_MS).toISOString().slice(0, 10);
}

/** The JST date (as a day number) of Unix ms `ms`. */
export function jstDay(ms: number): number {
  return Math.floor((ms + JST_OFFSET_MS) / DAY_MS);
}

/** The half-hour bin (0-47) of Unix ms `ms`: minutes since midnight JST divided by 30. */
export function timeBin(ms: number): number {
  const msOfDay = (((ms + JST_OFFSET_MS) % DAY_MS) + DAY_MS) % DAY_MS;
  return Math.floor(msOfDay / BIN_MS);
}

/** The day type of a JST date. 1970-01-01 (day 0) was a Thursday. */
export function dayType(day: number): DayType {
  const weekday = (((day + 4) % 7) + 7) % 7; // 0 = Sunday
  return weekday === 0 ? 2 : weekday === 6 ? 1 : 0;
}

const FIRST_DAY = dayNumber(CALENDAR_FIRST_DAY);
const LAST_DAY = dayNumber(CALENDAR_LAST_DAY);
const HOLIDAY_DAYS = new Set(HOLIDAYS.map(dayNumber));

/** True for holidays, December 29 to January 3, and days outside the holiday table. */
export function isExcludedDay(day: number): boolean {
  if (day < FIRST_DAY || day > LAST_DAY || HOLIDAY_DAYS.has(day)) return true;
  const date = new Date(day * DAY_MS);
  const month = date.getUTCMonth() + 1;
  const dayOfMonth = date.getUTCDate();
  return (month === 12 && dayOfMonth >= 29) || (month === 1 && dayOfMonth <= 3);
}

// ---------------------------------------------------------------------------------------------
// Fitting ("当てはめ")

/** One published cell, with the field names of GET /v1/plans. */
export interface Plan {
  slot: number;
  dayType: DayType;
  bin: number;
  /** ms, a whole number of seconds. */
  cycle: number;
  reference: "epoch" | "midnight";
  /** ms after the reference, 0 <= phase < cycle. */
  phase: number;
  /** ms. */
  spread: number;
  green: number | null;
  blink: number | null;
  days: number;
  reports: number;
  /** YYYY-MM-DD (JST). */
  lastDay: string;
}

/** What FIT_SQL returns for one cell whose cycle passed (step 1 of "セル"). */
export interface CellSums {
  slot: number;
  day_type: DayType;
  bin: number;
  /** Cms. */
  cycle: number;
  /** JST dates with a green start. */
  days: number;
  /** Green starts. */
  events: number;
  /** Report rows with a green start. */
  reports: number;
  /** Day number of the last JST date with a green start. */
  last_day: number;
  /** Sums of e^{iθ_k} over all green starts, epoch reference. */
  ex: number;
  ey: number;
  /** Sums over the days of e^{iψ_d}, the unit vector of each day's sum, epoch reference. */
  edx: number;
  edy: number;
  /** The same for the midnight reference. */
  mx: number;
  my: number;
  mdx: number;
  mdy: number;
  green: number | null;
  blink: number | null;
}

/** The circular statistics of one reference (step 3 of "セル"). */
export interface PhaseFit {
  rDays: number;
  rEvents: number;
  /** ms, not rounded. */
  spread: number;
  /** ms, 0 <= phase < cycle. */
  phase: number;
}

const TWO_PI = 2 * Math.PI;

export function phaseFit(
  cycle: number,
  days: number,
  events: number,
  eventSum: [number, number],
  daySum: [number, number],
): PhaseFit {
  const rDays = Math.hypot(...daySum) / days;
  const rEvents = Math.hypot(...eventSum) / events;
  // rDays can exceed 1 by a rounding error.
  const spread = rDays >= 1 ? 0 : (cycle / TWO_PI) * Math.sqrt(-2 * Math.log(rDays));
  let angle = Math.atan2(daySum[1], daySum[0]);
  if (angle < 0) angle += TWO_PI;
  const phase = (Math.round((cycle * angle) / TWO_PI) % cycle) + 0;
  return { rDays, rEvents, spread, phase };
}

/** Publication thresholds (step 4 of "セル"). */
const MIN_DAYS = 7;
const MIN_REPORTS = 2;
const MIN_R_EVENTS = 0.9;
const MAX_SPREAD_MS = 3000;

/**
 * Chooses the reference and decides whether the cell is published (steps 3 to 6). The reference
 * with the smaller spread wins, epoch on a tie. Spreads are compared at the whole milliseconds in
 * which they are published: when the cycle divides a day, both references give the same spread up
 * to rounding errors, and those must not decide.
 */
export function planOf(cell: CellSums): Plan | null {
  const epoch = phaseFit(cell.cycle, cell.days, cell.events, [cell.ex, cell.ey], [cell.edx, cell.edy]);
  const midnight = phaseFit(cell.cycle, cell.days, cell.events, [cell.mx, cell.my], [cell.mdx, cell.mdy]);
  const useMidnight = Math.round(midnight.spread) < Math.round(epoch.spread);
  const fit = useMidnight ? midnight : epoch;
  if (
    cell.days < MIN_DAYS ||
    cell.reports < MIN_REPORTS ||
    !(fit.rEvents >= MIN_R_EVENTS) ||
    !(fit.spread <= MAX_SPREAD_MS)
  ) {
    return null;
  }
  return {
    slot: cell.slot,
    dayType: cell.day_type,
    bin: cell.bin,
    cycle: cell.cycle,
    reference: useMidnight ? "midnight" : "epoch",
    phase: fit.phase,
    spread: Math.round(fit.spread),
    green: cell.green,
    blink: cell.blink,
    days: cell.days,
    reports: cell.reports,
    lastDay: dayDate(cell.last_day),
  };
}

/**
 * The cells of intersection ?1 from its rows with clock_ok = 1 received before ?2 (YYYY-MM-DD,
 * UTC), one row per cell whose cycle passes step 1, with the sums planOf needs. No phase is
 * computed for the other cells. T (`at`) = t x 1000 + ms - gap / 2 (gap is a multiple of 100, so
 * the division is exact), with 500 for an unknown ms and 0 for an unknown gap; the JST date and
 * bin come from each transition's own T, and transitions on excluded days are dropped (the
 * excluded dates come from isExcludedDay). Medians take the lower middle value for an even count.
 * A day whose phases cancel out exactly counts as phase 0, as atan2(0, 0) does.
 */
function buildFitSql(): string {
  const excluded: number[] = [];
  for (let day = FIRST_DAY; day <= LAST_DAY; day++) if (isExcludedDay(day)) excluded.push(day);
  return `
WITH changes AS (
  SELECT r.id AS row_id,
         json_extract(x.value, '$.slot') AS slot,
         json_extract(x.value, '$.from') AS from_state,
         json_extract(x.value, '$.held') AS held,
         json_extract(x.value, '$.cycle') AS cycle,
         json_extract(x.value, '$.t') * 1000 + IFNULL(json_extract(x.value, '$.ms'), 500)
           - IFNULL(json_extract(x.value, '$.gap'), 0) / 2 AS at
    FROM reports AS r, json_each(r.payload, '$.transitions') AS x
   WHERE r.intersection_id = ?1 AND r.clock_ok = 1 AND r.received_day < ?2
     AND (json_extract(x.value, '$.from') IN ('Green', 'BlinkGreen')
          OR (json_extract(x.value, '$.from') = 'Red' AND json_extract(x.value, '$.to') = 'Green'))
), dated AS (
  SELECT *, (at + ${JST_OFFSET_MS}) / ${DAY_MS} AS day, (at + ${JST_OFFSET_MS}) % ${DAY_MS} AS ms_of_day
    FROM changes
), cells AS (
  SELECT row_id, slot, from_state, held, cycle, at, day, ms_of_day,
         CASE (day + 4) % 7 WHEN 0 THEN 2 WHEN 6 THEN 1 ELSE 0 END AS day_type,
         ms_of_day / ${BIN_MS} AS bin
    FROM dated
   WHERE day BETWEEN ${FIRST_DAY} AND ${LAST_DAY}
     AND day NOT IN (${excluded.join(", ")})
), starts AS (
  SELECT * FROM cells WHERE from_state = 'Red'
), cycles AS (
  SELECT slot, day_type, bin, (cycle + 500) / 1000 AS seconds,
         row_number() OVER (PARTITION BY slot, day_type, bin ORDER BY cycle) AS k,
         count(*) OVER (PARTITION BY slot, day_type, bin) AS n
    FROM starts
   WHERE cycle IS NOT NULL
), periods AS (
  SELECT m.slot, m.day_type, m.bin, m.seconds * 1000 AS cycle
    FROM cycles AS m
   WHERE m.k = (m.n + 1) / 2 AND m.n >= 3 AND m.seconds BETWEEN 30 AND 300
     AND 5 * (SELECT count(*) FROM cycles AS c
               WHERE c.slot = m.slot AND c.day_type = m.day_type AND c.bin = m.bin
                 AND c.seconds BETWEEN m.seconds - 1 AND m.seconds + 1) >= 4 * m.n
), daily AS (
  SELECT s.slot, s.day_type, s.bin, s.day, p.cycle, count(*) AS n,
         sum(cos(2 * pi() * (s.at % p.cycle) / p.cycle)) AS ex,
         sum(sin(2 * pi() * (s.at % p.cycle) / p.cycle)) AS ey,
         sum(cos(2 * pi() * (s.ms_of_day % p.cycle) / p.cycle)) AS mx,
         sum(sin(2 * pi() * (s.ms_of_day % p.cycle) / p.cycle)) AS my
    FROM starts AS s JOIN periods AS p USING (slot, day_type, bin)
   GROUP BY s.slot, s.day_type, s.bin, s.day
), fitted AS (
  SELECT slot, day_type, bin, cycle, count(*) AS days, sum(n) AS events, max(day) AS last_day,
         sum(ex) AS ex, sum(ey) AS ey,
         sum(IFNULL(ex / sqrt(ex * ex + ey * ey), 1.0)) AS edx,
         sum(IFNULL(ey / sqrt(ex * ex + ey * ey), 0.0)) AS edy,
         sum(mx) AS mx, sum(my) AS my,
         sum(IFNULL(mx / sqrt(mx * mx + my * my), 1.0)) AS mdx,
         sum(IFNULL(my / sqrt(mx * mx + my * my), 0.0)) AS mdy
    FROM daily
   GROUP BY slot, day_type, bin
), counted AS (
  SELECT slot, day_type, bin, count(DISTINCT row_id) AS reports
    FROM starts
   GROUP BY slot, day_type, bin
), holds AS (
  SELECT slot, day_type, bin, from_state, held,
         row_number() OVER (PARTITION BY slot, day_type, bin, from_state ORDER BY held) AS k,
         count(*) OVER (PARTITION BY slot, day_type, bin, from_state) AS n
    FROM cells
   WHERE from_state IN ('Green', 'BlinkGreen') AND held IS NOT NULL
), medians AS (
  SELECT slot, day_type, bin,
         max(CASE WHEN from_state = 'Green' THEN held END) AS green,
         max(CASE WHEN from_state = 'BlinkGreen' THEN held END) AS blink
    FROM holds
   WHERE k = (n + 1) / 2
   GROUP BY slot, day_type, bin
)
SELECT f.slot, f.day_type, f.bin, f.cycle, f.days, f.events, c.reports, f.last_day,
       f.ex, f.ey, f.edx, f.edy, f.mx, f.my, f.mdx, f.mdy, m.green, m.blink
  FROM fitted AS f
  JOIN counted AS c USING (slot, day_type, bin)
  LEFT JOIN medians AS m USING (slot, day_type, bin)
 ORDER BY f.slot, f.day_type, f.bin`;
}

let fitSql: string | undefined;

/** The cells of one intersection that passed step 1, from the rows received before `today`. */
export async function cellSums(db: D1Database, intersectionId: string, today: string): Promise<CellSums[]> {
  fitSql ??= buildFitSql();
  return (await db.prepare(fitSql).bind(intersectionId, today).all<CellSums>()).results;
}

const DELETE_PLANS_SQL = "DELETE FROM timing_plans WHERE intersection_id = ?1";

// ?2 is a JSON array of Plan objects.
const INSERT_PLANS_SQL = `
INSERT INTO timing_plans
       (intersection_id, slot, day_type, bin, cycle_ms, reference, phase_ms, spread_ms, green_ms, blink_ms,
        days, reports, last_day, updated_day)
SELECT ?1,
       json_extract(p.value, '$.slot'), json_extract(p.value, '$.dayType'), json_extract(p.value, '$.bin'),
       json_extract(p.value, '$.cycle'), json_extract(p.value, '$.reference'), json_extract(p.value, '$.phase'),
       json_extract(p.value, '$.spread'), json_extract(p.value, '$.green'), json_extract(p.value, '$.blink'),
       json_extract(p.value, '$.days'), json_extract(p.value, '$.reports'), json_extract(p.value, '$.lastDay'),
       ?3
  FROM json_each(?2) AS p`;

// The latest name (message type 0) and position (type 1) by observation time among the rows the
// fit used: payload byte 2, i.e. hex characters 9-10 (1-based) of raw. A type that none of them
// carries keeps the value of an earlier fit, since the plans outlive the rows too.
const UPSERT_PLACE_SQL = `
WITH packets AS (
  SELECT substr(json_extract(o.value, '$.raw'), 9, 2) AS type,
         json_extract(o.value, '$.t') AS t,
         json_extract(o.value, '$.raw') AS raw
    FROM reports AS r, json_each(r.payload, '$.observations') AS o
   WHERE r.intersection_id = ?1 AND r.clock_ok = 1 AND r.received_day < ?2
     AND substr(json_extract(o.value, '$.raw'), 9, 2) IN ('00', '01')
)
INSERT INTO timing_places (intersection_id, name_raw, position_raw, updated_day)
SELECT ?1,
       (SELECT raw FROM packets WHERE type = '00' ORDER BY t DESC, raw DESC LIMIT 1),
       (SELECT raw FROM packets WHERE type = '01' ORDER BY t DESC, raw DESC LIMIT 1),
       ?2
 WHERE true
    ON CONFLICT (intersection_id) DO UPDATE
   SET name_raw = IFNULL(excluded.name_raw, name_raw),
       position_raw = IFNULL(excluded.position_raw, position_raw),
       updated_day = excluded.updated_day`;

export interface FitResult {
  plans: Plan[];
  /** Rows deleted from and inserted into timing_plans, as D1 reports them. */
  planRowsWritten: number;
  /** All rows the batch wrote. */
  rowsWritten: number;
}

/** Fits one intersection and replaces its plans and place in one batch (transaction). */
export async function fitIntersection(db: D1Database, intersectionId: string, today: string): Promise<FitResult> {
  const plans: Plan[] = [];
  for (const cell of await cellSums(db, intersectionId, today)) {
    const plan = planOf(cell);
    if (plan !== null) plans.push(plan);
  }
  const written = await db.batch([
    db.prepare(DELETE_PLANS_SQL).bind(intersectionId),
    db.prepare(INSERT_PLANS_SQL).bind(intersectionId, JSON.stringify(plans), today),
    db.prepare(UPSERT_PLACE_SQL).bind(intersectionId, today),
  ]);
  const rows = written.map((item) => item.meta.rows_written ?? 0);
  return { plans, planRowsWritten: rows[0]! + rows[1]!, rowsWritten: rows.reduce((sum, n) => sum + n, 0) };
}

// ---------------------------------------------------------------------------------------------
// The cron

export interface TimingLimits {
  /** Intersections per run. */
  maxIntersections: number;
  /** No new intersection is started once the run has written more plan rows than this. */
  maxPlanRowsWritten: number;
}

export const DEFAULT_TIMING_LIMITS: TimingLimits = { maxIntersections: 12, maxPlanRowsWritten: 4000 };

/** D1 queries one run makes at most (the Free plan allows 50 per invocation). */
export function maxTimingQueries(limits: TimingLimits = DEFAULT_TIMING_LIMITS): number {
  return 1 + 2 * limits.maxIntersections + 1;
}

// Intersections with rows to fit that were not fitted today: never fitted first, then those fitted
// longest ago. `waiting` counts all of them, also those beyond the limit. Reads only the partial
// index reports_for_timing (and timing_places).
const CANDIDATES_SQL = `
SELECT c.intersection_id AS id, count(*) OVER () AS waiting
  FROM (SELECT DISTINCT intersection_id FROM reports WHERE clock_ok = 1 AND received_day < ?1) AS c
  LEFT JOIN timing_places AS p ON p.intersection_id = c.intersection_id
 WHERE p.updated_day IS NULL OR p.updated_day < ?1
 ORDER BY p.updated_day IS NOT NULL, p.updated_day, c.intersection_id
 LIMIT ?2`;

// Only the timing columns. Before the daily cron's first record the row does not exist; it is
// then created with an empty cron_last_success and zero counts, which that cron overwrites.
const RECORD_SQL = `
INSERT INTO service_state
       (id, cron_last_success, folded_reports, backlog, deleted_keys, rows_written, database_bytes,
        timing_last_success, timing_fitted, timing_plan_rows, timing_backlog, timing_waiting, timing_rows_written)
VALUES (1, '', 0, 0, 0, 0, NULL, ?1, ?2, ?3, ?4, ?5, ?6)
    ON CONFLICT (id) DO UPDATE
   SET timing_last_success = excluded.timing_last_success,
       timing_fitted = excluded.timing_fitted,
       timing_plan_rows = excluded.timing_plan_rows,
       timing_backlog = excluded.timing_backlog,
       timing_waiting = excluded.timing_waiting,
       timing_rows_written = excluded.timing_rows_written`;

export interface TimingResult {
  /** Intersections fitted. */
  fitted: number;
  /** Plan rows stored. */
  planRows: number;
  /** Rows deleted from and inserted into timing_plans. */
  planRowsWritten: number;
  /** True when the run stopped at maxPlanRowsWritten with intersections left. */
  backlog: boolean;
  /** Intersections with rows to fit that this run did not fit (beyond the limits, or failed). */
  waiting: number;
  /** Every row the run wrote, the record included. */
  rowsWritten: number;
}

/** Runs the fitting cron as of `nowMs`: rows received before its UTC day are used. */
export async function runTimingJob(
  db: D1Database,
  nowMs: number,
  limits: TimingLimits = DEFAULT_TIMING_LIMITS,
): Promise<TimingResult> {
  const today = utcDay(nowMs);
  const { results: candidates } = await db
    .prepare(CANDIDATES_SQL)
    .bind(today, limits.maxIntersections)
    .all<{ id: string; waiting: number }>();
  const result: TimingResult = { fitted: 0, planRows: 0, planRowsWritten: 0, backlog: false, waiting: 0, rowsWritten: 0 };
  const errors: unknown[] = [];
  for (const { id } of candidates) {
    if (result.planRowsWritten > limits.maxPlanRowsWritten) {
      result.backlog = true;
      break;
    }
    try {
      const fit = await fitIntersection(db, id, today);
      result.fitted += 1;
      result.planRows += fit.plans.length;
      result.planRowsWritten += fit.planRowsWritten;
      result.rowsWritten += fit.rowsWritten;
    } catch (error) {
      errors.push(error);
    }
  }
  result.waiting = (candidates[0]?.waiting ?? 0) - result.fitted;
  if (errors.length > 0) throw errors[0];

  // The record below writes one more row.
  result.rowsWritten += 1;
  await db
    .prepare(RECORD_SQL)
    .bind(
      new Date(nowMs).toISOString().slice(0, 19) + "Z",
      result.fitted,
      result.planRows,
      result.backlog ? 1 : 0,
      result.waiting,
      result.rowsWritten,
    )
    .run();
  return result;
}

// ---------------------------------------------------------------------------------------------
// GET /v1/plans

// The response's "intersections" array, built by D1 so that the Worker does not handle every plan
// row (the Free plan allows 10 ms of CPU per request). Only intersections with at least one plan;
// by id, and plans by slot, dayType and bin. ?1 is a JSON array of IDs, or NULL for all.
const PLANS_SQL = `
SELECT json_group_array(json(item) ORDER BY id) AS intersections
  FROM (SELECT p.intersection_id AS id,
               json_object(
                 'id', p.intersection_id,
                 'name', s.name_raw,
                 'position', s.position_raw,
                 'plans', json_group_array(json_object(
                   'slot', p.slot, 'dayType', p.day_type, 'bin', p.bin,
                   'cycle', p.cycle_ms, 'reference', p.reference, 'phase', p.phase_ms, 'spread', p.spread_ms,
                   'green', p.green_ms, 'blink', p.blink_ms,
                   'days', p.days, 'reports', p.reports, 'lastDay', p.last_day
                 ) ORDER BY p.slot, p.day_type, p.bin)
               ) AS item
          FROM timing_plans AS p
          LEFT JOIN timing_places AS s ON s.intersection_id = p.intersection_id
         WHERE ?1 IS NULL OR p.intersection_id IN (SELECT value FROM json_each(?1))
         GROUP BY p.intersection_id)`;

/** The body of GET /v1/plans for `ids` (null: every intersection), as JSON text. One read. */
export async function plansBody(db: D1Database, ids: string[] | null): Promise<string> {
  const row = await db
    .prepare(PLANS_SQL)
    .bind(ids === null ? null : JSON.stringify(ids))
    .first<{ intersections: string }>();
  return `{"intersections":${row?.intersections ?? "[]"}}`;
}
