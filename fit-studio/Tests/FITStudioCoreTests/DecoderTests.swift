import XCTest
@testable import FITStudioCore

final class DecoderTests: XCTestCase {
    func testCRCMatchesCRC16ARC() {
        XCTAssertEqual(FITCRC.compute(Array("123456789".utf8)), 0xBB3D)
    }

    func testBaseTypesReadInvalidValuesAsMissing() {
        XCTAssertNil(FITBaseType.uint8.read([0xFF], at: 0, bigEndian: false))
        XCTAssertNil(FITBaseType.sint16.read([0xFF, 0x7F], at: 0, bigEndian: false))
        XCTAssertNil(FITBaseType.sint16.read([0x7F, 0xFF], at: 0, bigEndian: true))
        XCTAssertNil(FITBaseType.uint32z.read([0, 0, 0, 0], at: 0, bigEndian: false))
        XCTAssertNil(FITBaseType.float32.read([0xFF, 0xFF, 0xFF, 0xFF], at: 0, bigEndian: false))
        XCTAssertEqual(FITBaseType.sint16.read([0xFE, 0xFF], at: 0, bigEndian: false), -2)
        XCTAssertEqual(FITBaseType.uint16.read([0x01, 0x02], at: 0, bigEndian: true), 258)
        XCTAssertEqual(FITBaseType.uint16.read([0x01, 0x02], at: 0, bigEndian: false), 513)
    }

    func testBaseTypeWritesRoundAndClampWithoutProducingInvalidValues() {
        var bytes = [UInt8](repeating: 0, count: 8)
        FITBaseType.uint8.write(300, into: &bytes, at: 0, bigEndian: false)
        XCTAssertEqual(bytes[0], 254)
        FITBaseType.uint8.write(-5, into: &bytes, at: 0, bigEndian: false)
        XCTAssertEqual(bytes[0], 0)
        FITBaseType.uint8z.write(0.2, into: &bytes, at: 0, bigEndian: false)
        XCTAssertEqual(bytes[0], 1)
        FITBaseType.sint8.write(200, into: &bytes, at: 0, bigEndian: false)
        XCTAssertEqual(bytes[0], 126)
        FITBaseType.uint16.write(1234.6, into: &bytes, at: 0, bigEndian: true)
        XCTAssertEqual(Array(bytes[0..<2]), [0x04, 0xD3])
        FITBaseType.float32.write(37.25, into: &bytes, at: 0, bigEndian: false)
        XCTAssertEqual(FITBaseType.float32.read(bytes, at: 0, bigEndian: false), 37.25)
        for type in FITBaseType.allCases where type.isNumeric && !type.isFloat {
            var buffer = [UInt8](repeating: 0, count: 8)
            type.write(1e30, into: &buffer, at: 0, bigEndian: false)
            XCTAssertNotNil(type.read(buffer, at: 0, bigEndian: false), "\(type) wrote an invalid value")
        }
    }

    func testRejectsNonFITData() {
        XCTAssertThrowsError(try FITFile(bytes: Array("hello, this is not a FIT file".utf8)))
        XCTAssertThrowsError(try FITFile(bytes: []))
    }

    func testDecodesSimpleRide() throws {
        let file = try FITFile(bytes: TestFIT.ride(seconds: 60).file())
        XCTAssertTrue(file.warnings.isEmpty, "\(file.warnings)")
        XCTAssertEqual(file.messages(FITMessageNumber.record).count, 60)
        let first = file.messages(FITMessageNumber.record)[0]
        XCTAssertEqual(file.value(7, in: first), 200)
        XCTAssertEqual(file.value(6, in: first), 8)          // speed: raw 8000 / scale 1000
        XCTAssertEqual(file.value(named: "distance", in: first), 8)
        XCTAssertEqual(first.timestamp, UInt32(TestFIT.fitStart))
        XCTAssertTrue(file.segments[0].crcIsValid)
    }

    func testBigEndianDefinitions() throws {
        let file = try FITFile(bytes: TestFIT.ride(seconds: 10, bigEndian: true).file())
        let records = file.messages(FITMessageNumber.record)
        XCTAssertTrue(file.definition(of: records[0]).isBigEndian)
        XCTAssertEqual(file.value(7, in: records[3]), 203)
        XCTAssertEqual(file.value(6, in: records[3]), 8)
    }

    func testTwelveByteHeader() throws {
        let file = try FITFile(bytes: TestFIT.ride(seconds: 5).file(headerSize: 12))
        XCTAssertEqual(file.messages(FITMessageNumber.record).count, 5)
        XCTAssertTrue(file.warnings.isEmpty)
    }

    func testCompressedTimestamps() throws {
        var fit = TestFIT()
        fit.define(local: 0, global: FITMessageNumber.record, fields: [(253, .uint32), (7, .uint16)])
        fit.data(local: 0, 1000 + 30, 100)  // low 5 bits of 1030 are 6
        fit.define(local: 1, global: FITMessageNumber.record, fields: [(7, .uint16)])
        fit.compressed(local: 1, timeOffset: 7, 110)    // 1031
        fit.compressed(local: 1, timeOffset: 31, 120)   // 1055
        fit.compressed(local: 1, timeOffset: 2, 130)    // rolled over: 1058
        let file = try FITFile(bytes: fit.file())
        let records = file.messages(FITMessageNumber.record)
        XCTAssertEqual(records.map(\.timestamp), [1030, 1031, 1055, 1058])
        let activity = Activity(file: file)
        XCTAssertEqual(activity.times, [0, 1, 25, 28])
        XCTAssertEqual(activity.channel(.power)?.values, [100, 110, 120, 130])
    }

    func testDeveloperFields() throws {
        var fit = TestFIT()
        fit.define(local: 0, global: FITMessageNumber.developerDataID, fields: [(3, .uint8)])
        fit.data(local: 0, 0)
        fit.define(local: 1, global: FITMessageNumber.fieldDescription,
                   fields: [(0, .uint8), (1, .uint8), (2, .uint8), (3, .string), (6, .uint8), (8, .string)],
                   sizes: [3: 16, 8: 8])
        fit.data(local: 1, [.number(0), .number(5), .number(Double(FITBaseType.uint16.definitionByte)), .text("Core Temp"),
                            .number(100), .text("C")])
        fit.define(local: 2, global: FITMessageNumber.record, fields: [(253, .uint32), (7, .uint16)],
                   developer: [(number: 5, index: 0, type: .uint16)])
        fit.data(local: 2, 2000, 250, developer: [3750])
        fit.data(local: 2, 2001, 251, developer: [nil])
        let file = try FITFile(bytes: fit.file())
        let key = FITDeveloperFieldKey(developerIndex: 0, number: 5)
        XCTAssertEqual(file.developerFields[key]?.name, "Core Temp")
        XCTAssertEqual(file.developerFields[key]?.scale, 100)
        let activity = Activity(file: file)
        let channel = try XCTUnwrap(activity.channel(ChannelKey("dev:core_temp")))
        XCTAssertEqual(channel.values, [37.5, nil])
        XCTAssertEqual(channel.units, "°C")
        XCTAssertTrue(channel.isAdjustable)
    }

    func testArrayAndStringFields() throws {
        var fit = TestFIT()
        fit.define(local: 0, global: FITMessageNumber.deviceInfo, fields: [(0, .uint8), (27, .string)], sizes: [27: 12])
        fit.data(local: 0, [.number(1), .text("KICKR CORE")])
        fit.define(local: 1, global: FITMessageNumber.session, fields: [(253, .uint32), (39, .uint16)], sizes: [39: 6])
        fit.data(local: 1, 3000, 321)   // max_power_position array of 3
        let file = try FITFile(bytes: fit.file())
        let device = file.messages(FITMessageNumber.deviceInfo)[0]
        XCTAssertEqual(file.string(27, in: device), "KICKR CORE")
        let session = file.messages(FITMessageNumber.session)[0]
        XCTAssertEqual(file.rawValues(39, in: session), [321, 321, 321])
    }

    func testChainedFiles() throws {
        let first = TestFIT.ride(seconds: 3).file()
        var second = TestFIT()
        second.define(local: 0, global: FITMessageNumber.record, fields: [(253, .uint32), (7, .uint16)])
        second.data(local: 0, TestFIT.fitStart + 3, 300)
        let file = try FITFile(bytes: first + second.file())
        XCTAssertEqual(file.segments.count, 2)
        XCTAssertEqual(file.messages(FITMessageNumber.record).count, 4)
        XCTAssertEqual(file.messages.last?.segment, 1)
        XCTAssertEqual(Activity(file: file).channel(.power)?.values.last, 300)
    }

    func testTruncatedFileLoadsWithWarning() throws {
        var bytes = TestFIT.ride(seconds: 30).file()
        bytes.removeLast(25)   // CRC and part of the last messages
        let file = try FITFile(bytes: bytes)
        XCTAssertFalse(file.warnings.isEmpty)
        XCTAssertFalse(file.segments[0].hasCRC)
        XCTAssertEqual(file.messages(FITMessageNumber.record).count, 30)
    }

    func testUnclosedFileWithZeroDataSize() throws {
        let fit = TestFIT.ride(seconds: 10)
        let bytes = fit.file(declaredSize: 0, withCRC: false)
        let file = try FITFile(bytes: bytes)
        XCTAssertEqual(file.messages(FITMessageNumber.record).count, 10)
        XCTAssertFalse(file.warnings.isEmpty)
    }

    func testBadChecksumIsReported() throws {
        var bytes = TestFIT.ride(seconds: 10).file()
        bytes[bytes.count - 1] ^= 0xFF
        let file = try FITFile(bytes: bytes)
        XCTAssertFalse(file.segments[0].crcIsValid)
        XCTAssertTrue(file.warnings.contains { $0.contains("checksum") })
    }

    func testRecordsWithTheSameTimestampAreMerged() throws {
        var fit = TestFIT()
        fit.define(local: 0, global: FITMessageNumber.record, fields: [(253, .uint32), (7, .uint16)])
        fit.define(local: 1, global: FITMessageNumber.record, fields: [(253, .uint32), (3, .uint8)])
        fit.data(local: 0, 500, 200)
        fit.data(local: 1, 500, 150)
        fit.data(local: 0, 501, 210)
        fit.data(local: 1, 501, 151)
        let activity = Activity(file: try FITFile(bytes: fit.file()))
        XCTAssertEqual(activity.times, [0, 1])
        XCTAssertEqual(activity.channel(.power)?.values, [200, 210])
        XCTAssertEqual(activity.channel(.heartRate)?.values, [150, 151])
    }

    func testEnhancedFieldsArePreferredAndMerged() throws {
        var fit = TestFIT()
        fit.define(local: 0, global: FITMessageNumber.record, fields: [(253, .uint32), (6, .uint16), (73, .uint32), (2, .uint16)])
        fit.data(local: 0, 100, 5000, 5123, 2600)   // altitude raw 2600 → 2600/5 − 500 = 20 m
        fit.data(local: 0, 101, 5000, nil, 2605)
        let activity = Activity(file: try FITFile(bytes: fit.file()))
        XCTAssertEqual(activity.channel(.speed)?.values, [5.123, 5.0])
        XCTAssertEqual(activity.channel(.altitude)?.values, [20, 21])
        XCTAssertEqual(activity.channel(.speed)?.source, .native([73, 6]))
        XCTAssertEqual(activity.channels.filter { $0.name == "Speed" }.count, 1)
    }

    func testBalanceAndUndocumentedFields() throws {
        var fit = TestFIT()
        fit.define(local: 0, global: FITMessageNumber.record, fields: [(253, .uint32), (30, .uint8), (200, .uint16)])
        fit.data(local: 0, 100, Double(0x80 | 52), 77)
        let activity = Activity(file: try FITFile(bytes: fit.file()))
        let balance = try XCTUnwrap(activity.channel(.balance))
        XCTAssertEqual(balance.values, [52])
        XCTAssertFalse(balance.isAdjustable)
        let unknown = try XCTUnwrap(activity.channel(ChannelKey("field_200")))
        XCTAssertFalse(unknown.isDocumented)
        XCTAssertEqual(unknown.values, [77])
    }
}
