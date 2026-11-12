#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline signal-timing fit for Aoshingo (docs/timing-estimation.md, stage 0).

Reads app recordings (JSON Lines of RecordedAdvertisement) and/or a JSON export of the D1
`reports` table, derives each intersection's green-start events, and fits the cycle and phase
per cell (intersection x slot x day type x 30-minute bin) with exactly the rules of the spec.

Python 3.10+, standard library only.
"""

from __future__ import annotations

import argparse
import cmath
import datetime as dt
import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

# ---------------------------------------------------------------------------
# Calendar (spec: 暦)
# ---------------------------------------------------------------------------

JST = dt.timezone(dt.timedelta(hours=9))
JST_OFFSET_MS = 9 * 3600 * 1000
DAY_MS = 86_400_000
BIN_MS = 30 * 60 * 1000

HOLIDAYS: frozenset[tuple[int, int, int]] = frozenset(
    [(2026, m, d) for m, d in [
        (1, 1), (1, 12), (2, 11), (2, 23), (3, 20), (4, 29), (5, 3), (5, 4), (5, 5), (5, 6),
        (7, 20), (8, 11), (9, 21), (9, 22), (9, 23), (10, 12), (11, 3), (11, 23),
    ]]
    + [(2027, m, d) for m, d in [
        (1, 1), (1, 11), (2, 11), (2, 23), (3, 21), (3, 22), (4, 29), (5, 3), (5, 4), (5, 5),
        (7, 19), (8, 11), (9, 20), (9, 23), (10, 11), (11, 3), (11, 23),
    ]]
)
FIRST_HOLIDAY_YEAR = 2026
LAST_HOLIDAY_YEAR = 2027

# Same limits as the spec.
MIN_DAYS = 7
MIN_REPORTS = 2
MIN_CYCLE_EVENTS = 3
CYCLE_SHARE_MIN = 0.8
CYCLE_MIN_S = 30
CYCLE_MAX_S = 300
R_EVENTS_MIN = 0.9
SPREAD_MAX_MS = 3000

# Same as FieldCollector.maxTransitionGap and Bucketing.maximumDuration.
MAX_RECEPTION_GAP_S = 5.0
MAX_DURATION_MS = 3_600_000


@dataclass(frozen=True)
class JstTime:
    """A Unix time in milliseconds seen as a Japan Standard Time calendar position."""

    date: dt.date
    day_start_ms: float  # Unix ms of 00:00 JST of that date
    bin: int

    @staticmethod
    def of(unix_ms: float) -> "JstTime":
        jst_ms = unix_ms + JST_OFFSET_MS
        day_index = math.floor(jst_ms / DAY_MS)
        in_day = jst_ms - day_index * DAY_MS
        date = dt.date(1970, 1, 1) + dt.timedelta(days=day_index)
        return JstTime(date, day_index * DAY_MS - JST_OFFSET_MS, min(47, int(in_day // BIN_MS)))


def is_excluded_day(date: dt.date) -> bool:
    """Holidays, 29 Dec - 3 Jan, and days outside the years of the holiday table."""
    if not FIRST_HOLIDAY_YEAR <= date.year <= LAST_HOLIDAY_YEAR:
        return True
    if (date.year, date.month, date.day) in HOLIDAYS:
        return True
    return (date.month == 12 and date.day >= 29) or (date.month == 1 and date.day <= 3)


def day_type(date: dt.date) -> int:
    """0 = weekday, 1 = Saturday, 2 = Sunday."""
    weekday = date.weekday()
    return 0 if weekday < 5 else weekday - 4


def format_bin(bin_index: int) -> str:
    start = bin_index * 30
    end = start + 30
    return f"{start // 60:02d}:{start % 60:02d}-{end // 60:02d}:{end % 60:02d}"


# ---------------------------------------------------------------------------
# PICS parsing (PICSParser) and transition derivation (FieldCollector)
# ---------------------------------------------------------------------------

SIGNAL_STATES = {0: "NoSignal", 1: "Red", 2: "BlinkGreen", 3: "Green", 4: "None"}
HEADER_LENGTH = 10
MAX_SIGNALS = 6
MIN_PAYLOAD_LENGTH = {0: 24, 1: 18, 2: 11}
RAW_HEX_LENGTH = range(24, 129)  # ReportContract.rawLength: hex characters, 24...128


@dataclass(frozen=True)
class SignalPacket:
    intersection_id: str
    states: tuple[str, ...]


def parse_signal_packet(manufacturer_data: str) -> SignalPacket | None:
    """Parses a Type 2 packet like PICSParser; returns None for anything else or invalid data.

    `manufacturer_data` is hex including the little-endian company id `CE01`. Packets the app
    would not upload (wrong length, other message types) are ignored, as in FieldCollector.
    """
    text = manufacturer_data.strip().upper()
    if len(text) not in RAW_HEX_LENGTH or len(text) % 2 != 0 or not text.startswith("CE01"):
        return None
    try:
        payload = bytes.fromhex(text)[2:]
    except ValueError:
        return None
    if len(payload) < HEADER_LENGTH:
        return None
    message_type = payload[2]
    if message_type != 2 or len(payload) < MIN_PAYLOAD_LENGTH[2]:
        return None
    end = min(len(payload), HEADER_LENGTH + MAX_SIGNALS)
    states = tuple(SIGNAL_STATES.get(b & 0x0F, "Unknown") for b in payload[HEADER_LENGTH:end])
    return SignalPacket(payload[6:10].hex().upper(), states)


def duration_ms(seconds: float) -> int | None:
    """Bucketing.durationMilliseconds: 0.1 s units, None when negative or over an hour."""
    if not math.isfinite(seconds) or seconds < 0 or seconds > MAX_DURATION_MS / 1000 + 1:
        return None
    value = math.floor(seconds * 10 + 0.5) * 100
    return value if value <= MAX_DURATION_MS else None


@dataclass
class _Slot:
    state: str
    entered: dict[str, float] = field(default_factory=dict)


@dataclass
class Transition:
    """One state change of one slot. `t_ms` is the precise Unix time (ms) of the first packet."""

    intersection: str
    slot: int
    from_state: str
    to_state: str
    t_ms: float
    gap: int | None
    held: int | None
    cycle: int | None


def derive_transitions(packets: Iterable[tuple[float, SignalPacket]]) -> list[Transition]:
    """Derives transitions from (unix seconds, packet) pairs in arrival order.

    Same rules as FieldCollector.recordSignals: a reception gap over 5 s (or going backwards in
    time) resets the intersection's timing; `gap` is the time since the previous signal packet
    of the intersection; `held` is the time the slot had been in `from`; `cycle` is the time since
    the slot last entered `to`. Both are only known for periods received without a pause.
    """
    timings: dict[str, tuple[list[_Slot], float]] = {}
    out: list[Transition] = []
    for t, packet in packets:
        fresh = [_Slot(state) for state in packet.states]
        previous = timings.get(packet.intersection_id)
        if previous is None:
            timings[packet.intersection_id] = (fresh, t)
            continue
        slots_before, last_at = previous
        gap = t - last_at
        if not (0 <= gap <= MAX_RECEPTION_GAP_S):
            timings[packet.intersection_id] = (fresh, t)
            continue
        slots = fresh
        for index, state in enumerate(packet.states):
            if index >= len(slots_before):
                continue
            slot = slots_before[index]
            if slot.state != state:
                held_start = slot.entered.get(slot.state)
                cycle_start = slot.entered.get(state)
                out.append(Transition(
                    intersection=packet.intersection_id,
                    slot=index + 1,
                    from_state=slot.state,
                    to_state=state,
                    t_ms=t * 1000,
                    gap=duration_ms(gap),
                    held=None if held_start is None else duration_ms(t - held_start),
                    cycle=None if cycle_start is None else duration_ms(t - cycle_start),
                ))
                slot.entered[state] = t
                slot.state = state
            slots[index] = slot
        timings[packet.intersection_id] = (slots, t)
    return out


# ---------------------------------------------------------------------------
# Events: the fit's input
# ---------------------------------------------------------------------------


@dataclass
class Event:
    """A transition with its corrected time T (Unix ms) and where it came from."""

    intersection: str
    slot: int
    from_state: str
    to_state: str
    time_ms: float
    cycle: int | None
    held: int | None
    source: str  # distinct per recording file or report row


def corrected_time_ms(t: float, ms: int | None, gap: int | None) -> float:
    """T = t * 1000 + ms - gap / 2; ms defaults to 500 and gap to 0 (spec)."""
    return t * 1000 + (500 if ms is None else ms) - (0 if gap is None else gap) / 2


def events_from_recording(path: Path) -> tuple[list[Event], int]:
    """Reads a JSON Lines recording. Returns (events, number of unreadable lines)."""
    packets: list[tuple[float, SignalPacket]] = []
    bad = 0
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
                t = float(record["t"])
                data = record["manufacturerData"]
            except (ValueError, KeyError, TypeError):
                bad += 1
                continue
            packet = parse_signal_packet(data) if isinstance(data, str) else None
            if packet is not None:
                packets.append((t, packet))
    return events_from_transitions(derive_transitions(packets), str(path)), bad


def events_from_transitions(transitions: Iterable[Transition], source: str) -> list[Event]:
    # Recordings are treated as clock_ok with a precise `t`: ms is already inside t_ms (ms = 0).
    return [
        Event(
            intersection=tr.intersection,
            slot=tr.slot,
            from_state=tr.from_state,
            to_state=tr.to_state,
            time_ms=corrected_time_ms(tr.t_ms / 1000, 0, tr.gap),
            cycle=tr.cycle,
            held=tr.held,
            source=source,
        )
        for tr in transitions
    ]


def d1_rows(document: Any) -> list[dict[str, Any]]:
    """Accepts a list of rows, {"results": [...]}, or [{"results": [...]}, ...]."""
    if isinstance(document, dict):
        if "results" in document:
            return d1_rows(document["results"])
        return [document]
    rows: list[dict[str, Any]] = []
    for item in document:
        if isinstance(item, dict) and "results" in item and "payload" not in item:
            rows.extend(d1_rows(item["results"]))
        elif isinstance(item, dict):
            rows.append(item)
    return rows


@dataclass
class ReportStats:
    rows: int = 0
    used: int = 0
    skipped_clock: int = 0
    skipped_today: int = 0
    skipped_invalid: int = 0


def _as_int(value: Any) -> int | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def events_from_reports(
    document: Any, today: str | None, stats: ReportStats, label: str = "reports"
) -> list[Event]:
    """Events from D1 `reports` rows. Uses only clock_ok = 1 rows received before `today` (UTC)."""
    events: list[Event] = []
    for row in d1_rows(document):
        stats.rows += 1
        if _as_int(row.get("clock_ok")) != 1:
            stats.skipped_clock += 1
            continue
        received_day = row.get("received_day")
        if today is not None and (not isinstance(received_day, str) or received_day >= today):
            stats.skipped_today += 1
            continue
        payload = row.get("payload")
        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except ValueError:
                payload = None
        if not isinstance(payload, dict):
            stats.skipped_invalid += 1
            continue
        intersection = row.get("intersection_id") or payload.get("id")
        if not isinstance(intersection, str):
            stats.skipped_invalid += 1
            continue
        source = f"{label}:{row.get('id', stats.rows)}"
        stats.used += 1
        for tr in payload.get("transitions") or []:
            try:
                t = tr["t"]
                slot = int(tr["slot"])
                from_state, to_state = tr["from"], tr["to"]
            except (KeyError, TypeError, ValueError):
                continue
            if not isinstance(t, (int, float)):
                continue
            events.append(Event(
                intersection=intersection,
                slot=slot,
                from_state=from_state,
                to_state=to_state,
                time_ms=corrected_time_ms(t, _as_int(tr.get("ms")), _as_int(tr.get("gap"))),
                cycle=_as_int(tr.get("cycle")),
                held=_as_int(tr.get("held")),
                source=source,
            ))
    return events


# ---------------------------------------------------------------------------
# Fit (spec: 当てはめ)
# ---------------------------------------------------------------------------


def lower_median(values: list[float]) -> float:
    ordered = sorted(values)
    return ordered[(len(ordered) - 1) // 2]


def round_half_up(value: float) -> int:
    return math.floor(value + 0.5)


@dataclass
class ReferenceFit:
    name: str
    r_days: float
    r_events: float
    spread_ms: float
    phase_ms: int
    day_phase_ms: dict[dt.date, int]


@dataclass
class Cell:
    intersection: str
    slot: int
    day_type: int
    bin: int
    starts: int = 0
    cycle_values_s: list[int] = field(default_factory=list)
    cycle_s: int | None = None
    cycle_share: float | None = None
    fits: dict[str, ReferenceFit] = field(default_factory=dict)
    chosen: str | None = None
    days: int = 0
    reports: int = 0
    green_ms: float | None = None
    blink_ms: float | None = None
    last_day: dt.date | None = None
    ok: bool = False
    reasons: list[str] = field(default_factory=list)


def _circular(angles: list[float]) -> complex:
    """Mean of unit vectors e^{i*angle}."""
    return sum(cmath.exp(1j * a) for a in angles) / len(angles)


def fit_reference(
    name: str, starts: list[tuple[float, JstTime, str]], cycle_ms: int
) -> ReferenceFit:
    by_day: dict[dt.date, list[float]] = {}
    for time_ms, jst, _source in starts:
        base = 0.0 if name == "epoch" else jst.day_start_ms
        theta = 2 * math.pi * ((time_ms - base) % cycle_ms) / cycle_ms
        by_day.setdefault(jst.date, []).append(theta)
    psi = {day: cmath.phase(_circular(angles)) for day, angles in by_day.items()}
    mean_days = _circular(list(psi.values()))
    r_days = min(1.0, abs(mean_days))
    r_events = abs(_circular([a for angles in by_day.values() for a in angles]))
    spread = math.inf if r_days == 0 else cycle_ms / (2 * math.pi) * math.sqrt(-2 * math.log(r_days)) + 0.0
    angle = cmath.phase(mean_days) % (2 * math.pi)
    phase = round_half_up(cycle_ms * angle / (2 * math.pi)) % cycle_ms
    day_phase = {
        day: round_half_up(cycle_ms * (p % (2 * math.pi)) / (2 * math.pi)) % cycle_ms
        for day, p in psi.items()
    }
    return ReferenceFit(name, r_days, min(1.0, r_events), spread, phase, day_phase)


def chosen_reference(fits: dict[str, ReferenceFit]) -> str:
    """The reference with the smaller spread rounded to whole ms (as published); epoch on a tie.

    When the cycle divides a day both references give the same spread up to rounding errors, and
    those must not decide (server/src/timing.ts, planOf). Rounds half up like the server.
    """

    def rounded(spread_ms: float) -> float:
        return round_half_up(spread_ms) if math.isfinite(spread_ms) else math.inf

    return "midnight" if rounded(fits["midnight"].spread_ms) < rounded(fits["epoch"].spread_ms) else "epoch"


def fit_cells(events: list[Event], min_days: int = MIN_DAYS, min_reports: int = MIN_REPORTS) -> list[Cell]:
    """Fits every cell. Events on excluded days are dropped first."""
    starts: dict[tuple[str, int, int, int], list[tuple[float, JstTime, str, int | None]]] = {}
    greens: dict[tuple[str, int, int, int], list[int]] = {}
    blinks: dict[tuple[str, int, int, int], list[int]] = {}
    for ev in events:
        jst = JstTime.of(ev.time_ms)
        if is_excluded_day(jst.date):
            continue
        key = (ev.intersection, ev.slot, day_type(jst.date), jst.bin)
        if ev.from_state == "Red" and ev.to_state == "Green":
            starts.setdefault(key, []).append((ev.time_ms, jst, ev.source, ev.cycle))
        if ev.held is not None:
            if ev.from_state == "Green":
                greens.setdefault(key, []).append(ev.held)
            elif ev.from_state == "BlinkGreen":
                blinks.setdefault(key, []).append(ev.held)

    cells: list[Cell] = []
    for key in sorted(starts):
        cell = Cell(*key)
        rows = starts[key]
        cell.starts = len(rows)
        cell.days = len({jst.date for _, jst, _, _ in rows})
        cell.reports = len({source for _, _, source, _ in rows})
        cell.last_day = max(jst.date for _, jst, _, _ in rows)
        if key in greens:
            cell.green_ms = lower_median(greens[key])
        if key in blinks:
            cell.blink_ms = lower_median(blinks[key])
        cell.cycle_values_s = [round_half_up(c / 1000) for _, _, _, c in rows if c is not None]

        if len(cell.cycle_values_s) < MIN_CYCLE_EVENTS:
            cell.reasons.append(f"周期のデータが {MIN_CYCLE_EVENTS} 件未満（{len(cell.cycle_values_s)} 件）")
        else:
            cell.cycle_s = int(lower_median(cell.cycle_values_s))
            near = sum(1 for c in cell.cycle_values_s if abs(c - cell.cycle_s) <= 1)
            cell.cycle_share = near / len(cell.cycle_values_s)
            if cell.cycle_share < CYCLE_SHARE_MIN:
                cell.reasons.append(
                    f"周期が定まらない（C ±1 秒以内が {cell.cycle_share:.0%}、8 割未満）"
                )
            if not CYCLE_MIN_S <= cell.cycle_s <= CYCLE_MAX_S:
                cell.reasons.append(f"周期 {cell.cycle_s} 秒が 30〜300 秒の範囲外")

        # No phase fit when the cycle itself is not established.
        if not cell.reasons and cell.cycle_s is not None:
            cycle_ms = cell.cycle_s * 1000
            plain = [(time_ms, jst, source) for time_ms, jst, source, _ in rows]
            cell.fits = {name: fit_reference(name, plain, cycle_ms) for name in ("epoch", "midnight")}
            cell.chosen = chosen_reference(cell.fits)
            chosen = cell.fits[cell.chosen]
            if cell.days < min_days:
                cell.reasons.append(f"日数が {min_days} 日未満（{cell.days} 日）")
            if cell.reports < min_reports:
                cell.reasons.append(f"報告・記録が {min_reports} 件未満（{cell.reports} 件）")
            if chosen.r_events < R_EVENTS_MIN:
                cell.reasons.append(f"R_events が 0.9 未満（{chosen.r_events:.3f}）")
            if chosen.spread_ms > SPREAD_MAX_MS:
                cell.reasons.append(f"ばらつきが 3000 ms を超える（{chosen.spread_ms:.0f} ms）")
        cell.ok = not cell.reasons
        cells.append(cell)
    return cells


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

DAY_TYPE_NAMES = {0: "平日", 1: "土", 2: "日"}


def circular_diff_ms(a: int, b: int, cycle_ms: int) -> int:
    """a - b folded into [-cycle/2, cycle/2)."""
    return (a - b + cycle_ms // 2) % cycle_ms - cycle_ms // 2


def _finite(value: float) -> float | None:
    return value if math.isfinite(value) else None


def cell_to_json(cell: Cell) -> dict[str, Any]:
    chosen = cell.fits.get(cell.chosen) if cell.chosen else None
    return {
        "intersection": cell.intersection,
        "slot": cell.slot,
        "dayType": cell.day_type,
        "bin": cell.bin,
        "binLabel": format_bin(cell.bin),
        "starts": cell.starts,
        "cycleMs": None if cell.cycle_s is None else cell.cycle_s * 1000,
        "cycleShare": cell.cycle_share,
        "reference": cell.chosen,
        "phaseMs": chosen.phase_ms if chosen else None,
        "spreadMs": _finite(chosen.spread_ms) if chosen else None,
        "rEvents": chosen.r_events if chosen else None,
        "references": {
            name: {
                "rDays": fit.r_days,
                "rEvents": fit.r_events,
                "spreadMs": _finite(fit.spread_ms),
                "phaseMs": fit.phase_ms,
                "dayPhaseMs": {day.isoformat(): p for day, p in sorted(fit.day_phase_ms.items())},
            }
            for name, fit in cell.fits.items()
        },
        "days": cell.days,
        "reports": cell.reports,
        "greenMs": cell.green_ms,
        "blinkMs": cell.blink_ms,
        "lastDay": cell.last_day.isoformat() if cell.last_day else None,
        "verdict": "OK" if cell.ok else "NG",
        "reasons": cell.reasons,
    }


def _num(value: float | None, spec: str = ".0f", unit: str = "") -> str:
    if value is None or value == math.inf:
        return "-"
    return f"{value:{spec}}{unit}"


def format_table(cells: list[Cell], by_day: bool = False) -> str:
    headers = [
        "intersection", "slot", "day", "bin", "C(s)", "±1s", "R_ev",
        "epoch R_d/spread", "midnight R_d/spread", "ref", "phase(s)", "days", "reports",
        "green/blink(s)", "verdict",
    ]
    rows: list[list[str]] = []
    for c in cells:
        chosen = c.fits.get(c.chosen) if c.chosen else None

        def rd(name: str) -> str:
            fit = c.fits.get(name)
            return "-" if fit is None else f"{fit.r_days:.3f}/{_num(fit.spread_ms / 1000, '.2f', 's')}"

        verdict = "OK" if c.ok else "NG: " + "、".join(c.reasons)
        rows.append([
            c.intersection, str(c.slot), DAY_TYPE_NAMES[c.day_type], format_bin(c.bin),
            _num(c.cycle_s, ".0f"), _num(None if c.cycle_share is None else c.cycle_share * 100, ".0f", "%"),
            _num(chosen.r_events if chosen else None, ".3f"),
            rd("epoch"), rd("midnight"), c.chosen or "-",
            _num(chosen.phase_ms / 1000 if chosen else None, ".1f"),
            str(c.days), str(c.reports),
            f"{_num(None if c.green_ms is None else c.green_ms / 1000, '.1f')}/"
            f"{_num(None if c.blink_ms is None else c.blink_ms / 1000, '.1f')}",
            verdict,
        ])
    widths = [max(len(h), *(len(r[i]) for r in rows)) if rows else len(h) for i, h in enumerate(headers)]
    lines = ["  ".join(h.ljust(w) for h, w in zip(headers[:-1], widths[:-1])) + "  " + headers[-1]]
    for c, r in zip(cells, rows):
        lines.append("  ".join(v.ljust(w) for v, w in zip(r[:-1], widths[:-1])) + "  " + r[-1])
        chosen = c.fits.get(c.chosen) if c.chosen else None
        if by_day and chosen is not None:
            cycle_ms = (c.cycle_s or 0) * 1000
            for day in sorted(chosen.day_phase_ms):
                parts = [f"{name} {c.fits[name].day_phase_ms[day] / 1000:7.1f}s" for name in ("epoch", "midnight")]
                diff = circular_diff_ms(chosen.day_phase_ms[day], chosen.phase_ms, cycle_ms)
                lines.append(f"    {day.isoformat()}  {'  '.join(parts)}  採用基準の位相との差 {diff / 1000:+.1f}s")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


def load_input(path: Path, today: str | None, stats: ReportStats) -> tuple[list[Event], str]:
    """Loads one file; a recording (JSON Lines) or a D1 export (JSON). Returns (events, kind)."""
    text = path.read_text(encoding="utf-8")
    try:
        document = json.loads(text)
    except ValueError:
        document = None
    looks_like_recording = (
        isinstance(document, dict) and "manufacturerData" in document
    ) or (
        isinstance(document, list) and document and isinstance(document[0], dict)
        and "manufacturerData" in document[0]
    )
    if document is not None and not looks_like_recording and isinstance(document, (list, dict)):
        return events_from_reports(document, today, stats, label=path.name), "reports"
    events, bad = events_from_recording(path)
    if bad:
        print(f"{path}: 読めない行が {bad} 行ありました", file=sys.stderr)
    return events, "recording"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="信号の周期と位相の当てはめ（docs/timing-estimation.md の段階 0）",
    )
    parser.add_argument("files", nargs="+", type=Path,
                        help="記録ファイル（.jsonl）または reports 表の JSON 書き出し")
    parser.add_argument("--min-days", type=int, default=MIN_DAYS, help=f"必要な日数（初期値 {MIN_DAYS}）")
    parser.add_argument("--min-reports", type=int, default=MIN_REPORTS,
                        help=f"必要な報告の行数。記録ファイルは別のファイルの数（初期値 {MIN_REPORTS}）")
    parser.add_argument("--by-day", action="store_true", help="セルごとに日ごとの位相も表示する")
    parser.add_argument("--json", action="store_true", help="JSON で出力する")
    parser.add_argument("--today", metavar="YYYY-MM-DD",
                        help="reports の行は、この日（UTC）より前に受信したものだけを使う（初期値は今日の UTC の日付）")
    parser.add_argument("--intersection", metavar="ID", help="この交差点 ID だけを表示する")
    args = parser.parse_args(argv)

    today = args.today or dt.datetime.now(dt.timezone.utc).date().isoformat()
    stats = ReportStats()
    events: list[Event] = []
    recordings = 0
    for path in args.files:
        try:
            found, kind = load_input(path, today, stats)
        except OSError as error:
            print(f"{path}: {error}", file=sys.stderr)
            return 2
        recordings += kind == "recording"
        events.extend(found)

    cells = fit_cells(events, args.min_days, args.min_reports)
    if args.intersection:
        cells = [c for c in cells if c.intersection == args.intersection.upper()]

    if args.json:
        json.dump(
            {
                "today": today,
                "recordings": recordings,
                "reports": stats.__dict__,
                "cells": [cell_to_json(c) for c in cells],
            },
            sys.stdout, ensure_ascii=False, indent=2,
        )
        print()
        return 0

    if stats.rows:
        print(
            f"reports: {stats.rows} 行（使用 {stats.used}、clock_ok でない {stats.skipped_clock}、"
            f"{today} 以降の受信 {stats.skipped_today}、読めない {stats.skipped_invalid}）"
        )
    if recordings:
        print(f"記録ファイル: {recordings} 件（時計は合っているものとして扱います）")
    if not cells:
        print("青の始まり（赤 → 青）の変化が見つかりませんでした。")
        return 0
    print(format_table(cells, by_day=args.by_day))
    ok = sum(c.ok for c in cells)
    print(f"\n{len(cells)} セル中 {ok} セルが公開の条件を満たします。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
