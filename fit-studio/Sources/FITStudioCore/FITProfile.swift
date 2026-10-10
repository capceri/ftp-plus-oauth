import Foundation

/// A field as described by the FIT profile.
public struct FITProfileField: Sendable, Equatable {
    public var message: UInt16
    public var number: UInt8
    public var name: String
    /// Profile type: a base type name ("uint16") or a named type ("sport", "date_time", …).
    public var type: String
    public var baseType: String
    public var isArray: Bool
    /// Raw value = (physical value + offset) × scale.
    public var scale: Double
    public var offset: Double
    public var units: String

    /// True for plain numbers. Named types are enums, bit fields or timestamps.
    public var isQuantity: Bool { type == baseType && FITBaseType.named(type)?.isNumeric == true }
}

/// FIT message numbers used by the app.
public enum FITMessageNumber {
    public static let fileID: UInt16 = 0
    public static let deviceSettings: UInt16 = 2
    public static let userProfile: UInt16 = 3
    public static let zonesTarget: UInt16 = 7
    public static let sport: UInt16 = 12
    public static let session: UInt16 = 18
    public static let lap: UInt16 = 19
    public static let record: UInt16 = 20
    public static let event: UInt16 = 21
    public static let deviceInfo: UInt16 = 23
    public static let activity: UInt16 = 34
    public static let fileCreator: UInt16 = 49
    public static let length: UInt16 = 101
    public static let segmentLap: UInt16 = 142
    public static let fieldDescription: UInt16 = 206
    public static let developerDataID: UInt16 = 207
    public static let split: UInt16 = 312
    public static let splitSummary: UInt16 = 313
}

/// Lookups into the FIT profile (names, scales, units and enum value names), generated from the
/// Garmin FIT SDK by `scripts/generate_profile.py`.
public enum FITProfile {
    public static func messageName(_ global: UInt16) -> String? {
        tables.messageNames[global]
    }

    public static func field(message: UInt16, number: UInt8) -> FITProfileField? {
        tables.fields[message]?[number]
    }

    public static func fields(message: UInt16) -> [FITProfileField] {
        (tables.fields[message] ?? [:]).values.sorted { $0.number < $1.number }
    }

    public static func fieldNumber(message: UInt16, name: String) -> UInt8? {
        tables.fieldNumbers[message]?[name]
    }

    /// The name of an enum value, e.g. `typeValueName("sport", 2)` is "cycling".
    public static func typeValueName(_ type: String, _ value: Int) -> String? {
        tables.typeValues[type]?[value]
    }

    public static func hasType(_ type: String) -> Bool {
        tables.typeValues[type] != nil
    }

    private struct Tables {
        var messageNames: [UInt16: String] = [:]
        var fields: [UInt16: [UInt8: FITProfileField]] = [:]
        var fieldNumbers: [UInt16: [String: UInt8]] = [:]
        var typeValues: [String: [Int: String]] = [:]
    }

    private static let tables: Tables = {
        var tables = Tables()
        for line in messageRows.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2, let number = UInt16(parts[0]) else { continue }
            tables.messageNames[number] = String(parts[1])
        }
        for line in fieldRows.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 9, let message = UInt16(parts[0]), let number = UInt8(parts[1]) else { continue }
            let field = FITProfileField(message: message, number: number, name: String(parts[2]),
                                        type: String(parts[3]), baseType: String(parts[4]),
                                        isArray: parts[5] == "1", scale: Double(parts[6]) ?? 1,
                                        offset: Double(parts[7]) ?? 0, units: String(parts[8]))
            tables.fields[message, default: [:]][number] = field
            tables.fieldNumbers[message, default: [:]][field.name] = number
        }
        for line in typeRows.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, let value = Int(parts[1]) else { continue }
            tables.typeValues[String(parts[0]), default: [:]][value] = String(parts[2])
        }
        return tables
    }()
}

extension FITBaseType {
    /// The base type with a profile name such as "uint16" or "enum".
    public static func named(_ name: String) -> FITBaseType? {
        allCases.first { $0.name == name }
    }
}
