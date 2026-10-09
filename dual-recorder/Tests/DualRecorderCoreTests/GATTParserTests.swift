import XCTest
@testable import DualRecorderCore

final class GATTParserTests: XCTestCase {
    func testCyclingPowerWithBalanceAndCrankData() throws {
        // flags: balance present | balance reference left | crank data present
        let bytes: [UInt8] = [0x23, 0x00, 0xFA, 0x00, 0x66, 0x10, 0x00, 0x00, 0x04]
        let m = try XCTUnwrap(CyclingPowerMeasurement.parse(bytes))
        XCTAssertEqual(m.instantaneousPower, 250)
        XCTAssertEqual(m.pedalPowerBalance, 51)
        XCTAssertTrue(m.balanceReferenceIsLeft)
        XCTAssertEqual(m.cumulativeCrankRevolutions, 16)
        XCTAssertEqual(m.lastCrankEventTime, 1024)

        let reading = SensorReading(m, cadence: 90)
        XCTAssertEqual(reading.power, 250)
        XCTAssertEqual(reading.balanceRight, 49)
        XCTAssertNil(reading.balanceUnknownSide)
    }

    func testCyclingPowerSkipsTorqueAndWheelDataBeforeCrankData() throws {
        let bytes: [UInt8] = [0x34, 0x00, 0x2C, 0x01, 0xAA, 0xBB, 1, 2, 3, 4, 5, 6, 0x05, 0x00, 0x00, 0x08]
        let m = try XCTUnwrap(CyclingPowerMeasurement.parse(bytes))
        XCTAssertEqual(m.instantaneousPower, 300)
        XCTAssertNil(m.pedalPowerBalance)
        XCTAssertEqual(m.cumulativeCrankRevolutions, 5)
        XCTAssertEqual(m.lastCrankEventTime, 2048)
    }

    func testCyclingPowerBalanceWithUnknownSide() throws {
        let m = try XCTUnwrap(CyclingPowerMeasurement.parse([0x01, 0x00, 0x64, 0x00, 0x60]))
        XCTAssertEqual(m.pedalPowerBalance, 48)
        XCTAssertFalse(m.balanceReferenceIsLeft)
        let reading = SensorReading(m, cadence: nil)
        XCTAssertEqual(reading.balanceUnknownSide, 48)
        XCTAssertNil(reading.balanceRight)
    }

    func testCyclingPowerRejectsTruncatedData() {
        XCTAssertNil(CyclingPowerMeasurement.parse([0x20, 0x00, 0xFA]))
        XCTAssertNil(CyclingPowerMeasurement.parse([0x20, 0x00, 0xFA, 0x00, 0x10, 0x00]))
    }

    func testIndoorBikeDataWithSpeedCadenceAndPower() throws {
        let bytes: [UInt8] = [0x44, 0x00, 0xC4, 0x09, 0xB4, 0x00, 0xC8, 0x00]
        let d = try XCTUnwrap(IndoorBikeData.parse(bytes))
        XCTAssertEqual(d.speedKmh, 25)
        XCTAssertEqual(d.cadence, 90)
        XCTAssertEqual(d.power, 200)
    }

    func testIndoorBikeDataMoreDataBitMeansNoSpeed() throws {
        let d = try XCTUnwrap(IndoorBikeData.parse([0x41, 0x00, 0x96, 0x00]))
        XCTAssertNil(d.speedKmh)
        XCTAssertNil(d.cadence)
        XCTAssertEqual(d.power, 150)
    }

    func testIndoorBikeDataSkipsIntermediateFields() throws {
        // speed, avg speed, cadence, avg cadence, distance, resistance, power, avg power, energy, HR
        let flags: UInt16 = 0x0002 | 0x0004 | 0x0008 | 0x0010 | 0x0020 | 0x0040 | 0x0080 | 0x0100 | 0x0200
        var bytes: [UInt8] = [UInt8(flags & 0xFF), UInt8(flags >> 8)]
        bytes += [0x10, 0x27]          // speed
        bytes += [0x00, 0x00]          // avg speed
        bytes += [0xA0, 0x00]          // cadence 80 rpm
        bytes += [0x00, 0x00]          // avg cadence
        bytes += [0x00, 0x00, 0x00]    // distance
        bytes += [0x00, 0x00]          // resistance
        bytes += [0x2C, 0x01]          // power 300
        bytes += [0x00, 0x00]          // avg power
        bytes += [0, 0, 0, 0, 0]       // energy
        bytes += [0x8C]                // HR 140
        let d = try XCTUnwrap(IndoorBikeData.parse(bytes))
        XCTAssertEqual(d.speedKmh, 100)
        XCTAssertEqual(d.cadence, 80)
        XCTAssertEqual(d.power, 300)
        XCTAssertEqual(d.heartRate, 140)
    }

    func testHeartRate() {
        XCTAssertEqual(HeartRateMeasurement.parse([0x00, 0x48]), 72)
        XCTAssertEqual(HeartRateMeasurement.parse([0x01, 0x2C, 0x01]), 300)
        XCTAssertEqual(HeartRateMeasurement.parse([0x16, 0x9B, 0x10, 0x03]), 155)
        XCTAssertNil(HeartRateMeasurement.parse([0x01, 0x2C]))
    }

    func testControlPointResponses() throws {
        let ok = try XCTUnwrap(CyclingPowerControlPoint.parseResponse([0x20, 0x0C, 0x01, 0xF6, 0xFF]))
        XCTAssertEqual(ok.requestOpCode, 0x0C)
        XCTAssertEqual(ok.result, .success)
        XCTAssertEqual(ok.offset, -10)

        let unsupported = try XCTUnwrap(CyclingPowerControlPoint.parseResponse([0x20, 0x0C, 0x02]))
        XCTAssertEqual(unsupported.result, .opCodeNotSupported)
        XCTAssertNil(unsupported.offset)

        XCTAssertNil(CyclingPowerControlPoint.parseResponse([0x0C, 0x01]))
        XCTAssertEqual(CyclingPowerControlPoint.startOffsetCompensationRequest, [0x0C])
    }

    func testCrankCadence() {
        var calc = CrankCadenceCalculator(stoppedAfter: 3)
        XCTAssertNil(calc.update(revolutions: 100, eventTime: 1000, receivedAt: 0))
        // One revolution in 2/3 s = 90 rpm.
        XCTAssertEqual(calc.update(revolutions: 101, eventTime: 1000 + 683, receivedAt: 1)!, 90, accuracy: 0.2)
        // No new revolution yet: hold the last cadence.
        XCTAssertEqual(calc.update(revolutions: 101, eventTime: 1683, receivedAt: 2)!, 90, accuracy: 0.2)
        // Still none after 3 s: stopped.
        XCTAssertEqual(calc.update(revolutions: 101, eventTime: 1683, receivedAt: 4.1), 0)
    }

    func testCrankCadenceHandlesCounterRollover() {
        var calc = CrankCadenceCalculator()
        _ = calc.update(revolutions: 65535, eventTime: 65000, receivedAt: 0)
        // 2 revolutions over 1.5 s (1536 ticks), both counters roll over.
        let cadence = calc.update(revolutions: 1, eventTime: UInt16((65000 + 1536) % 65536), receivedAt: 1.5)
        XCTAssertEqual(cadence!, 80, accuracy: 0.01)
    }

    func testCrankCadenceIgnoresImplausibleJumps() {
        var calc = CrankCadenceCalculator()
        _ = calc.update(revolutions: 10, eventTime: 0, receivedAt: 0)
        XCTAssertEqual(calc.update(revolutions: 11, eventTime: 640, receivedAt: 1)!, 96, accuracy: 0.01)
        // 500 revolutions in 0.1 s is a counter reset, not a sprint.
        XCTAssertEqual(calc.update(revolutions: 511, eventTime: 742, receivedAt: 2)!, 96, accuracy: 0.01)
    }
}
