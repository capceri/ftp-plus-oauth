import Foundation

/// A field in a definition message.
public struct FITFieldDefinition: Sendable, Equatable {
    public var number: UInt8
    public var size: Int
    /// Raw base type byte as written in the file.
    public var baseTypeByte: UInt8
    /// Byte offset of the field inside the data message (after the record header).
    public var offset: Int

    /// The base type, or `.byte` when the definition is malformed (unknown type, or a size that
    /// isn't a whole number of values), so the bytes are kept but never interpreted.
    public var baseType: FITBaseType {
        guard let type = FITBaseType(definitionByte: baseTypeByte), size % type.size == 0, size > 0 else { return .byte }
        return type
    }

    /// Number of values (FIT arrays are fields whose size is a multiple of the base type size).
    public var count: Int { baseType == .string ? 1 : size / baseType.size }
}

/// A developer field in a definition message.
public struct FITDeveloperFieldDefinition: Sendable, Equatable {
    public var number: UInt8
    public var size: Int
    public var developerIndex: UInt8
    public var offset: Int

    public var key: FITDeveloperFieldKey { FITDeveloperFieldKey(developerIndex: developerIndex, number: number) }
}

public struct FITDeveloperFieldKey: Hashable, Sendable {
    public var developerIndex: UInt8
    public var number: UInt8

    public init(developerIndex: UInt8, number: UInt8) {
        self.developerIndex = developerIndex
        self.number = number
    }
}

/// What a `field_description` message says about a developer field.
public struct FITDeveloperFieldDescription: Sendable, Equatable {
    public var key: FITDeveloperFieldKey
    public var name: String
    public var units: String
    public var baseType: FITBaseType
    public var scale: Double
    public var offset: Double
    /// The native field this developer field mirrors, if any (e.g. a second power source).
    public var nativeMessage: UInt16?
    public var nativeField: UInt8?
    /// Application ID (16 bytes) of the Connect IQ app or developer that defined it, as hex.
    public var applicationID: String?
}

/// The layout of a data message, as given by a definition message.
public struct FITDefinition: Sendable {
    public var globalNumber: UInt16
    public var isBigEndian: Bool
    public var fields: [FITFieldDefinition]
    public var developerFields: [FITDeveloperFieldDefinition]
    /// Size of the data message without its header byte.
    public var dataSize: Int
    var fieldIndex: [UInt8: Int]

    init(globalNumber: UInt16, isBigEndian: Bool, fields: [FITFieldDefinition], developerFields: [FITDeveloperFieldDefinition]) {
        self.globalNumber = globalNumber
        self.isBigEndian = isBigEndian
        self.fields = fields
        self.developerFields = developerFields
        dataSize = fields.reduce(0) { $0 + $1.size } + developerFields.reduce(0) { $0 + $1.size }
        var index: [UInt8: Int] = [:]
        for (i, field) in fields.enumerated() where index[field.number] == nil {
            index[field.number] = i
        }
        fieldIndex = index
    }

    public func field(_ number: UInt8) -> FITFieldDefinition? {
        fieldIndex[number].map { fields[$0] }
    }
}

/// One data message. Field values are read from the file's bytes on demand.
public struct FITMessage: Sendable {
    /// Index into `FITFile.definitions`.
    public var definition: Int
    public var globalNumber: UInt16
    /// Offset of the first byte after the record header.
    public var dataOffset: Int
    /// The message's timestamp (its own field 253, or the one implied by a compressed timestamp
    /// header), in FIT time (seconds since 1989-12-31 UTC).
    public var timestamp: UInt32?
    /// Which file in a chained FIT file the message belongs to.
    public var segment: Int
}

/// One FIT file inside the data (FIT allows several to be chained back to back).
public struct FITSegment: Sendable {
    public var start: Int
    public var headerSize: Int
    public var protocolVersion: UInt8
    public var profileVersion: UInt16
    /// Offset of the first byte after the last record (where the file CRC is).
    public var recordsEnd: Int
    /// Whether the 2-byte CRC after the records exists (truncated files lack it).
    public var hasCRC: Bool
    public var crcIsValid: Bool
}

public struct FITDecodingError: LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }

    public init(_ message: String) { self.message = message }
}

/// A decoded FIT file: every message, the raw bytes, and accessors for field values.
///
/// Decoding is lossless: messages point into `bytes`, so a field can be rewritten in place
/// (see `FITAdjuster`) and the rest of the file stays exactly as it was.
public struct FITFile: Sendable {
    public static let fitEpochOffset: Int64 = 631_065_600

    public let bytes: [UInt8]
    public let segments: [FITSegment]
    public let definitions: [FITDefinition]
    public let messages: [FITMessage]
    public let developerFields: [FITDeveloperFieldKey: FITDeveloperFieldDescription]
    /// Problems that didn't stop decoding (bad CRC, truncated file, …).
    public let warnings: [String]

    public init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    public init(bytes: [UInt8]) throws {
        var decoder = Decoder(bytes: bytes)
        try decoder.decode()
        self.bytes = bytes
        segments = decoder.segments
        definitions = decoder.definitions
        messages = decoder.messages
        warnings = decoder.warnings
        developerFields = FITFile.developerFieldDescriptions(bytes: bytes, definitions: decoder.definitions,
                                                            messages: decoder.messages)
    }

    public static func unixTime(_ fitTimestamp: UInt32) -> Int64 {
        Int64(fitTimestamp) + fitEpochOffset
    }

    public static func date(_ fitTimestamp: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(unixTime(fitTimestamp)))
    }

    // MARK: - Reading values

    public func definition(of message: FITMessage) -> FITDefinition {
        definitions[message.definition]
    }

    public func messages(_ global: UInt16) -> [FITMessage] {
        messages.filter { $0.globalNumber == global }
    }

    /// The field's raw (unscaled) value, or the first element of an array. Nil when absent or invalid.
    public func rawValue(_ number: UInt8, in message: FITMessage) -> Double? {
        let definition = definitions[message.definition]
        guard let field = definition.field(number), field.baseType != .string else { return nil }
        return field.baseType.read(bytes, at: message.dataOffset + field.offset, bigEndian: definition.isBigEndian)
    }

    /// All raw values of an array field (one element for ordinary fields).
    public func rawValues(_ number: UInt8, in message: FITMessage) -> [Double?] {
        let definition = definitions[message.definition]
        guard let field = definition.field(number) else { return [] }
        return rawValues(field, in: message, bigEndian: definition.isBigEndian)
    }

    func rawValues(_ field: FITFieldDefinition, in message: FITMessage, bigEndian: Bool) -> [Double?] {
        let type = field.baseType
        guard type != .string else { return [] }
        return (0..<field.count).map {
            type.read(bytes, at: message.dataOffset + field.offset + $0 * type.size, bigEndian: bigEndian)
        }
    }

    /// The value in real units, using the profile's scale and offset.
    public func value(_ number: UInt8, in message: FITMessage) -> Double? {
        guard let raw = rawValue(number, in: message) else { return nil }
        guard let profile = FITProfile.field(message: message.globalNumber, number: number) else { return raw }
        return raw / profile.scale - profile.offset
    }

    /// The value in real units, looked up by profile field name (e.g. "avg_power").
    public func value(named name: String, in message: FITMessage) -> Double? {
        guard let number = FITProfile.fieldNumber(message: message.globalNumber, name: name) else { return nil }
        return value(number, in: message)
    }

    public func string(_ number: UInt8, in message: FITMessage) -> String? {
        let definition = definitions[message.definition]
        guard let field = definition.field(number), field.baseType == .string || field.baseType == .byte else { return nil }
        return FITFile.string(bytes, from: message.dataOffset + field.offset, size: field.size)
    }

    public func string(named name: String, in message: FITMessage) -> String? {
        guard let number = FITProfile.fieldNumber(message: message.globalNumber, name: name) else { return nil }
        return string(number, in: message)
    }

    /// A developer field's value in real units.
    public func developerValue(_ key: FITDeveloperFieldKey, in message: FITMessage) -> Double? {
        let definition = definitions[message.definition]
        guard let field = definition.developerFields.first(where: { $0.key == key }),
              let description = developerFields[key], description.baseType.isNumeric,
              field.size >= description.baseType.size,
              let raw = description.baseType.read(bytes, at: message.dataOffset + field.offset,
                                                  bigEndian: definition.isBigEndian) else { return nil }
        return raw / description.scale - description.offset
    }

    static func string(_ bytes: [UInt8], from offset: Int, size: Int) -> String? {
        var slice = bytes[offset..<(offset + size)]
        if let end = slice.firstIndex(of: 0) { slice = slice[..<end] }
        guard !slice.isEmpty else { return nil }
        return String(decoding: slice, as: UTF8.self)
    }

    // MARK: - Developer fields

    private static func developerFieldDescriptions(bytes: [UInt8], definitions: [FITDefinition],
                                                   messages: [FITMessage]) -> [FITDeveloperFieldKey: FITDeveloperFieldDescription] {
        func raw(_ message: FITMessage, _ number: UInt8) -> Double? {
            let definition = definitions[message.definition]
            guard let field = definition.field(number) else { return nil }
            return field.baseType.read(bytes, at: message.dataOffset + field.offset, bigEndian: definition.isBigEndian)
        }
        func text(_ message: FITMessage, _ number: UInt8) -> String? {
            let definition = definitions[message.definition]
            guard let field = definition.field(number) else { return nil }
            return string(bytes, from: message.dataOffset + field.offset, size: field.size)
        }

        var applications: [UInt8: String] = [:]
        for message in messages where message.globalNumber == FITMessageNumber.developerDataID {
            guard let index = raw(message, 3) else { continue }
            let definition = definitions[message.definition]
            if let field = definition.field(1), field.size == 16 {
                let start = message.dataOffset + field.offset
                applications[UInt8(index)] = bytes[start..<(start + 16)].map { String(format: "%02x", $0) }.joined()
            }
        }

        var result: [FITDeveloperFieldKey: FITDeveloperFieldDescription] = [:]
        for message in messages where message.globalNumber == FITMessageNumber.fieldDescription {
            guard let index = raw(message, 0), let number = raw(message, 1), let typeByte = raw(message, 2),
                  let baseType = FITBaseType(definitionByte: UInt8(typeByte)) else { continue }
            let key = FITDeveloperFieldKey(developerIndex: UInt8(index), number: UInt8(number))
            let scale = raw(message, 6).flatMap { $0 > 0 ? $0 : nil } ?? 1
            result[key] = FITDeveloperFieldDescription(
                key: key,
                name: text(message, 3) ?? "Developer field \(Int(number))",
                units: text(message, 8) ?? "",
                baseType: baseType,
                scale: scale,
                offset: raw(message, 7) ?? 0,
                nativeMessage: raw(message, 14).map { UInt16($0) },
                nativeField: raw(message, 15).map { UInt8($0) },
                applicationID: applications[UInt8(index)])
        }
        return result
    }
}

// MARK: - Decoder

private struct Decoder {
    let bytes: [UInt8]
    var segments: [FITSegment] = []
    var definitions: [FITDefinition] = []
    var messages: [FITMessage] = []
    var warnings: [String] = []

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func isHeader(_ bytes: [UInt8], at start: Int) -> Bool {
        guard start + 12 <= bytes.count, bytes[start] >= 12 else { return false }
        return Array(bytes[(start + 8)..<(start + 12)]) == Array(".FIT".utf8)
    }

    mutating func decode() throws {
        guard Decoder.isHeader(bytes, at: 0) else {
            throw FITDecodingError("This isn't a FIT file (the “.FIT” signature is missing).")
        }
        var start = 0
        while Decoder.isHeader(bytes, at: start) {
            let next = decodeSegment(at: start)
            guard let next, next < bytes.count else { break }
            start = next
        }
        if messages.isEmpty {
            throw FITDecodingError("The FIT file contains no data.")
        }
    }

    /// Decodes one FIT file starting at `start`. Returns where the next chained file would start,
    /// or nil if decoding had to stop early.
    mutating func decodeSegment(at start: Int) -> Int? {
        let segmentIndex = segments.count
        let headerSize = Int(bytes[start])
        let dataSize = Int(FITBaseType.readBits(bytes, at: start + 4, count: 4, bigEndian: false))
        let recordsStart = start + headerSize
        var recordsEnd = recordsStart + dataSize
        var stoppedEarly = false

        if headerSize >= 14 && start + 14 <= bytes.count {
            let stored = UInt16(FITBaseType.readBits(bytes, at: start + 12, count: 2, bigEndian: false))
            if stored != 0 && stored != FITCRC.compute(bytes[start..<(start + 12)]) {
                warnings.append("The file header's checksum is wrong.")
            }
        }
        if dataSize == 0 || recordsEnd > bytes.count {
            warnings.append("The file is incomplete (it may not have been closed properly). Everything readable was loaded.")
            recordsEnd = bytes.count
            stoppedEarly = true
        }

        var localDefinitions = [Int?](repeating: nil, count: 16)
        var lastTimestamp: UInt32?
        var position = recordsStart
        var completeEnd = recordsStart
        recordLoop: while position < recordsEnd {
            let header = bytes[position]
            position += 1

            if header & 0x40 != 0 && header & 0x80 == 0 {
                // Definition message.
                guard position + 5 <= recordsEnd else { stoppedEarly = true; break }
                let bigEndian = bytes[position + 1] == 1
                let global = UInt16(FITBaseType.readBits(bytes, at: position + 2, count: 2, bigEndian: bigEndian))
                let fieldCount = Int(bytes[position + 4])
                position += 5
                guard position + fieldCount * 3 <= recordsEnd else { stoppedEarly = true; break }
                var fields: [FITFieldDefinition] = []
                var offset = 0
                for i in 0..<fieldCount {
                    let p = position + i * 3
                    let size = Int(bytes[p + 1])
                    fields.append(FITFieldDefinition(number: bytes[p], size: size, baseTypeByte: bytes[p + 2], offset: offset))
                    offset += size
                }
                position += fieldCount * 3
                var developerFields: [FITDeveloperFieldDefinition] = []
                if header & 0x20 != 0 {
                    guard position + 1 <= recordsEnd else { stoppedEarly = true; break }
                    let count = Int(bytes[position])
                    position += 1
                    guard position + count * 3 <= recordsEnd else { stoppedEarly = true; break }
                    for i in 0..<count {
                        let p = position + i * 3
                        let size = Int(bytes[p + 1])
                        developerFields.append(FITDeveloperFieldDefinition(number: bytes[p], size: size,
                                                                           developerIndex: bytes[p + 2], offset: offset))
                        offset += size
                    }
                    position += count * 3
                }
                definitions.append(FITDefinition(globalNumber: global, isBigEndian: bigEndian,
                                                 fields: fields, developerFields: developerFields))
                localDefinitions[Int(header & 0x0F)] = definitions.count - 1
                completeEnd = position
                continue recordLoop
            }

            // Data message, with a normal or a compressed timestamp header.
            let local: Int
            var timestamp: UInt32?
            if header & 0x80 != 0 {
                local = Int((header >> 5) & 0x03)
                let offset = UInt32(header & 0x1F)
                if let last = lastTimestamp {
                    var value = (last & ~UInt32(0x1F)) + offset
                    if offset < (last & 0x1F) { value &+= 0x20 }
                    timestamp = value
                    lastTimestamp = value
                }
            } else {
                local = Int(header & 0x0F)
            }
            guard let definitionIndex = localDefinitions[local] else {
                warnings.append("The file is damaged (a message refers to a missing definition). Everything before that point was loaded.")
                stoppedEarly = true
                break
            }
            let definition = definitions[definitionIndex]
            guard position + definition.dataSize <= recordsEnd else { stoppedEarly = true; break }
            if let field = definition.field(253), field.size >= 4,
               let value = FITBaseType.uint32.read(bytes, at: position + field.offset, bigEndian: definition.isBigEndian) {
                timestamp = UInt32(value)
                lastTimestamp = timestamp
            }
            messages.append(FITMessage(definition: definitionIndex, globalNumber: definition.globalNumber,
                                       dataOffset: position, timestamp: timestamp, segment: segmentIndex))
            position += definition.dataSize
            completeEnd = position
        }

        let hasCRC = !stoppedEarly && recordsEnd + 2 <= bytes.count
        var crcIsValid = false
        if hasCRC {
            let stored = UInt16(FITBaseType.readBits(bytes, at: recordsEnd, count: 2, bigEndian: false))
            crcIsValid = stored == FITCRC.compute(bytes[start..<recordsEnd])
            if !crcIsValid {
                warnings.append("The file's checksum doesn't match its contents. It may be damaged or edited by a tool that didn't update the checksum.")
            }
        } else if stoppedEarly && !warnings.contains(where: { $0.hasPrefix("The file is") }) {
            warnings.append("The file is incomplete. Everything readable was loaded.")
        }
        segments.append(FITSegment(start: start, headerSize: headerSize, protocolVersion: bytes[start + 1],
                                   profileVersion: UInt16(FITBaseType.readBits(bytes, at: start + 2, count: 2, bigEndian: false)),
                                   recordsEnd: stoppedEarly ? completeEnd : recordsEnd, hasCRC: hasCRC, crcIsValid: crcIsValid))
        return stoppedEarly ? nil : recordsEnd + 2
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
