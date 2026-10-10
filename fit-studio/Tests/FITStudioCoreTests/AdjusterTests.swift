import XCTest
@testable import FITStudioCore

final class AdjusterTests: XCTestCase {
    private func adjust(_ file: FITFile, _ percents: [ChannelKey: Double]) throws -> (FITFile, AdjustmentReport) {
        let result = FITAdjuster.adjust(file, activity: Activity(file: file), percents: percents)
        let adjusted = try FITFile(data: result.data)
        XCTAssertTrue(adjusted.warnings.isEmpty, "\(adjusted.warnings)")
        return (adjusted, result.report)
    }

    private func values(_ file: FITFile, _ global: UInt16, _ name: String) -> [Double?] {
        file.messages(global).map { file.value(named: name, in: $0) }
    }

    func testPowerScalesRecordsAndSummaries() throws {
        let original = try FixtureTests.fixture()
        let (adjusted, report) = try adjust(original, [.power: 10])
        XCTAssertEqual(adjusted.bytes.count, original.bytes.count)
        XCTAssertTrue(adjusted.segments[0].crcIsValid)

        let before = values(original, FITMessageNumber.record, "power")
        let after = values(adjusted, FITMessageNumber.record, "power")
        XCTAssertEqual(after, before.map { $0.map { ($0 * 1.1).rounded() } })
        XCTAssertEqual(report.valuesChanged[.power], 2400)   // power + accumulated power in 1200 records

        let accumulatedBefore = values(original, FITMessageNumber.record, "accumulated_power")
        let accumulatedAfter = values(adjusted, FITMessageNumber.record, "accumulated_power")
        XCTAssertEqual(accumulatedAfter, accumulatedBefore.map { $0.map { ($0 * 1.1).rounded() } })

        for name in ["avg_power", "max_power", "normalized_power", "total_work"] {
            for global in [FITMessageNumber.lap, FITMessageNumber.session] {
                XCTAssertEqual(values(adjusted, global, name), values(original, global, name).map { $0.map { ($0 * 1.1).rounded() } }, name)
            }
        }
        let session = adjusted.messages(FITMessageNumber.session)[0]
        let originalSession = original.messages(FITMessageNumber.session)[0]
        XCTAssertEqual(try XCTUnwrap(adjusted.value(named: "intensity_factor", in: session)),
                       try XCTUnwrap(original.value(named: "intensity_factor", in: originalSession)) * 1.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(adjusted.value(named: "training_stress_score", in: session)),
                       try XCTUnwrap(original.value(named: "training_stress_score", in: originalSession)) * 1.21, accuracy: 0.1)
        // The rider's FTP setting isn't a measurement and stays put.
        XCTAssertEqual(adjusted.value(named: "threshold_power", in: session), 250)

        // Everything else is untouched.
        XCTAssertEqual(values(adjusted, FITMessageNumber.record, "heart_rate"), values(original, FITMessageNumber.record, "heart_rate"))
        XCTAssertEqual(values(adjusted, FITMessageNumber.session, "avg_heart_rate"), values(original, FITMessageNumber.session, "avg_heart_rate"))
        XCTAssertEqual(values(adjusted, FITMessageNumber.record, "position_lat"), values(original, FITMessageNumber.record, "position_lat"))
        let developer = FITDeveloperFieldKey(developerIndex: 0, number: 0)
        XCTAssertEqual(adjusted.messages(FITMessageNumber.record).map { adjusted.developerValue(developer, in: $0) },
                       original.messages(FITMessageNumber.record).map { original.developerValue(developer, in: $0) })

        // Analysis of the adjusted file agrees with the preview.
        let preview = Activity(file: original).adjusted(by: [.power: 10]).powerMetrics()
        let real = Activity(file: adjusted).powerMetrics()
        XCTAssertEqual(try XCTUnwrap(real?.average), try XCTUnwrap(preview?.average), accuracy: 0.5)
    }

    func testOnlyAdjustedBytesChange() throws {
        let original = try FixtureTests.fixture()
        let (adjusted, _) = try adjust(original, [.heartRate: -5])
        let changed = zip(original.bytes, adjusted.bytes).filter { $0 != $1 }.count
        // At most one byte per record's heart rate, a few summary bytes and the 2-byte checksum.
        XCTAssertGreaterThan(changed, 1000)
        XCTAssertLessThanOrEqual(changed, 1200 + 10 + 2)
        XCTAssertEqual(values(adjusted, FITMessageNumber.session, "max_heart_rate"),
                       values(original, FITMessageNumber.session, "max_heart_rate").map { $0.map { ($0 * 0.95).rounded() } })
    }

    func testSpeedUsesScaleAndUpdatesEnhancedSummaries() throws {
        let original = try FixtureTests.fixture()
        let (adjusted, _) = try adjust(original, [.speed: 5])
        let before = values(original, FITMessageNumber.record, "enhanced_speed")
        let after = values(adjusted, FITMessageNumber.record, "enhanced_speed")
        for (b, a) in zip(before, after) {
            XCTAssertEqual(try XCTUnwrap(a), try XCTUnwrap(b) * 1.05, accuracy: 0.0006)
        }
        XCTAssertEqual(try XCTUnwrap(values(adjusted, FITMessageNumber.session, "enhanced_avg_speed")[0]),
                       try XCTUnwrap(values(original, FITMessageNumber.session, "enhanced_avg_speed")[0]) * 1.05, accuracy: 0.001)
        // Distance is its own channel and stays put.
        XCTAssertEqual(values(adjusted, FITMessageNumber.record, "distance"), values(original, FITMessageNumber.record, "distance"))
    }

    func testAltitudeRespectsOffset() throws {
        let original = try FixtureTests.fixture()
        let (adjusted, _) = try adjust(original, [.altitude: 10])
        let before = values(original, FITMessageNumber.record, "enhanced_altitude")
        let after = values(adjusted, FITMessageNumber.record, "enhanced_altitude")
        for (b, a) in zip(before, after) {
            XCTAssertEqual(try XCTUnwrap(a), try XCTUnwrap(b) * 1.1, accuracy: 0.11)   // resolution 0.2 m
        }
        XCTAssertEqual(try XCTUnwrap(values(adjusted, FITMessageNumber.session, "enhanced_max_altitude")[0]), 155 * 1.1, accuracy: 0.11)
        XCTAssertEqual(values(adjusted, FITMessageNumber.session, "total_ascent")[0], 77)
    }

    func testDeveloperFieldAdjustment() throws {
        let original = try FixtureTests.fixture()
        let key = ChannelKey("dev:power2")
        let (adjusted, report) = try adjust(original, [key: -2.5])
        let field = FITDeveloperFieldKey(developerIndex: 0, number: 0)
        let before = original.messages(FITMessageNumber.record).map { original.developerValue(field, in: $0) }
        let after = adjusted.messages(FITMessageNumber.record).map { adjusted.developerValue(field, in: $0) }
        XCTAssertEqual(after, before.map { $0.map { ($0 * 0.975).rounded() } })
        XCTAssertEqual(report.valuesChanged[key], 1200)
        XCTAssertEqual(values(adjusted, FITMessageNumber.record, "power"), values(original, FITMessageNumber.record, "power"))
    }

    func testSeveralChannelsAtOnce() throws {
        let original = try FixtureTests.fixture()
        let (adjusted, report) = try adjust(original, [.power: -3, .cadence: 2, .heartRate: 1, .temperature: 0])
        XCTAssertEqual(Set(report.valuesChanged.keys), [.power, .cadence, .heartRate])
        XCTAssertEqual(values(adjusted, FITMessageNumber.record, "cadence"),
                       values(original, FITMessageNumber.record, "cadence").map { $0.map { ($0 * 1.02).rounded() } })
        XCTAssertEqual(values(adjusted, FITMessageNumber.record, "temperature"), values(original, FITMessageNumber.record, "temperature"))
    }

    func testNoAdjustmentKeepsTheFileIdentical() throws {
        let original = try FixtureTests.fixture()
        let result = FITAdjuster.adjust(original, activity: Activity(file: original), percents: [.power: 0])
        XCTAssertEqual([UInt8](result.data), original.bytes)
        XCTAssertEqual(result.report.totalValuesChanged, 0)
    }

    func testMissingValuesStayMissingAndValuesClamp() throws {
        let file = try FITFile(bytes: TestFIT.ride(seconds: 40, power: { $0 % 10 == 0 ? nil : 200 }).file())
        let (adjusted, _) = try adjust(file, [.power: 50, .heartRate: 100])
        let power = values(adjusted, FITMessageNumber.record, "power")
        XCTAssertNil(power[0] ?? nil)
        XCTAssertEqual(power[1], 300)
        // Heart rate is a uint8: 140–149 × 2 is clamped to 254 (255 means "no value").
        XCTAssertEqual(Set(values(adjusted, FITMessageNumber.record, "heart_rate").compactMap { $0 }), [254])
    }

    func testBigEndianFile() throws {
        let file = try FITFile(bytes: TestFIT.ride(seconds: 20, bigEndian: true).file())
        let (adjusted, _) = try adjust(file, [.power: 10, .speed: -10])
        XCTAssertEqual(values(adjusted, FITMessageNumber.record, "power")[2], 222)
        XCTAssertEqual(values(adjusted, FITMessageNumber.record, "speed")[2], 7.2)
    }

    func testFractionalCadence() throws {
        var fit = TestFIT()
        fit.define(local: 0, global: FITMessageNumber.record, fields: [(253, .uint32), (4, .uint8), (53, .uint8)])
        fit.data(local: 0, 100, 90, 64)    // 90.5 rpm
        fit.define(local: 1, global: FITMessageNumber.session, fields: [(253, .uint32), (18, .uint8), (92, .uint8)])
        fit.data(local: 1, 100, 90, 64)
        let file = try FITFile(bytes: fit.file())
        XCTAssertEqual(Activity(file: file).channel(.cadence)?.values, [90.5])
        let (adjusted, _) = try adjust(file, [.cadence: 10])
        XCTAssertEqual(Activity(file: adjusted).channel(.cadence)?.values, [99.546875])   // 99.55 → 99 + 70/128
        let session = adjusted.messages(FITMessageNumber.session)[0]
        XCTAssertEqual(adjusted.rawValue(18, in: session), 99)
        XCTAssertEqual(adjusted.rawValue(92, in: session), 70)
    }

    func testCompressedAccumulatedPowerUnwraps() throws {
        var fit = TestFIT()
        fit.define(local: 0, global: FITMessageNumber.record, fields: [(253, .uint32), (7, .uint16), (28, .uint16)])
        fit.data(local: 0, 100, 1000, 65000)
        fit.data(local: 0, 101, 1000, 464)      // wrapped: 66 000
        fit.data(local: 0, 102, 1000, 1464)     // 67 000
        let (adjusted, _) = try adjust(try FITFile(bytes: fit.file()), [.power: 10])
        // 65 000 × 1.1 = 71 500 → 5 964 after wrapping; 66 000 → 72 600 → 7 064; 67 000 → 73 700 → 8 164
        XCTAssertEqual(adjusted.messages(FITMessageNumber.record).map { adjusted.rawValue(28, in: $0) }, [5964, 7064, 8164])
    }

    func testTruncatedFileIsRepairedInTheCopy() throws {
        var bytes = TestFIT.ride(seconds: 30).file()
        bytes.removeLast(25)
        let file = try FITFile(bytes: bytes)
        let result = FITAdjuster.adjust(file, activity: Activity(file: file), percents: [.power: 5])
        XCTAssertTrue(result.report.repairedTruncatedFile)
        let repaired = try FITFile(data: result.data)
        XCTAssertTrue(repaired.warnings.isEmpty, "\(repaired.warnings)")
        XCTAssertTrue(repaired.segments[0].crcIsValid)
        XCTAssertEqual(repaired.messages(FITMessageNumber.record).count, 30)
        XCTAssertEqual(values(repaired, FITMessageNumber.record, "power")[0], 210)
    }

    func testChainedFilesGetEachChecksumUpdated() throws {
        let bytes = TestFIT.ride(seconds: 3).file() + TestFIT.ride(seconds: 4).file()
        let file = try FITFile(bytes: bytes)
        let (adjusted, _) = try adjust(file, [.power: 1])
        XCTAssertEqual(adjusted.segments.count, 2)
        XCTAssertTrue(adjusted.segments.allSatisfy(\.crcIsValid))
    }

    func testSummaryLinks() {
        let power = FITAdjuster.summaryLinks(for: .power).map(\.name)
        XCTAssertTrue(power.contains("avg_power"))
        XCTAssertTrue(power.contains("normalized_power"))
        XCTAssertFalse(power.contains("threshold_power"))
        XCTAssertTrue(FITAdjuster.summaryLinks(for: .speed).map(\.name).contains("enhanced_avg_speed"))
        XCTAssertTrue(FITAdjuster.summaryLinks(for: ChannelKey("dev:power2")).isEmpty)
        XCTAssertTrue(FITAdjuster.summaryLinks(for: ChannelKey("field_200")).isEmpty)
    }
}
