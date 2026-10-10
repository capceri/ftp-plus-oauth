import XCTest
@testable import FITStudioCore

/// Reads a file written by Garmin's own FIT SDK encoder (scripts/make_test_fixture.py).
final class FixtureTests: XCTestCase {
    static func fixture() throws -> FITFile {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "garmin-sdk-ride", withExtension: "fit", subdirectory: "Fixtures"))
        return try FITFile(data: Data(contentsOf: url))
    }

    func testDecodesGarminSDKFile() throws {
        let file = try Self.fixture()
        XCTAssertTrue(file.warnings.isEmpty, "\(file.warnings)")
        XCTAssertTrue(file.segments[0].crcIsValid)
        XCTAssertEqual(file.messages(FITMessageNumber.record).count, 1200)
        XCTAssertEqual(file.messages(FITMessageNumber.lap).count, 2)
    }

    func testChannels() throws {
        let activity = Activity(file: try Self.fixture())
        XCTAssertEqual(activity.times.count, 1200)
        XCTAssertEqual(activity.duration, 1199)
        XCTAssertEqual(activity.startUnix, 1_789_893_000)   // 2026-09-20 08:30 UTC
        let keys = activity.channels.map(\.key.rawValue)
        for expected in ["power", "heart_rate", "cadence", "speed", "distance", "altitude", "temperature",
                         "left_right_balance", "dev:power2", "dev:core_temp"] {
            XCTAssertTrue(keys.contains(expected), "missing \(expected) in \(keys)")
        }
        // Standard channels come first, in the preferred order.
        XCTAssertEqual(Array(keys.prefix(6)), ["power", "heart_rate", "cadence", "speed", "distance", "altitude"])
        XCTAssertEqual(activity.channel(.power)?.values.first, 180)
        XCTAssertEqual(activity.channel(.heartRate)?.values.first, 128)
        XCTAssertEqual(activity.channel(.speed)?.values.first, 8)
        XCTAssertEqual(activity.channel(.altitude)?.values.first, 120)
        XCTAssertEqual(activity.channel(.balance)?.values.first, 50)
        XCTAssertEqual(activity.channel(ChannelKey("dev:power2"))?.values.first, 184)
        XCTAssertEqual(try XCTUnwrap(activity.channel(ChannelKey("dev:core_temp"))?.values.first ?? nil), 37.5, accuracy: 0.001)
        XCTAssertEqual(activity.channel(.power)?.units, "W")
        XCTAssertEqual(activity.channel(.altitude)?.name, "Elevation")
        XCTAssertFalse(activity.channel(ChannelKey("accumulated_power"))?.isAdjustable ?? true)
        XCTAssertTrue(activity.hasPositions)
        XCTAssertEqual(try XCTUnwrap(activity.positions.first ?? nil).latitude, 51.4816, accuracy: 1e-6)
    }

    func testInfo() throws {
        let info = Activity(file: try Self.fixture()).info
        XCTAssertEqual(info.creator, "Garmin Edge 1040")
        XCTAssertEqual(info.fileType, "Activity")
        XCTAssertEqual(info.sport, "Cycling · Road")
        XCTAssertEqual(info.profileVersion, "21.218")
        XCTAssertEqual(try XCTUnwrap(info.distance), 9637.26, accuracy: 0.01)
        XCTAssertEqual(info.elapsedTime, 1200)
        XCTAssertEqual(info.calories, 640)
        XCTAssertEqual(info.laps.count, 2)
        XCTAssertEqual(info.laps[1].start, 600)
        XCTAssertEqual(info.laps[1].end, 1200)
        XCTAssertEqual(info.devices.count, 3)
        XCTAssertEqual(info.devices[1].name, "Favero Assioma Duo")
        XCTAssertEqual(info.devices[1].type, "Bike power")
        XCTAssertEqual(info.devices[1].batteryStatus, "Good")
        XCTAssertEqual(info.devices[0].softwareVersion, 27.1)
        XCTAssertEqual(info.developerFields.map(\.name), ["Power2", "Core Temp"])
        XCTAssertTrue(info.messageCounts.contains { $0.name == "Record" && $0.count == 1200 })
    }

    func testStatsMatchSessionSummary() throws {
        let file = try Self.fixture()
        let activity = Activity(file: file)
        let session = file.messages(FITMessageNumber.session)[0]
        let metrics = try XCTUnwrap(activity.powerMetrics())
        XCTAssertEqual(metrics.average.rounded(), file.value(named: "avg_power", in: session))
        XCTAssertEqual(metrics.maximum, file.value(named: "max_power", in: session))
        XCTAssertEqual(try XCTUnwrap(metrics.normalized).rounded(), file.value(named: "normalized_power", in: session))
        XCTAssertEqual(metrics.work * 1000, file.value(named: "total_work", in: session))
        XCTAssertEqual(metrics.curve.first?.duration, 1)
        XCTAssertEqual(metrics.curve.first?.watts, 400)
        let heartRate = try XCTUnwrap(activity.stats(for: try XCTUnwrap(activity.channel(.heartRate))))
        XCTAssertEqual(heartRate.average.rounded(), file.value(named: "avg_heart_rate", in: session))
        XCTAssertEqual(heartRate.coverage, 1)
        // Lap 2 from the records matches the lap message.
        let lap = file.messages(FITMessageNumber.lap)[1]
        let lapPower = try XCTUnwrap(activity.powerMetrics(in: 600...1199))
        XCTAssertEqual(lapPower.average.rounded(), file.value(named: "avg_power", in: lap))
    }

    func testInspector() throws {
        let file = try Self.fixture()
        let session = FITInspector.fields(of: file.messages(FITMessageNumber.session)[0], in: file)
        func field(_ name: String) -> InspectedField? { session.first { $0.name == name } }
        XCTAssertEqual(field("Sport")?.value, "Cycling")
        XCTAssertEqual(field("Avg power")?.value, "186")
        XCTAssertEqual(field("Avg power")?.units, "W")
        XCTAssertEqual(field("Start time")?.value, "2026-09-20T08:30:00Z")
        XCTAssertEqual(field("Total distance")?.raw, "963726")
        XCTAssertEqual(field("Total distance")?.value, "9637.26")
        let record = FITInspector.fields(of: file.messages(FITMessageNumber.record)[0], in: file)
        XCTAssertEqual(record.first { $0.name == "Left right balance" }?.value, "50% right")
        XCTAssertEqual(record.first { $0.name == "Power2" }?.value, "184")
        XCTAssertTrue(record.first { $0.name == "Power2" }?.isDeveloper ?? false)
        XCTAssertEqual(FITInspector.label(of: file.messages(FITMessageNumber.lap)[1], in: file), "2026-09-20T08:49:59Z #1")
    }

    func testCSVExport() throws {
        let csv = CSVExporter.csv(Activity(file: try Self.fixture()))
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 1201)
        XCTAssertTrue(lines[0].hasPrefix("elapsed_s,time_utc,Power (W),Heart rate (bpm),Cadence (rpm),Speed (km/h)"))
        XCTAssertTrue(lines[1].hasPrefix("0,2026-09-20T08:30:00Z,180,128,85,28.8,"))
        XCTAssertTrue(lines[0].hasSuffix("latitude,longitude"))
    }
}
