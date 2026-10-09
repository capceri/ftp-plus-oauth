#!/usr/bin/env python3
"""Decode FIT files with Garmin's official FIT SDK and check they are valid activities.

Usage: python3 scripts/validate_fit.py FILE_OR_DIR [...]
Requires: pip install garmin-fit-sdk
"""
import sys
from pathlib import Path

from garmin_fit_sdk import Decoder, Stream


def validate(path: Path) -> list[str]:
    problems = []
    # Each check consumes the stream, so give every step a fresh decoder.
    if not Decoder(Stream.from_file(str(path))).is_fit():
        return ["not a FIT file"]
    if not Decoder(Stream.from_file(str(path))).check_integrity():
        problems.append("CRC / integrity check failed")
    messages, errors = Decoder(Stream.from_file(str(path))).read(convert_datetimes_to_dates=False)
    problems += [f"decoder error: {e}" for e in errors]

    for required in ("file_id_mesgs", "record_mesgs", "event_mesgs", "lap_mesgs", "session_mesgs", "activity_mesgs"):
        if not messages.get(required):
            problems.append(f"missing {required}")
    if problems:
        return problems

    file_id = messages["file_id_mesgs"][0]
    if file_id.get("type") != "activity":
        problems.append(f"file_id.type is {file_id.get('type')!r}")

    records = messages["record_mesgs"]
    times = [r["timestamp"] for r in records]
    if times != sorted(times) or len(set(times)) != len(times):
        problems.append("record timestamps are not strictly increasing")

    session = messages["session_mesgs"][0]
    if session.get("sport") != "cycling":
        problems.append(f"session.sport is {session.get('sport')!r}")
    elapsed = session.get("total_elapsed_time")
    if elapsed is None or abs(elapsed - (times[-1] - times[0])) > 1:
        problems.append(f"session elapsed time {elapsed} doesn't match records")

    powers = [r["power"] for r in records if r.get("power") is not None]
    if powers:
        avg = round(sum(powers) / len(powers))
        if session.get("avg_power") != avg:
            problems.append(f"session avg_power {session.get('avg_power')} != records average {avg}")

    activity = messages["activity_mesgs"][0]
    if activity.get("num_sessions") != 1:
        problems.append("activity.num_sessions != 1")

    print(f"{path.name}: {len(records)} records, "
          f"{len(powers)} with power, avg {session.get('avg_power')} W, NP {session.get('normalized_power')} W, "
          f"max {session.get('max_power')} W, avg HR {session.get('avg_heart_rate')}, "
          f"avg cadence {session.get('avg_cadence')}, devices "
          f"{[d.get('product_name') for d in messages.get('device_info_mesgs', [])]}, "
          f"first record {records[0]}")
    return problems


def main() -> int:
    paths = []
    for arg in sys.argv[1:]:
        p = Path(arg)
        paths += sorted(p.glob("*.fit")) if p.is_dir() else [p]
    if not paths:
        print("no FIT files given", file=sys.stderr)
        return 2
    failed = False
    for path in paths:
        problems = validate(path)
        for problem in problems:
            print(f"{path.name}: {problem}", file=sys.stderr)
        failed |= bool(problems)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
