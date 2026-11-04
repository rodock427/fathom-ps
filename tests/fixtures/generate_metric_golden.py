"""Regenerate metrics.golden.json from Python Fathom's own reporting functions.

Needs Fathom's virtualenv and a throwaway Postgres (it TRUNCATEs license_events):

    FATHOM_TEST_DSN=postgresql://... ../license_manager/.venv/bin/python tests/fixtures/generate_metric_golden.py

Loads emulator_day.log (one day: see generate_golden.py) with Fathom's parser and writer, then records peak_concurrency and
denial_rate for the windows in WINDOWS. tests/Metrics.Tests.ps1 loads the same log with
fathom-ps and must get the same numbers.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
FATHOM = HERE.parents[2] / "license_manager"
sys.path[:0] = [str(p) for p in (FATHOM / "src").glob("lm_*")]

import psycopg  # noqa: E402
from lm_opdb.license_events import ensure_license_events_table, write_events  # noqa: E402
from lm_parsers.flexlm.parser import FlexLMParser  # noqa: E402
from lm_parsers.schema import ParserContext  # noqa: E402
from lm_reporting.engine import PostgresEngine  # noqa: E402
from lm_reporting.queries import denial_rate, peak_concurrency  # noqa: E402

# Pinned, shared with tests/Metrics.Tests.ps1. The second window opens mid-day, so seats
# held from before it must carry in.
SERVER_ID = "parity"
WINDOWS = {
    "whole-day": (datetime(2026, 8, 20, 0, 0), datetime(2026, 8, 21, 0, 0)),
    "afternoon": (datetime(2026, 8, 20, 13, 0), datetime(2026, 8, 20, 17, 0)),
}


def main() -> None:
    dsn = os.environ["FATHOM_TEST_DSN"]
    log = HERE / "emulator_day.log"
    context = ParserContext(
        source_file=log.name, source_file_hash="parity", server_id=SERVER_ID,
        ingest_batch_id="parity", current_date=datetime(2026, 1, 1),
    )
    with psycopg.connect(dsn, autocommit=True) as conn:
        ensure_license_events_table(conn)
        conn.execute("TRUNCATE license_events")
        write_events(conn, list(FlexLMParser().parse_file(log, context)))

    engine = PostgresEngine(dsn)
    golden = {}
    for name, (start, end) in WINDOWS.items():
        peaks = peak_concurrency(engine, start, end, SERVER_ID)
        denials = denial_rate(engine, start, end, SERVER_ID)
        golden[name] = {
            "start": start.isoformat(),
            "end": end.isoformat(),
            "peak": {r.feature: int(r.peak_in_use) for r in peaks.itertuples()},
            "denials": {r.feature: int(r.denials) for r in denials.itertuples()},
            "checkouts": {r.feature: int(r.checkouts) for r in denials.itertuples()},
        }
    (HERE / "metrics.golden.json").write_text(json.dumps(golden, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
