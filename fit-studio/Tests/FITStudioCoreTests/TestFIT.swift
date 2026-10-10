import Foundation
@testable import FITStudioCore

/// Builds FIT files byte by byte for tests, including layouts the app's own files never use
/// (big-endian definitions, compressed timestamps, developer fields, chained files).
struct TestFIT {
    enum Value {
        case number(Double?)
        case text(String)
    }

    private(set) var records: [UInt8] = []
    private var layouts: [UInt8: (bigEndian: Bool, fields: [(number: UInt8, size: Int, type: FITBaseType)],
                                  developer: [(number: UInt8, size: Int, index: UInt8, type: FITBaseType)])] = [:]

    mutating func define(local: UInt8, global: UInt16, bigEndian: Bool = false,
                         fields: [(UInt8, FITBaseType)], sizes: [UInt8: Int] = [:],
                         developer: [(number: UInt8, index: UInt8, type: FITBaseType)] = []) {
        let fieldList = fields.map { (number: $0.0, size: sizes[$0.0] ?? $0.1.size, type: $0.1) }
        let developerList = developer.map { (number: $0.number, size: $0.type.size, index: $0.index, type: $0.type) }
        records.append(0x40 | (developer.isEmpty ? 0 : 0x20) | local)
        records.append(0)
        records.append(bigEndian ? 1 : 0)
        var global16 = [UInt8](repeating: 0, count: 2)
        FITBaseType.writeBits(UInt64(global), into: &global16, at: 0, count: 2, bigEndian: bigEndian)
        records += global16
        records.append(UInt8(fieldList.count))
        for field in fieldList {
            records += [field.number, UInt8(field.size), field.type.definitionByte]
        }
        if !developer.isEmpty {
            records.append(UInt8(developerList.count))
            for field in developerList {
                records += [field.number, UInt8(field.size), field.index]
            }
        }
        layouts[local] = (bigEndian, fieldList, developerList)
    }

    /// A data message. Values are raw (unscaled); nil writes the type's invalid value.
    mutating func data(local: UInt8, _ values: [Value], developer: [Double?] = []) {
        records.append(local)
        appendValues(local: local, values, developer: developer)
    }

    mutating func data(local: UInt8, _ numbers: Double?..., developer: [Double?] = []) {
        data(local: local, numbers.map { .number($0) }, developer: developer)
    }

    /// A data message with a compressed timestamp header (local types 0–3 only).
    mutating func compressed(local: UInt8, timeOffset: UInt8, _ numbers: Double?...) {
        records.append(0x80 | (local << 5) | (timeOffset & 0x1F))
        appendValues(local: local, numbers.map { .number($0) }, developer: [])
    }

    private mutating func appendValues(local: UInt8, _ values: [Value], developer: [Double?]) {
        let layout = layouts[local]!
        precondition(values.count == layout.fields.count)
        for (field, value) in zip(layout.fields, values) {
            switch value {
            case .text(let text):
                var bytes = Array(text.utf8).prefix(field.size - 1)
                bytes += [UInt8](repeating: 0, count: field.size - bytes.count)
                records += bytes
            case .number(let number):
                let count = field.size / field.type.size
                for _ in 0..<count {
                    records += TestFIT.encode(number, type: field.type, bigEndian: layout.bigEndian)
                }
            }
        }
        for (field, value) in zip(layout.developer, developer) {
            records += TestFIT.encode(value, type: field.type, bigEndian: layout.bigEndian)
        }
    }

    static func encode(_ value: Double?, type: FITBaseType, bigEndian: Bool) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: type.size)
        if let value {
            type.write(value, into: &bytes, at: 0, bigEndian: bigEndian)
        } else {
            let invalid: UInt64
            switch type {
            case .sint8: invalid = 0x7F
            case .sint16: invalid = 0x7FFF
            case .sint32: invalid = 0x7FFF_FFFF
            case .sint64: invalid = 0x7FFF_FFFF_FFFF_FFFF
            case .uint8z, .uint16z, .uint32z, .uint64z, .string: invalid = 0
            default: invalid = UInt64.max
            }
            FITBaseType.writeBits(invalid, into: &bytes, at: 0, count: type.size, bigEndian: bigEndian)
        }
        return bytes
    }

    /// The complete file: header, records and CRC.
    func file(headerSize: Int = 14, declaredSize: Int? = nil, withCRC: Bool = true) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: headerSize)
        header[0] = UInt8(headerSize)
        header[1] = 0x20
        FITBaseType.writeBits(2141, into: &header, at: 2, count: 2, bigEndian: false)
        FITBaseType.writeBits(UInt64(declaredSize ?? records.count), into: &header, at: 4, count: 4, bigEndian: false)
        header.replaceSubrange(8..<12, with: Array(".FIT".utf8))
        if headerSize >= 14 {
            FITBaseType.writeBits(UInt64(FITCRC.compute(header[0..<12])), into: &header, at: 12, count: 2, bigEndian: false)
        }
        var file = header + records
        if withCRC {
            let crc = FITCRC.compute(file)
            file += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        }
        return file
    }

    static let fitStart: Double = 1_100_000_000  // FIT timestamp of the test rides (2024-11-08)

    /// A simple activity: `seconds` records of power, heart rate, cadence and speed, one lap and a session.
    static func ride(seconds: Int = 120, bigEndian: Bool = false, power: (Int) -> Double? = { 200 + Double($0 % 7) }) -> TestFIT {
        var fit = TestFIT()
        fit.define(local: 0, global: FITMessageNumber.fileID, fields: [(0, .enumeration), (1, .uint16), (2, .uint16), (4, .uint32)])
        fit.data(local: 0, 4, 255, 1, fitStart)
        fit.define(local: 1, global: FITMessageNumber.record, bigEndian: bigEndian,
                   fields: [(253, .uint32), (7, .uint16), (3, .uint8), (4, .uint8), (6, .uint16), (5, .uint32)])
        var distance = 0.0
        var watts: [Double] = []
        for i in 0..<seconds {
            distance += 8
            let p = power(i)
            if let p { watts.append(p) }
            fit.data(local: 1, fitStart + Double(i), p, 140 + Double(i % 10), 90, 8000, distance * 100)
        }
        let average = watts.isEmpty ? nil : (watts.reduce(0, +) / Double(watts.count)).rounded()
        fit.define(local: 2, global: FITMessageNumber.lap,
                   fields: [(253, .uint32), (2, .uint32), (7, .uint32), (9, .uint32), (13, .uint16), (19, .uint16), (20, .uint16), (15, .uint8)])
        fit.data(local: 2, fitStart + Double(seconds - 1), fitStart, Double(seconds) * 1000, distance * 100, 8000,
                 average, watts.max(), 144)
        fit.define(local: 3, global: FITMessageNumber.session,
                   fields: [(253, .uint32), (2, .uint32), (5, .enumeration), (7, .uint32), (9, .uint32), (20, .uint16),
                            (21, .uint16), (34, .uint16), (35, .uint16), (36, .uint16), (48, .uint32), (16, .uint8), (45, .uint16)])
        fit.data(local: 3, fitStart + Double(seconds - 1), fitStart, 2, Double(seconds) * 1000, distance * 100,
                 average, watts.max(), average, 500, 800, watts.reduce(0, +), 144, 250)
        return fit
    }
}
