import Foundation

/// One field of a message, formatted for the message inspector.
public struct InspectedField: Sendable, Identifiable, Equatable {
    public var id: String
    public var number: Int
    public var name: String
    public var value: String
    public var units: String
    /// The stored value(s) before scale and offset, e.g. "2600" for an altitude of 20 m.
    public var raw: String
    public var baseType: String
    public var isDeveloper: Bool
}

public enum FITInspector {
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Every field of a message, including fields with no value ("–").
    public static func fields(of message: FITMessage, in file: FITFile) -> [InspectedField] {
        let definition = file.definition(of: message)
        var result: [InspectedField] = []
        for field in definition.fields {
            let profile = FITProfile.field(message: message.globalNumber, number: field.number)
            let type = field.baseType
            var value = "–", raw = "–"
            if type == .string {
                let text = file.string(field.number, in: message)
                value = text ?? "–"
                raw = value
            } else if type == .byte && field.size > 1 {
                let start = message.dataOffset + field.offset
                let bytes = file.bytes[start..<(start + field.size)]
                if bytes.contains(where: { $0 != 0xFF }) {
                    value = bytes.map { String(format: "%02x", $0) }.joined()
                    raw = value
                }
            } else {
                let raws = file.rawValues(field.number, in: message)
                if raws.contains(where: { $0 != nil }) {
                    raw = raws.map { $0.map(format) ?? "–" }.joined(separator: ", ")
                    value = raws.map { $0.map { describe($0, profile: profile) } ?? "–" }.joined(separator: ", ")
                }
            }
            result.append(InspectedField(
                id: "f\(field.number)", number: Int(field.number),
                name: profile.map { FITNames.humanize($0.name) } ?? "Field \(field.number)",
                value: value, units: profile.map { $0.type == "date_time" ? "" : FITNames.units($0.units) } ?? "",
                raw: raw, baseType: type.name, isDeveloper: false))
        }
        for field in definition.developerFields {
            let description = file.developerFields[field.key]
            let value = file.developerValue(field.key, in: message)
            result.append(InspectedField(
                id: "d\(field.developerIndex)-\(field.number)", number: Int(field.number),
                name: description?.name ?? "Developer field \(field.number)",
                value: value.map(format) ?? "–", units: description.map { FITNames.units($0.units) } ?? "",
                raw: "–", baseType: description?.baseType.name ?? "?", isDeveloper: true))
        }
        return result
    }

    /// A short label for a message in a list: its timestamp (or message index) and a key value.
    public static func label(of message: FITMessage, in file: FITFile) -> String {
        var parts: [String] = []
        if let timestamp = message.timestamp {
            parts.append(dateFormatter.string(from: FITFile.date(timestamp)))
        }
        if let index = file.rawValue(254, in: message) {
            parts.append("#\(Int(index))")
        }
        return parts.isEmpty ? "–" : parts.joined(separator: " ")
    }

    static func describe(_ raw: Double, profile: FITProfileField?) -> String {
        guard let profile else { return format(raw) }
        if profile.type == "date_time" {
            // Values below 0x10000000 are relative times (seconds since the device was switched on).
            return raw >= 0x1000_0000 ? dateFormatter.string(from: FITFile.date(UInt32(raw))) : "\(format(raw)) s (relative)"
        }
        if profile.type == "left_right_balance" {
            let percent = Int(raw) & 0x7F
            return Int(raw) & 0x80 != 0 ? "\(percent)% right" : "\(percent)%"
        }
        if profile.type != profile.baseType, let name = FITProfile.typeValueName(profile.type, Int(raw)) {
            return FITNames.humanize(name)
        }
        return format(raw / profile.scale - profile.offset)
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}
