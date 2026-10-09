import XCTest
@testable import DualRecorderCore

final class FITTests: XCTestCase {
    func testCRCMatchesCRC16ARC() {
        // FIT uses CRC-16/ARC; its standard check value for "123456789" is 0xBB3D.
        XCTAssertEqual(FITCRC.compute(Array("123456789".utf8)), 0xBB3D)
    }

    func testTimestampsUseFITEpoch() {
        XCTAssertEqual(FITWriter.fitTimestamp(unixSeconds: 631_065_600), 0)
        XCTAssertEqual(FITWriter.fitTimestamp(Date(timeIntervalSince1970: 631_065_660.9)), 60)
    }

    func testFileStructure() {
        let records = (0..<90).map { FITRecord(unixTime: 1_760_000_000 + Int64($0), power: 200 + $0, cadence: 90) }
        let data = [UInt8](FITActivityEncoder.encode(records: records, devices: [FITDevice(name: "ASSIOMA", kind: .powerMeter)]))

        XCTAssertEqual(data[0], 14)
        XCTAssertEqual(Array(data[8..<12]), Array(".FIT".utf8))
        let dataSize = Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24
        XCTAssertEqual(data.count, 14 + dataSize + 2)
        // A CRC over data that ends with its own CRC is 0.
        XCTAssertEqual(FITCRC.compute(data[0..<14]), 0)
        XCTAssertEqual(FITCRC.compute(data), 0)
    }

    func testBalanceEncoding() {
        XCTAssertEqual(FITActivityEncoder.encodeBalance(FITRecord(unixTime: 0, balance: 49.4, balanceIsRight: true)), 0x80 | 49)
        XCTAssertEqual(FITActivityEncoder.encodeBalance(FITRecord(unixTime: 0, balance: 52, balanceIsRight: false)), 52)
        XCTAssertNil(FITActivityEncoder.encodeBalance(FITRecord(unixTime: 0)))
    }

    func testStringFieldsAreTruncatedAndTerminated() {
        var data = Data()
        FITValue.string("Assioma Duo Pedals", size: 8).append(to: &data)
        XCTAssertEqual(Array(data), Array("Assioma".utf8) + [0])
        data = Data()
        FITValue.string("Ëë", size: 4).append(to: &data)
        XCTAssertEqual(data.count, 4)
        XCTAssertEqual(data.last, 0)
    }

    func testLocalMessageTypesAreReused() {
        var writer = FITWriter()
        for i in 0..<5 {
            writer.write(global: 20, fields: [(253, .uint32(UInt32(i))), (7, .uint16(100))])
        }
        let file = [UInt8](writer.finish())
        let body = file[14..<(file.count - 2)]
        // One definition (6 bytes + 2 fields * 3) and five data messages (1 + 4 + 2 bytes).
        XCTAssertEqual(body.count, 12 + 5 * 7)
    }

    /// Writes example files for `scripts/validate_fit.py` when FIT_OUTPUT_DIR is set (CI does this).
    func testWriteSampleFilesForExternalValidation() throws {
        guard let path = ProcessInfo.processInfo.environment["FIT_OUTPUT_DIR"] else {
            throw XCTSkip("FIT_OUTPUT_DIR not set")
        }
        let pedals = SourceInfo(id: "p", name: "ASSIOMA48023", kind: .powerMeter)
        let trainer = SourceInfo(id: "t", name: "KICKR CORE 1234", kind: .trainer)
        let strap = SourceInfo(id: "h", name: "HRM-Pro+", kind: .heartRate)
        let start: Int64 = 1_760_034_600
        let samples = (0..<3600).map { i -> SecondSample in
            var values: [String: SourceValues] = [
                "t": SourceValues(power: 200 + (i % 60), cadence: 88),
                "h": SourceValues(heartRate: 120 + i / 60),
            ]
            // Ten seconds of pedal dropout half-way through.
            if !(1800..<1810).contains(i) {
                values["p"] = SourceValues(power: 205 + (i % 60), cadence: 89, balanceRight: 49.5)
            }
            return SecondSample(time: start + Int64(i), values: values)
        }
        let ride = Ride(startedAt: Date(timeIntervalSince1970: TimeInterval(start)), eventName: "Validation Ride",
                        sources: [pedals, trainer, strap], samples: samples)
        let urls = try RideExporter.write(ride, to: URL(fileURLWithPath: path), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(urls.count, 2)
    }
}
