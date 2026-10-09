import Foundation

/// A field value in a FIT data message. `nil` payloads are written as the base type's
/// "invalid" value, which FIT decoders treat as "no data".
public enum FITValue: Equatable, Sendable {
    case enumeration(UInt8?)
    case uint8(UInt8?)
    case uint16(UInt16?)
    case uint32(UInt32?)
    /// uint32z: like uint32 but 0 is the invalid value (used for serial numbers).
    case uint32z(UInt32?)
    /// Null-terminated UTF-8 string padded to `size` bytes (terminator included).
    case string(String, size: Int)

    var baseType: UInt8 {
        switch self {
        case .enumeration: return 0x00
        case .uint8: return 0x02
        case .uint16: return 0x84
        case .uint32: return 0x86
        case .uint32z: return 0x8C
        case .string: return 0x07
        }
    }

    var size: Int {
        switch self {
        case .enumeration, .uint8: return 1
        case .uint16: return 2
        case .uint32, .uint32z: return 4
        case .string(_, let size): return size
        }
    }

    func append(to data: inout Data) {
        switch self {
        case .enumeration(let v), .uint8(let v):
            data.append(v ?? 0xFF)
        case .uint16(let v):
            data.appendLittleEndian(v ?? 0xFFFF)
        case .uint32(let v):
            data.appendLittleEndian(v ?? 0xFFFF_FFFF)
        case .uint32z(let v):
            data.appendLittleEndian(v ?? 0)
        case .string(let text, let size):
            // Truncate on a character boundary so we never emit half a UTF-8 sequence.
            var bytes: [UInt8] = []
            for character in text {
                let encoded = Array(String(character).utf8)
                if bytes.count + encoded.count > size - 1 { break }
                bytes += encoded
            }
            data.append(contentsOf: bytes)
            data.append(contentsOf: [UInt8](repeating: 0, count: size - bytes.count))
        }
    }
}

extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}

/// Low-level FIT file writer: manages definition messages, data messages, the file header and CRCs.
///
/// Messages are written with `write(global:fields:)`; a definition message is emitted automatically
/// whenever a message's layout differs from the one currently bound to its local message type.
public struct FITWriter {
    /// Seconds between the Unix epoch and the FIT epoch (1989-12-31 00:00:00 UTC).
    public static let fitEpochOffset: Int64 = 631_065_600

    public static func fitTimestamp(_ date: Date) -> UInt32 {
        fitTimestamp(unixSeconds: Int64(date.timeIntervalSince1970.rounded(.down)))
    }

    public static func fitTimestamp(unixSeconds: Int64) -> UInt32 {
        UInt32(clamping: unixSeconds - fitEpochOffset)
    }

    private struct Layout: Equatable {
        var global: UInt16
        var fields: [(number: UInt8, size: Int, baseType: UInt8)]

        static func == (lhs: Layout, rhs: Layout) -> Bool {
            lhs.global == rhs.global && lhs.fields.elementsEqual(rhs.fields) {
                $0.number == $1.number && $0.size == $1.size && $0.baseType == $1.baseType
            }
        }
    }

    private var records = Data()
    /// Local message types 0...15 and the layout currently defined for each.
    private var localLayouts: [Layout?] = Array(repeating: nil, count: 16)
    private var nextLocal = 0

    public init() {}

    public mutating func write(global: UInt16, fields: [(UInt8, FITValue)]) {
        let layout = Layout(global: global, fields: fields.map { ($0.0, $0.1.size, $0.1.baseType) })
        let local: Int
        if let existing = localLayouts.firstIndex(where: { $0 == layout }) {
            local = existing
        } else {
            local = nextLocal
            nextLocal = (nextLocal + 1) % localLayouts.count
            localLayouts[local] = layout
            writeDefinition(local: UInt8(local), layout: layout)
        }
        records.append(UInt8(local))
        for (_, value) in fields {
            value.append(to: &records)
        }
    }

    private mutating func writeDefinition(local: UInt8, layout: Layout) {
        records.append(0x40 | local)    // definition message header
        records.append(0)               // reserved
        records.append(0)               // architecture: little endian
        records.appendLittleEndian(layout.global)
        records.append(UInt8(layout.fields.count))
        for field in layout.fields {
            records.append(field.number)
            records.append(UInt8(field.size))
            records.append(field.baseType)
        }
    }

    /// The complete file: 14-byte header, records, and the trailing file CRC.
    public func finish() -> Data {
        var header = Data()
        header.append(14)                         // header size
        header.append(0x20)                       // protocol version 2.0
        header.appendLittleEndian(UInt16(2141))   // profile version 21.41
        header.appendLittleEndian(UInt32(records.count))
        header.append(contentsOf: Array(".FIT".utf8))
        header.appendLittleEndian(FITCRC.compute(header))

        var file = header
        file.append(records)
        file.appendLittleEndian(FITCRC.compute(file))
        return file
    }
}

public enum FITCRC {
    private static let table: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ]

    public static func compute<D: Sequence>(_ bytes: D, initial: UInt16 = 0) -> UInt16 where D.Element == UInt8 {
        var crc = initial
        for byte in bytes {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}
