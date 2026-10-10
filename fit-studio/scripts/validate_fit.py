#!/usr/bin/env python3
"""Checks FIT Studio's adjusted files with Garmin's official FIT SDK.

The unit tests write pairs of original and adjusted files plus adjustments.json (when
FIT_OUTPUT_DIR is set). For every pair this script checks that:
  * both files decode without errors and pass the SDK's integrity (CRC) check;
  * every adjusted value equals the original times (1 + percent/100), to the field's resolution;
  * linked summary values (lap/session averages, maximums, NP, work, TSS…) were scaled too;
  * every other value in every message is unchanged.

Usage: python3 scripts/validate_fit.py DIR
Requires: pip install garmin-fit-sdk
"""
import json
import sys
from pathlib import Path

from garmin_fit_sdk import Decoder, Stream
from garmin_fit_sdk.profile import Profile

SUMMARY_KEYS = {"lap_mesgs", "session_mesgs", "length_mesgs", "segment_lap_mesgs", "split_mesgs", "split_summary_mesgs"}
MESSAGE_BY_KEY = {m["messages_key"]: m for m in Profile["messages"].values()}


def decode(path):
    if not Decoder(Stream.from_file(str(path))).check_integrity():
        raise AssertionError(f"{path.name}: integrity (CRC) check failed")
    messages, errors = Decoder(Stream.from_file(str(path))).read(
        expand_components=False, merge_heart_rates=False, convert_datetimes_to_dates=False)
    if errors:
        raise AssertionError(f"{path.name}: decoder errors {errors}")
    return messages


def record_fields(key):
    """Record fields belonging to a channel (same rules as FITStudioCore)."""
    names = {key, f"enhanced_{key}"}
    if key == "cadence":
        names.add("cadence256")
    if key == "power":
        names |= {"accumulated_power", "compressed_accumulated_power"}
    return names


def summary_fields(key):
    """Summary fields that follow a channel, with the exponent applied to the factor."""
    base = [key, f"avg_{key}", f"max_{key}", f"min_{key}", f"total_{key}"]
    links = {name: 1 for name in base + [f"enhanced_{n}" for n in base]}
    if key == "power":
        links.update({"normalized_power": 1, "total_work": 1, "avg_power_position": 1, "max_power_position": 1,
                      "intensity_factor": 1, "training_stress_score": 2})
    if key == "altitude":
        links.update({"total_ascent": 1, "total_descent": 1})
    if key == "cadence":
        links.update({"avg_cadence_position": 1, "max_cadence_position": 1})
    return links


def resolution(messages_key, field_name):
    message = MESSAGE_BY_KEY.get(messages_key)
    if message:
        for field in message["fields"].values():
            if field["name"] == field_name:
                scale = field["scale"][0] if len(field["scale"]) == 1 else 1
                return 0.5 / scale
    return 0.5


def close(expected, actual, tolerance):
    if isinstance(expected, list):
        return isinstance(actual, list) and len(expected) == len(actual) and all(
            close(e, a, tolerance) for e, a in zip(expected, actual))
    if expected is None or actual is None:
        return expected is None and actual is None
    return abs(expected - actual) <= tolerance + 1e-6 * max(1, abs(expected))


def scaled(value, factor):
    if isinstance(value, list):
        return [scaled(v, factor) for v in value]
    return None if value is None else value * factor


def check_pair(directory, item):
    original = decode(directory / item["original"])
    adjusted = decode(directory / item["adjusted"])
    percents = item["percents"]
    problems = []
    changed = 0

    developer_names = {}
    for description in original.get("field_description_mesgs", []):
        name = "dev:" + description["field_name"].lower().replace(" ", "_")
        developer_names[name] = description["field_definition_number"]

    if set(original) != set(adjusted):
        problems.append(f"message types differ: {sorted(set(original) ^ set(adjusted))}")
    for key in original:
        before, after = original[key], adjusted.get(key, [])
        if len(before) != len(after):
            problems.append(f"{key}: {len(before)} messages became {len(after)}")
            continue
        targets = {}
        for channel, percent in percents.items():
            factor = 1 + percent / 100
            if key == "record_mesgs" and not channel.startswith("dev:"):
                targets.update({name: factor for name in record_fields(channel)})
            elif key in SUMMARY_KEYS and not channel.startswith("dev:"):
                targets.update({name: factor ** exponent for name, exponent in summary_fields(channel).items()})
        dev_targets = {developer_names[c]: 1 + p / 100 for c, p in percents.items()
                       if c.startswith("dev:") and key == "record_mesgs" and c in developer_names}

        for index, (b, a) in enumerate(zip(before, after)):
            for name in set(b) | set(a):
                if name == "developer_fields":
                    for number in set(b.get(name, {})) | set(a.get(name, {})):
                        bv, av = b.get(name, {}).get(number), a.get(name, {}).get(number)
                        if number in dev_targets:
                            if not close(scaled(bv, dev_targets[number]), av, 0.5):
                                problems.append(f"{key}[{index}] developer field {number}: {bv} -> {av}")
                            changed += bv is not None
                        elif bv != av:
                            problems.append(f"{key}[{index}] developer field {number} changed: {bv} -> {av}")
                    continue
                bv, av = b.get(name), a.get(name)
                if name in targets and bv is not None and not isinstance(bv, str):
                    if not close(scaled(bv, targets[name]), av, resolution(key, name)):
                        problems.append(f"{key}[{index}].{name}: {bv} x {targets[name]:.4f} != {av}")
                    changed += 1
                elif bv != av:
                    problems.append(f"{key}[{index}].{name} changed unexpectedly: {bv} -> {av}")
            if len(problems) > 20:
                return problems + ["(stopping after 20 problems)"]

    if changed == 0:
        problems.append("nothing was adjusted")
    session = adjusted.get("session_mesgs", [{}])[0]
    powers = [r["power"] for r in adjusted["record_mesgs"] if r.get("power") is not None]
    if powers and session.get("avg_power") is not None and abs(session["avg_power"] - sum(powers) / len(powers)) > 1:
        problems.append(f"session avg_power {session['avg_power']} doesn't match the adjusted records")
    print(f"{item['adjusted']}: {changed} values adjusted ({', '.join(f'{k} {v:+g}%' for k, v in percents.items())}), "
          f"{sum(len(v) for v in adjusted.values())} messages checked")
    return problems


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    directory = Path(sys.argv[1])
    manifest = json.loads((directory / "adjustments.json").read_text())
    failed = False
    for item in manifest:
        try:
            problems = check_pair(directory, item)
        except AssertionError as error:
            problems = [str(error)]
        for problem in problems:
            print(f"{item['adjusted']}: {problem}", file=sys.stderr)
        failed |= bool(problems)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
