"""Local-only adapter parity fixture. Reads SQLite without modifying it; prints no measurements."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sqlite3
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from fitbit_audit.normalize import normalize
from fitbit_audit.sync import SCORING_METRICS


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timezone", default="America/Los_Angeles")
    args = parser.parse_args()
    os.umask(0o077)
    if args.output.is_symlink() or args.output.parent.is_symlink():
        raise ValueError("Private fixture cannot use a symlink.")
    connection = sqlite3.connect(args.database.resolve().as_uri() + "?mode=ro", uri=True)
    try:
        connection.execute("BEGIN")
        records = {
            metric: [json.loads(row[0]) for row in connection.execute(
                "SELECT payload FROM records WHERE metric=? ORDER BY event,identity", (metric,))]
            for metric in SCORING_METRICS
        }
        windows = {}
        for metric, start, end in connection.execute("SELECT metric,start,end FROM windows"):
            windows.setdefault(metric, []).append((start, end))
        age = json.loads(connection.execute("SELECT value FROM settings WHERE key='profile_age'").fetchone()[0])
    finally:
        connection.close()
    captured = datetime.now(timezone.utc)
    expected = normalize(records, {"age": age}, args.timezone, captured, windows)
    fixture = {"records": records, "ageYears": age, "capturedAt": captured.isoformat().replace("+00:00", "Z"),
               "timeZone": args.timezone, "completedWindows": {
                   metric: [[a + "T00:00:00Z", b + "T00:00:00Z"] for a, b in values]
                   for metric, values in windows.items()}, "expected": expected}
    args.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with args.output.open("x") as stream:
        json.dump(fixture, stream, separators=(",", ":"), allow_nan=False)
    args.output.chmod(0o600)
    print("Private adapter parity fixture written; measurements omitted.")


if __name__ == "__main__":
    main()
