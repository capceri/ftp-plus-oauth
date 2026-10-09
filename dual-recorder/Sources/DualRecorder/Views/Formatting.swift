import DualRecorderCore
import SwiftUI

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func watts(_ value: Int?) -> String {
        value.map { "\($0) W" } ?? "– W"
    }

    static func percent(_ value: Double?, signed: Bool = true) -> String {
        guard let value else { return "–" }
        return String(format: signed ? "%+.1f%%" : "%.1f%%", value)
    }
}

extension SensorKind {
    var symbol: String {
        switch self {
        case .powerMeter: return "bolt.fill"
        case .trainer: return "bicycle"
        case .heartRate: return "heart.fill"
        }
    }

    var tint: Color {
        switch self {
        case .powerMeter: return .orange
        case .trainer: return .blue
        case .heartRate: return .red
        }
    }
}

extension Sensor.ConnectionState {
    var label: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Waiting for sensor…"
        case .disconnected: return "Not connected"
        }
    }

    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .secondary
        }
    }
}

/// "+2.1% vs KICKR" style description of a power comparison.
func comparisonText(_ comparison: PowerComparison?) -> String {
    guard let comparison, let diff = comparison.differencePercent else { return "–" }
    return "\(comparison.reference.name) \(Format.percent(diff)) vs \(comparison.other.name)"
}
