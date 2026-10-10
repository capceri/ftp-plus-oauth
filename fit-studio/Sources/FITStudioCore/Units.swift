import Foundation

public enum UnitSystem: String, CaseIterable, Codable, Sendable {
    case metric, imperial

    public var label: String { self == .metric ? "Metric" : "Imperial" }
}

/// Converts a channel's FIT units (m/s, m, °C) to the units shown to the user.
public struct DisplayUnit: Sendable {
    public var symbol: String
    public var scale: Double
    public var offset: Double

    public func convert(_ value: Double) -> Double { value * scale + offset }
    public func convert(_ value: Double?) -> Double? { value.map(convert) }

    public static func identity(_ symbol: String) -> DisplayUnit { DisplayUnit(symbol: symbol, scale: 1, offset: 0) }
}

public extension Quantity {
    func displayUnit(_ system: UnitSystem, fallback: String) -> DisplayUnit {
        switch (self, system) {
        case (.speed, .metric): return DisplayUnit(symbol: "km/h", scale: 3.6, offset: 0)
        case (.speed, .imperial): return DisplayUnit(symbol: "mph", scale: 3600 / 1609.344, offset: 0)
        case (.distance, .metric): return DisplayUnit(symbol: "km", scale: 0.001, offset: 0)
        case (.distance, .imperial): return DisplayUnit(symbol: "mi", scale: 1 / 1609.344, offset: 0)
        case (.altitude, .metric): return .identity("m")
        case (.altitude, .imperial): return DisplayUnit(symbol: "ft", scale: 1 / 0.3048, offset: 0)
        case (.temperature, .metric): return .identity("°C")
        case (.temperature, .imperial): return DisplayUnit(symbol: "°F", scale: 1.8, offset: 32)
        case (.other, _): return .identity(fallback)
        }
    }

    /// Decimal places worth showing for a value in display units.
    func decimals(_ system: UnitSystem) -> Int {
        switch self {
        case .speed, .distance: return 1
        case .altitude, .temperature: return 0
        case .other: return 0
        }
    }
}

public extension Channel {
    func displayUnit(_ system: UnitSystem) -> DisplayUnit {
        quantity.displayUnit(system, fallback: units)
    }

    /// Decimal places for showing this channel's values.
    func decimals(_ system: UnitSystem) -> Int {
        if quantity != .other { return quantity.decimals(system) }
        switch units {
        case "W", "bpm", "rpm", "kcal", "", "s": return 0
        default: return 1
        }
    }
}

public enum CSVExporter {
    /// One row per record: elapsed seconds, UTC time, every channel (in display units), position.
    public static func csv(_ activity: Activity, system: UnitSystem = .metric) -> String {
        let formatter = ISO8601DateFormatter()
        var header = ["elapsed_s", "time_utc"]
        let units = activity.channels.map { $0.displayUnit(system) }
        for (channel, unit) in zip(activity.channels, units) {
            header.append(escape(unit.symbol.isEmpty ? channel.name : "\(channel.name) (\(unit.symbol))"))
        }
        if activity.hasPositions { header += ["latitude", "longitude"] }

        var lines = [header.joined(separator: ",")]
        lines.reserveCapacity(activity.times.count + 1)
        for row in activity.times.indices {
            let time = activity.times[row]
            var fields = [format(time, decimals: time.rounded() == time ? 0 : 3)]
            fields.append(activity.startUnix.map {
                formatter.string(from: Date(timeIntervalSince1970: TimeInterval($0) + time))
            } ?? "")
            for (channel, unit) in zip(activity.channels, units) {
                fields.append(channel.values[row].map { format(unit.convert($0), decimals: 4) } ?? "")
            }
            if activity.hasPositions {
                let position = activity.positions[row]
                fields.append(position.map { format($0.latitude, decimals: 7) } ?? "")
                fields.append(position.map { format($0.longitude, decimals: 7) } ?? "")
            }
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func format(_ value: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    static func escape(_ text: String) -> String {
        text.contains(",") || text.contains("\"") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }
}
