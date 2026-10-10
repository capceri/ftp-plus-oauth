import FITStudioCore
import SwiftUI

enum Format {
    /// "1:02:03" or "2:03".
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "–" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Short labels for power-curve durations: "5s", "1m", "20m", "1h".
    static func shortDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m\(seconds % 60)s" }
        return seconds % 3600 == 0 ? "\(seconds / 3600)h" : String(format: "%.1fh", Double(seconds) / 3600)
    }

    static func number(_ value: Double?, decimals: Int = 0) -> String {
        guard let value, value.isFinite else { return "–" }
        return value.formatted(.number.precision(.fractionLength(decimals)))
    }

    static func percent(_ value: Double?, decimals: Int = 1, signed: Bool = true) -> String {
        guard let value, value.isFinite else { return "–" }
        let text = abs(value).formatted(.number.precision(.fractionLength(decimals)))
        guard signed else { return text + "%" }
        return (value > 0 ? "+" : value < 0 ? "−" : "±") + text + "%"
    }

    /// A channel value in the user's units, with its unit symbol.
    static func value(_ value: Double?, channel: Channel, system: UnitSystem, unit: Bool = true) -> String {
        guard let value else { return "–" }
        let display = channel.displayUnit(system)
        let text = number(display.convert(value), decimals: channel.decimals(system))
        return unit && !display.symbol.isEmpty ? "\(text) \(display.symbol)" : text
    }

    static func distance(_ meters: Double?, system: UnitSystem) -> String {
        guard let meters else { return "–" }
        let unit = Quantity.distance.displayUnit(system, fallback: "")
        return "\(number(unit.convert(meters), decimals: 2)) \(unit.symbol)"
    }

    static func elevation(_ meters: Double?, system: UnitSystem) -> String {
        guard let meters else { return "–" }
        let unit = Quantity.altitude.displayUnit(system, fallback: "")
        return "\(number(unit.convert(meters))) \(unit.symbol)"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

/// Consistent colours for channels across charts.
enum ChannelStyle {
    static func color(_ key: ChannelKey) -> Color {
        switch key.rawValue {
        case "power": return .orange
        case "heart_rate": return .red
        case "cadence": return .purple
        case "speed": return .blue
        case "distance": return .teal
        case "altitude": return .green
        case "temperature": return .pink
        case "left_right_balance": return .indigo
        case "grade": return .brown
        default:
            let palette: [Color] = [.cyan, .mint, .indigo, .brown, .yellow, .teal, .pink]
            let hash = key.rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return palette[hash % palette.count]
        }
    }

    static func symbol(_ key: ChannelKey) -> String {
        switch key.rawValue {
        case "power": return "bolt.fill"
        case "heart_rate": return "heart.fill"
        case "cadence": return "arrow.triangle.2.circlepath"
        case "speed": return "speedometer"
        case "distance": return "point.topleft.down.to.point.bottomright.curvepath"
        case "altitude": return "mountain.2.fill"
        case "temperature": return "thermometer.medium"
        case "left_right_balance": return "scalemass"
        default: return key.isDeveloper ? "puzzlepiece.extension" : "waveform.path.ecg"
        }
    }

    /// Colours for compared files (reference first).
    static let fileColors: [Color] = [.blue, .orange, .green, .purple]
}

struct Tile: View {
    var title: String
    var value: String
    var unit: String = ""
    var symbol: String?
    var tint: Color = .accentColor
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title)
            } icon: {
                if let symbol { Image(systemName: symbol) }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary)
                }
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct Banner: View {
    var text: String
    var symbol: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        Label(text, systemImage: symbol)
            .foregroundStyle(Color.primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.16)))
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Placeholder shown when there's nothing to display.
struct EmptyState: View {
    var title: String
    var message: String
    var symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
