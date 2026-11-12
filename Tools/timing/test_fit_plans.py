# SPDX-License-Identifier: Apache-2.0
"""Tests for fit_plans.py with synthetic signals. Run: python3 -m unittest discover -s Tools/timing -v"""

import datetime as dt
import json
import tempfile
import unittest
from pathlib import Path

import fit_plans as fp

INTERSECTION = "1234ABCD"
GREEN_S, BLINK_S = 30, 6


def jst_midnight(year: int, month: int, day: int) -> int:
    """Unix seconds of 00:00 JST."""
    return int(dt.datetime(year, month, day, tzinfo=fp.JST).timestamp())


def packet_hex(state_nibble: int, remaining: int = 3, intersection: str = INTERSECTION) -> str:
    """Manufacturer data of a Type 2 packet with one signal."""
    header = bytes([0x00, 0x00, 0x02, 0x2A, 0x00, 0x00]) + bytes.fromhex(intersection)
    return (b"\xCE\x01" + header + bytes([(remaining << 4) | state_nibble])).hex().upper()


NIBBLE = {"Red": 1, "BlinkGreen": 2, "Green": 3}


def state_at(starts: list[float], t: float) -> str:
    past = [s for s in starts if s <= t]
    if not past:
        return "Red"
    elapsed = t - past[-1]
    if elapsed < GREEN_S:
        return "Green"
    return "BlinkGreen" if elapsed < GREEN_S + BLINK_S else "Red"


def write_recording(path: Path, starts: list[float], t0: float, t1: float, step: float = 0.2) -> None:
    """Writes a JSON Lines recording of a signal whose green starts are `starts` (Unix s)."""
    lines = []
    steps = int(round((t1 - t0) / step))
    for i in range(steps):
        t = round(t0 + i * step, 3)
        data = packet_hex(NIBBLE[state_at(starts, t)])
        lines.append(json.dumps({"t": t, "manufacturerData": data, "rssi": -70}))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def fixed_starts(day_midnight: int, offset: float, cycle: float, window_start: float, window_end: float):
    """Green starts offset + k * cycle after `day_midnight`, inside the window."""
    k = int((window_start - day_midnight - offset) // cycle) - 1
    out = []
    while True:
        s = day_midnight + offset + k * cycle
        if s > window_end:
            return out
        if s >= window_start - 60:
            out.append(s)
        k += 1


class CalendarTests(unittest.TestCase):
    def test_day_types_and_bins(self):
        self.assertEqual(fp.day_type(dt.date(2026, 11, 10)), 0)  # Tuesday
        self.assertEqual(fp.day_type(dt.date(2026, 11, 14)), 1)  # Saturday
        self.assertEqual(fp.day_type(dt.date(2026, 11, 15)), 2)  # Sunday
        jst = fp.JstTime.of(jst_midnight(2026, 11, 10) * 1000 + (10 * 60 + 35) * 60_000)
        self.assertEqual((jst.date, jst.bin), (dt.date(2026, 11, 10), 21))
        self.assertEqual(fp.format_bin(21), "10:30-11:00")
        self.assertEqual(fp.format_bin(47), "23:30-24:00")

    def test_excluded_days(self):
        for date in [dt.date(2026, 11, 3), dt.date(2026, 12, 30), dt.date(2027, 1, 2), dt.date(2028, 5, 1)]:
            self.assertTrue(fp.is_excluded_day(date), date)
        for date in [dt.date(2026, 11, 10), dt.date(2026, 12, 28), dt.date(2027, 1, 4)]:
            self.assertFalse(fp.is_excluded_day(date), date)


class ParsingTests(unittest.TestCase):
    def test_signal_packet(self):
        # slot 1: remaining 4 (high nibble 3), Red; slot 2: remaining 1, Green; slot 3: unused.
        packet = fp.parse_signal_packet("CE0100000" "22A0000" "1234ABCD" "31" "03" "04".upper())
        self.assertIsNotNone(packet)
        self.assertEqual(packet.intersection_id, "1234ABCD")
        self.assertEqual(packet.states, ("Red", "Green", "None"))

    def test_rejects_other_packets(self):
        self.assertIsNone(fp.parse_signal_packet("CE01" "0000" "00" "2A0000" "1234ABCD" + "00" * 14))  # Type 0
        self.assertIsNone(fp.parse_signal_packet("CE0200000" "22A0000" "1234ABCD" "31"))  # not PICS
        self.assertIsNone(fp.parse_signal_packet("CE01" "00000" "22A0000" "1234ABCD"))  # no signal byte
        self.assertIsNone(fp.parse_signal_packet("zz"))

    def test_derive_transitions_like_field_collector(self):
        def pkt(name):
            return fp.parse_signal_packet(packet_hex(NIBBLE[name]))

        sequence = [
            (100.0, pkt("Red")), (100.2, pkt("Red")),
            (100.4, pkt("Green")),
            (101.0, pkt("Green")),
            (105.0, pkt("BlinkGreen")),
            (106.0, pkt("Red")),
            (107.0, pkt("Green")),
            (113.0, pkt("Red")),  # 6 s pause: no transition, timing is forgotten
            (113.2, pkt("Green")),
        ]
        out = fp.derive_transitions(sequence)
        summary = [(tr.from_state, tr.to_state, tr.gap, tr.held, tr.cycle) for tr in out]
        self.assertEqual(summary, [
            ("Red", "Green", 200, None, None),
            ("Green", "BlinkGreen", 4000, 4600, None),
            ("BlinkGreen", "Red", 1000, 1000, None),
            ("Red", "Green", 1000, 1000, 6600),
            ("Red", "Green", 200, None, None),
        ])
        self.assertAlmostEqual(out[0].t_ms, 100_400)

    def test_recording_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "r.jsonl"
            lines = [
                {"t": 1000.0, "manufacturerData": packet_hex(1)},
                {"t": 1000.2, "manufacturerData": packet_hex(3)},
            ]
            path.write_text("\n".join(json.dumps(x) for x in lines) + "\nnot json\n", encoding="utf-8")
            events, bad = fp.events_from_recording(path)
        self.assertEqual(bad, 1)
        self.assertEqual(len(events), 1)
        # T = t * 1000 - gap / 2 with the precise t.
        self.assertAlmostEqual(events[0].time_ms, 1_000_200 - 100)

    def test_d1_export_shapes(self):
        rows = [{"id": 1, "clock_ok": 1}]
        self.assertEqual(fp.d1_rows(rows), rows)
        self.assertEqual(fp.d1_rows({"results": rows}), rows)
        self.assertEqual(fp.d1_rows([{"results": rows, "success": True}]), rows)


class FitTests(unittest.TestCase):
    DAYS = [(2026, 11, 10), (2026, 11, 11), (2026, 11, 12)]  # Tue, Wed, Thu

    def build(self, tmp: Path, days, offset, cycle, reference_midnight=False):
        paths = []
        for index, (y, m, d) in enumerate(days):
            midnight = jst_midnight(y, m, d)
            start, end = midnight + 10 * 3600, midnight + 10 * 3600 + 20 * 60
            # `reference_midnight` anchors the cycle to the day's midnight; otherwise to the epoch.
            anchor = midnight if reference_midnight else 0
            starts = fixed_starts(anchor, offset, cycle, start, end)
            path = tmp / f"day{index}-{y}{m:02d}{d:02d}.jsonl"
            write_recording(path, starts, start, end)
            paths.append(path)
        return paths

    def fit(self, paths, **kwargs):
        events = []
        for path in paths:
            found, _ = fp.events_from_recording(path)
            events.extend(found)
        return fp.fit_cells(events, **kwargs)

    def test_fixed_time_signal_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            cells = self.fit(self.build(Path(tmp), self.DAYS, offset=37, cycle=120))
        self.assertEqual(len(cells), 1)
        cell = cells[0]
        self.assertEqual(cell.reasons, [])
        self.assertTrue(cell.ok)
        self.assertEqual((cell.intersection, cell.slot, cell.day_type, cell.bin), (INTERSECTION, 1, 0, 20))
        self.assertEqual(cell.cycle_s, 120)
        self.assertEqual(cell.days, 3)
        self.assertEqual(cell.reports, 3)
        self.assertEqual(cell.chosen, "epoch")
        phase = cell.fits["epoch"].phase_ms
        self.assertLess(abs(phase - 37_000), 300)
        self.assertLess(cell.fits["epoch"].spread_ms, 300)
        self.assertAlmostEqual(cell.green_ms, GREEN_S * 1000, delta=300)
        self.assertAlmostEqual(cell.blink_ms, BLINK_S * 1000, delta=300)
        self.assertEqual(cell.last_day, dt.date(2026, 11, 12))

    def test_not_enough_days_or_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = self.build(Path(tmp), self.DAYS[:2], offset=37, cycle=120)
            default = self.fit(paths)[0]
            relaxed = self.fit(paths, min_days=2)[0]
        self.assertFalse(default.ok)
        self.assertTrue(any("日数" in r for r in default.reasons))
        self.assertTrue(relaxed.ok)

    def test_variable_cycle_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for index, (y, m, d) in enumerate(self.DAYS):
                midnight = jst_midnight(y, m, d)
                start = midnight + 10 * 3600
                starts, t = [], start + 10.0
                for length in [90, 120, 150, 90, 120, 150, 90, 120]:
                    starts.append(t)
                    t += length
                path = Path(tmp) / f"v{index}.jsonl"
                write_recording(path, starts, start, t)
                paths.append(path)
            cell = self.fit(paths)[0]
        self.assertFalse(cell.ok)
        self.assertTrue(any("周期が定まらない" in r for r in cell.reasons))
        self.assertEqual(cell.fits, {})

    def test_holidays_are_excluded(self):
        holiday = (2026, 11, 23)  # Labor Thanksgiving Day, a Monday
        with tempfile.TemporaryDirectory() as tmp:
            normal = self.build(Path(tmp), self.DAYS, offset=37, cycle=120)
            # The holiday has a different phase; it must not influence the fit nor the day count.
            odd = self.build(Path(tmp) / ".", [holiday], offset=77, cycle=120)
            with_holiday = self.fit(normal + odd)
            only_two_plus_holiday = self.fit(normal[:2] + odd)
        self.assertEqual(len(with_holiday), 1)
        self.assertEqual(with_holiday[0].days, 3)
        self.assertTrue(with_holiday[0].ok)
        self.assertLess(abs(with_holiday[0].fits["epoch"].phase_ms - 37_000), 300)
        self.assertEqual(only_two_plus_holiday[0].days, 2)
        self.assertFalse(only_two_plus_holiday[0].ok)

    def test_midnight_reference_is_chosen(self):
        # 110 s does not divide a day (86,400 mod 110 = 50), so the epoch phase moves day to day.
        with tempfile.TemporaryDirectory() as tmp:
            cell = self.fit(self.build(Path(tmp), self.DAYS, offset=20, cycle=110, reference_midnight=True))[0]
        self.assertEqual(cell.cycle_s, 110)
        self.assertEqual(cell.chosen, "midnight")
        self.assertTrue(cell.ok, cell.reasons)
        self.assertLess(abs(cell.fits["midnight"].phase_ms - 20_000), 300)
        self.assertGreater(cell.fits["epoch"].spread_ms, 3000)

    def test_by_day_output_lists_each_day(self):
        with tempfile.TemporaryDirectory() as tmp:
            cells = self.fit(self.build(Path(tmp), self.DAYS, offset=37, cycle=120))
        text = fp.format_table(cells, by_day=True)
        for day in ("2026-11-10", "2026-11-11", "2026-11-12"):
            self.assertIn(day, text)
        self.assertIn("OK", text)


class ReportTests(unittest.TestCase):
    def rows(self, offset_ms=37_000, received="2026-11-11"):
        """D1 rows with schema 4 transitions of a 120 s signal (Red -> Green every cycle)."""
        out = []
        for index, (y, m, d) in enumerate([(2026, 11, 4), (2026, 11, 5), (2026, 11, 6), (2026, 11, 9)]):  # Wed-Fri, Mon
            midnight = jst_midnight(y, m, d)
            base = midnight + 10 * 3600
            transitions = []
            for k in range(6):
                t_ms = (base // 120 + 1 + k) * 120_000 + offset_ms + 100  # one packet after the change
                transitions.append({
                    "t": t_ms // 1000, "ms": (t_ms % 1000) // 100 * 100, "slot": 1,
                    "from": "Red", "to": "Green", "emitter": 0, "gap": 200,
                    "held": 90_000, "cycle": None if k == 0 else 120_000,
                })
            out.append({
                "id": 1000 + index, "intersection_id": INTERSECTION, "received_day": received,
                "schema": 4, "clock_ok": 1,
                "payload": json.dumps({"transitions": transitions}),
            })
        return out

    def test_reports_fit_and_filters(self):
        rows = self.rows()
        rows[0]["clock_ok"] = 0  # wrong clock
        rows[1]["clock_ok"] = None  # schema <= 3
        rows[2]["received_day"] = "2026-11-12"  # received today
        stats = fp.ReportStats()
        events = fp.events_from_reports([{"results": rows}], "2026-11-12", stats)
        self.assertEqual((stats.rows, stats.used, stats.skipped_clock, stats.skipped_today), (4, 1, 2, 1))
        self.assertEqual({e.source for e in events}, {"reports:1003"})

        stats = fp.ReportStats()
        events = fp.events_from_reports({"results": self.rows()}, "2026-11-12", stats)
        cells = fp.fit_cells(events, min_days=3, min_reports=2)
        self.assertEqual(len(cells), 1)
        self.assertTrue(cells[0].ok, cells[0].reasons)
        self.assertEqual(cells[0].reports, 4)
        # T = t + ms - gap / 2, so the phase is the change time minus 100 ms.
        self.assertLess(abs(cells[0].fits["epoch"].phase_ms - 37_000), 300)

    def test_payload_may_be_an_object_and_main_reads_files(self):
        rows = self.rows()
        for row in rows:
            row["payload"] = json.loads(row["payload"])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "reports.json"
            path.write_text(json.dumps(rows), encoding="utf-8")
            stats = fp.ReportStats()
            events, kind = fp.load_input(path, "2026-11-12", stats)
        self.assertEqual(kind, "reports")
        self.assertEqual(stats.used, 4)
        self.assertEqual(len(events), 24)


if __name__ == "__main__":
    unittest.main()
