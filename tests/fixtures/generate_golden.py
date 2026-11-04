"""Regenerate the parity golden files from Python Fathom's own parsers.

Run with Fathom's virtualenv (the parsers are imported from there):

    ../license_manager/.venv/bin/python tests/fixtures/generate_golden.py

Writes:
  emulator.log / emulator_lmstat.txt   larger inputs rendered by Fathom's emulator
  emulator_day.log                     emulator.log up to its first midnight (for metric parity)
  edge_cases.log                       hand-picked tricky lines (CRLF line endings)
  *.events.json / *.status.json        what Python Fathom parses each input into

Every value that would otherwise depend on "now" is pinned, so the output is stable.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
FATHOM = HERE.parents[2] / "license_manager"
sys.path[:0] = [str(FATHOM / "tools"), *(str(p) for p in (FATHOM / "src").glob("lm_*"))]

from flexlm_emulator import build_scenario, render_debug_log, render_lmstat  # noqa: E402
from lm_parsers.flexlm.lmstat import parse_lmstat_output  # noqa: E402
from lm_parsers.flexlm.parser import FlexLMParser  # noqa: E402
from lm_parsers.schema import ParserContext  # noqa: E402

# Pinned inputs shared with tests/Parity.Tests.ps1.
SEED_DATE = datetime(2026, 1, 1)
CAPTURED_AT = datetime(2026, 8, 20, 12, 0, 0)
IDS = {"server_id": "parity", "source_file_hash": "parity", "ingest_batch_id": "parity"}

EDGE_CASES = [
    "   09:00:00 (lmgrd) A line before any date marker uses the seeded date",
    "no leading time on this line at all",
    "09:00:01 (lmgrd) FLEXnet Licensing (v11.18.0.0 build 1) started on licsrv01 (Windows) (1/15/2026)",
    "\t09:00:02 (lmgrd) Started adskflex (pid 4242)",
    "09:00:03 (adskflex) TIMESTAMP 1/15/2026",
    '9:05:00 (adskflex) OUT: "ACD_2026_0F" alice@WS-01 (1 license)',
    '9:06:00 (adskflex) OUT: "87545ACD_2026_0F" bob@ws-02.corp.local (12 licenses)',
    '09:07:00 (adskflex) IN: "ACD_2026_0F" alice@WS-01  ',
    "",
    "   ",
    '09:10:00 (adskflex) DENIED: "INVENTOR_PRO" carol@WS-03  (Licensed number of users already reached. (-4,342))',
    '09:11:00 (adskflex) QUEUED: "INVENTOR_PRO" dave@WS-04',
    '09:12:00 (adskflex) License for "RVT_2024" has Expired',
    '23:59:59 (adskflex) OUT: "ACD_2026_0F" éva@WS-05',
    # Fathom does not roll the date at midnight; it waits for the next TIMESTAMP.
    '00:00:30 (adskflex) IN: "ACD_2026_0F" éva@WS-05',
    "00:01:00 (adskflex) TIMESTAMP 1/16/2026",
    "00:02:00 (lmgrd) Received signal 1 (Hangup). Re-reading license file.",
    "00:03:00 (adskflex) EXITING DUE TO SIGNAL 15",
    # Quirk kept for parity: the vendor-down rule is tried first, so this is
    # vendor_daemon_down with vendor "lmgrd", not server_down.
    "00:03:01 (lmgrd) EXITING DUE TO SIGNAL 15",
    "00:03:02 (mlm) Vendor daemon mlm is exiting",
    "00:04:00 (lmgrd) shutdown",
]


def write_inputs() -> None:
    scenario = build_scenario("site-b", seed=7, n_events=400)
    (HERE / "emulator.log").write_text(render_debug_log(scenario))
    (HERE / "emulator_lmstat.txt").write_text(render_lmstat(scenario))
    (HERE / "emulator_day.log").write_text(first_day(render_debug_log(scenario)))
    (HERE / "edge_cases.log").write_bytes(("\r\n".join(EDGE_CASES) + "\r\n").encode())


def first_day(log_text: str) -> str:
    """The lines before the clock first goes backwards (midnight, with no new TIMESTAMP).
    Fathom doesn't roll the date over there and fathom-ps does, so metrics can only be
    compared on a log that stays within one day."""
    lines, last = [], ""
    for line in log_text.splitlines(keepends=True):
        clock = line.split(" ", 1)[0].zfill(8)
        if last and clock < last:
            break
        lines.append(line)
        last = clock
    return "".join(lines)


def golden_events(log: Path) -> list[dict]:
    context = ParserContext(source_file=log.name, current_date=SEED_DATE, **IDS)
    return [e.model_dump(mode="json") for e in FlexLMParser().parse_file(log, context)]


def golden_status(lmstat: Path) -> list[dict]:
    statuses = parse_lmstat_output(lmstat.read_text(), "parity", CAPTURED_AT)
    return [s.model_dump(mode="json") for s in statuses]


def dump(path: Path, rows: list[dict]) -> None:
    path.write_text(json.dumps(rows, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    write_inputs()
    for log in sorted(HERE.glob("*.log")):
        dump(log.with_suffix(".events.json"), golden_events(log))
    for lmstat in sorted(HERE.glob("*lmstat*.txt")):
        dump(lmstat.with_suffix(".status.json"), golden_status(lmstat))
