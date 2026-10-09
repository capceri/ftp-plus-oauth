import Foundation

extension SensorReading {
    /// Converts a Cycling Power Measurement (plus cadence derived from its crank data).
    public init(_ measurement: CyclingPowerMeasurement, cadence: Double?) {
        self.init(power: measurement.instantaneousPower, cadence: cadence)
        if let balance = measurement.pedalPowerBalance {
            if measurement.balanceReferenceIsLeft {
                balanceRight = 100 - balance
            } else {
                balanceUnknownSide = balance
            }
        }
    }

    public init(_ data: IndoorBikeData) {
        self.init(power: data.power, cadence: data.cadence)
    }
}

/// Collects sensor readings as they arrive and turns them into one value per sensor per second.
///
/// For each second, a metric is the mean of the readings received during that second.
/// If none arrived, the most recent reading is carried forward as long as it is no older
/// than `staleAfter` (sensors notify at roughly 1 Hz, so an occasional gap is normal);
/// after that the metric is missing, which shows up as a gap rather than a made-up zero.
public struct SecondSampler: Sendable {
    public var staleAfter: TimeInterval

    private enum Metric: Hashable, Sendable {
        case power, cadence, heartRate, balanceRight, balanceUnknownSide
    }

    private struct Key: Hashable, Sendable {
        var source: String
        var metric: Metric
    }

    private struct Channel: Sendable {
        var sum = 0.0
        var count = 0
        var lastValue = 0.0
        var lastTime = -Double.infinity
    }

    private var channels: [Key: Channel] = [:]

    public init(staleAfter: TimeInterval = 3) {
        self.staleAfter = staleAfter
    }

    /// - Parameter time: Unix time (seconds, fractional) the reading arrived.
    public mutating func add(_ reading: SensorReading, from source: String, at time: TimeInterval) {
        func add(_ metric: Metric, _ value: Double?) {
            guard let value, value.isFinite else { return }
            let key = Key(source: source, metric: metric)
            var channel = channels[key] ?? Channel()
            channel.sum += value
            channel.count += 1
            channel.lastValue = value
            channel.lastTime = time
            channels[key] = channel
        }
        add(.power, reading.power.map(Double.init))
        add(.cadence, reading.cadence)
        add(.heartRate, reading.heartRate.map(Double.init))
        add(.balanceRight, reading.balanceRight)
        add(.balanceUnknownSide, reading.balanceUnknownSide)
    }

    /// Closes the current second and returns its values.
    /// - Parameter second: the Unix second being emitted; readings older than
    ///   `second - staleAfter` are no longer carried forward.
    public mutating func flush(second: Int64) -> SecondSample {
        var values: [String: SourceValues] = [:]
        let now = Double(second)
        for (key, var channel) in channels {
            let value: Double?
            if channel.count > 0 {
                value = channel.sum / Double(channel.count)
            } else if now - channel.lastTime <= staleAfter {
                value = channel.lastValue
            } else {
                value = nil
            }
            channel.sum = 0
            channel.count = 0
            channels[key] = channel
            guard let value else { continue }
            var entry = values[key.source] ?? SourceValues()
            switch key.metric {
            case .power: entry.power = Int(value.rounded())
            case .cadence: entry.cadence = Int(value.rounded())
            case .heartRate: entry.heartRate = Int(value.rounded())
            case .balanceRight: entry.balanceRight = value
            case .balanceUnknownSide: entry.balanceUnknownSide = value
            }
            values[key.source] = entry
        }
        return SecondSample(time: second, values: values)
    }

    /// Forgets a sensor's pending readings, e.g. after it was removed.
    public mutating func remove(source: String) {
        channels = channels.filter { $0.key.source != source }
    }
}
