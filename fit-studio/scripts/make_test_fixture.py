#!/usr/bin/env python3
"""Writes Tests/FITStudioCoreTests/Fixtures/garmin-sdk-ride.fit with Garmin's own FIT encoder.

The fixture is a 20-minute outdoor ride shaped like a Garmin Edge file: GPS, enhanced speed and
altitude, power with L/R balance, heart rate, cadence, temperature, two developer fields, two
laps and a session with summary values. Because a different encoder made it, it checks that
FIT Studio reads files it didn't write.

Usage:
    python3 -m venv .venv && .venv/bin/pip install garmin-fit-sdk
    .venv/bin/python scripts/make_test_fixture.py Tests/FITStudioCoreTests/Fixtures/garmin-sdk-ride.fit
"""
import math
import sys
from datetime import datetime, timezone

from garmin_fit_sdk import Encoder
from garmin_fit_sdk.profile import Profile

MESG = Profile["mesg_num"]
START = datetime(2026, 9, 20, 8, 30, 0, tzinfo=timezone.utc)
SECONDS = 1200


def ts(seconds):
    return int(START.timestamp()) - 631065600 + seconds


def sample(i):
    """Deterministic but varied ride data for second i."""
    power = 180 + 60 * math.sin(i / 37) + 25 * math.sin(i / 5.3)
    if 400 <= i < 430:
        power = 0  # coasting
    if 700 <= i < 760:
        power = 380 + 20 * math.sin(i)  # an effort
    cadence = 0 if power == 0 else 85 + 6 * math.sin(i / 11)
    speed = 8.0 + 1.5 * math.sin(i / 90)
    return {
        "power": round(power),
        "cadence": round(cadence),
        "heart_rate": round(128 + 25 * (1 - math.exp(-i / 300)) + 4 * math.sin(i / 60)),
        "enhanced_speed": round(speed, 3),
        "enhanced_altitude": round(120 + 35 * math.sin(i / 240), 1),
        "temperature": 18 + i // 400,
        "left_right_balance": 0x80 | (50 + round(2 * math.sin(i / 50))),
    }


def main(path):
    developer_id = {"mesg_num": MESG["DEVELOPER_DATA_ID"], "developer_data_index": 0,
                    "application_id": list(range(16)), "application_version": 3}
    power2 = {"mesg_num": MESG["FIELD_DESCRIPTION"], "developer_data_index": 0, "field_definition_number": 0,
              "fit_base_type_id": 0x84, "field_name": "Power2", "units": "watts",
              "native_mesg_num": MESG["RECORD"], "native_field_num": 7}
    core = {"mesg_num": MESG["FIELD_DESCRIPTION"], "developer_data_index": 0, "field_definition_number": 1,
            "fit_base_type_id": 0x88, "field_name": "Core Temp", "units": "C"}
    encoder = Encoder()
    encoder.add_developer_field("power2", developer_id, power2)
    encoder.add_developer_field("core", developer_id, core)

    encoder.write_mesg({"mesg_num": MESG["FILE_ID"], "type": "activity", "manufacturer": "garmin",
                        "product": 3843, "serial_number": 3412345678, "time_created": ts(0)})
    encoder.write_mesg(developer_id)
    encoder.write_mesg(power2)
    encoder.write_mesg(core)
    encoder.write_mesg({"mesg_num": MESG["DEVICE_INFO"], "timestamp": ts(0), "device_index": 0,
                        "manufacturer": "garmin", "product": 3843, "serial_number": 3412345678,
                        "software_version": 27.1, "source_type": "local"})
    encoder.write_mesg({"mesg_num": MESG["DEVICE_INFO"], "timestamp": ts(0), "device_index": 1,
                        "device_type": 11, "manufacturer": "favero_electronics", "product": 12,
                        "serial_number": 48023, "battery_status": "good", "source_type": "antplus"})
    encoder.write_mesg({"mesg_num": MESG["DEVICE_INFO"], "timestamp": ts(0), "device_index": 2,
                        "device_type": 120, "manufacturer": "garmin", "serial_number": 990011,
                        "battery_voltage": 2.95, "source_type": "antplus"})
    encoder.write_mesg({"mesg_num": MESG["EVENT"], "timestamp": ts(0), "event": "timer", "event_type": "start"})

    distance = 0.0
    accumulated = 0
    lat0, lon0 = 51.4816, -3.1791  # Cardiff
    laps = []
    lap_start = 0
    for i in range(SECONDS):
        values = sample(i)
        distance += values["enhanced_speed"]
        accumulated += values["power"]
        angle = i / SECONDS * 2 * math.pi
        record = {"mesg_num": MESG["RECORD"], "timestamp": ts(i),
                  "position_lat": round((lat0 + 0.02 * math.sin(angle)) * 2**31 / 180),
                  "position_long": round((lon0 + 0.03 * (1 - math.cos(angle))) * 2**31 / 180),
                  "distance": round(distance, 2), "accumulated_power": accumulated, **values,
                  "developer_fields": {"power2": values["power"] + 4, "core": 37.5 + i / 2400}}
        encoder.write_mesg(record)
        if i in (599, SECONDS - 1):
            laps.append((lap_start, i))
            lap_start = i + 1

    def summary(first, last):
        rows = [sample(i) for i in range(first, last + 1)]
        power = [r["power"] for r in rows]
        rolling = [sum(power[k - 29:k + 1]) / 30 for k in range(29, len(power))]
        np_ = round((sum(p ** 4 for p in rolling) / len(rolling)) ** 0.25)
        speed = sum(r["enhanced_speed"] for r in rows) / len(rows)
        return {
            "start_time": ts(first), "timestamp": ts(last),
            "total_elapsed_time": last - first + 1, "total_timer_time": last - first + 1,
            "total_distance": round(speed * len(rows), 2),
            "avg_power": round(sum(power) / len(power)), "max_power": max(power), "normalized_power": np_,
            "total_work": sum(power),
            "avg_heart_rate": round(sum(r["heart_rate"] for r in rows) / len(rows)),
            "max_heart_rate": max(r["heart_rate"] for r in rows),
            "avg_cadence": round(sum(r["cadence"] for r in rows if r["cadence"]) / sum(1 for r in rows if r["cadence"])),
            "max_cadence": max(r["cadence"] for r in rows),
            "enhanced_avg_speed": round(speed, 3), "enhanced_max_speed": max(r["enhanced_speed"] for r in rows),
            "enhanced_max_altitude": max(r["enhanced_altitude"] for r in rows),
            "enhanced_min_altitude": min(r["enhanced_altitude"] for r in rows),
            "avg_temperature": round(sum(r["temperature"] for r in rows) / len(rows)),
            "max_temperature": max(r["temperature"] for r in rows),
        }

    for index, (first, last) in enumerate(laps):
        encoder.write_mesg({"mesg_num": MESG["LAP"], "message_index": index, "event": "lap", "event_type": "stop",
                            "sport": "cycling", **summary(first, last)})
    encoder.write_mesg({"mesg_num": MESG["EVENT"], "timestamp": ts(SECONDS - 1), "event": "timer", "event_type": "stop_all"})
    session = summary(0, SECONDS - 1)
    encoder.write_mesg({"mesg_num": MESG["SESSION"], "message_index": 0, "event": "session", "event_type": "stop",
                        "sport": "cycling", "sub_sport": "road", "first_lap_index": 0, "num_laps": len(laps),
                        "total_calories": 640, "total_ascent": 70, "total_descent": 70,
                        "threshold_power": 250, "intensity_factor": session["normalized_power"] / 250,
                        "training_stress_score": round(SECONDS * session["normalized_power"] ** 2 / (250 ** 2 * 36), 1),
                        **session})
    encoder.write_mesg({"mesg_num": MESG["ACTIVITY"], "timestamp": ts(SECONDS - 1), "total_timer_time": SECONDS,
                        "num_sessions": 1, "type": "manual", "event": "activity", "event_type": "stop",
                        "local_timestamp": ts(SECONDS - 1) + 3600})
    with open(path, "wb") as f:
        f.write(encoder.close())
    print(f"wrote {path}")


if __name__ == "__main__":
    main(sys.argv[1])
