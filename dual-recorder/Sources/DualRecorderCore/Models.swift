import Foundation

/// What a sensor is used for. Decides how it is shown, which data is read from it
/// and how it ends up in the exported files.
public enum SensorKind: String, Codable, CaseIterable, Sendable {
    /// A standalone power meter such as Assioma pedals (Bluetooth Cycling Power Service).
    case powerMeter
    /// A smart trainer (FTMS, or Cycling Power Service on older trainers).
    case trainer
    /// A heart-rate strap or armband (Heart Rate Service).
    case heartRate

    public var measuresPower: Bool { self != .heartRate }

    public var label: String {
        switch self {
        case .powerMeter: return "Power meter"
        case .trainer: return "Trainer"
        case .heartRate: return "Heart rate"
        }
    }
}

/// Identifies a sensor that contributed data to a ride.
public struct SourceInfo: Codable, Equatable, Hashable, Sendable {
    /// CoreBluetooth peripheral identifier.
    public var id: String
    /// Display name (user nickname, or the advertised Bluetooth name).
    public var name: String
    public var kind: SensorKind

    public init(id: String, name: String, kind: SensorKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// One decoded notification from a sensor. Fields a notification doesn't carry are nil.
public struct SensorReading: Equatable, Sendable {
    public var power: Int?
    public var cadence: Double?
    public var heartRate: Int?
    /// Right pedal's share of total power in percent, when the sensor says which side it reports.
    public var balanceRight: Double?
    /// Pedal balance in percent when the sensor doesn't say which side it refers to.
    public var balanceUnknownSide: Double?

    public init(power: Int? = nil, cadence: Double? = nil, heartRate: Int? = nil,
                balanceRight: Double? = nil, balanceUnknownSide: Double? = nil) {
        self.power = power
        self.cadence = cadence
        self.heartRate = heartRate
        self.balanceRight = balanceRight
        self.balanceUnknownSide = balanceUnknownSide
    }

    public var isEmpty: Bool {
        power == nil && cadence == nil && heartRate == nil && balanceRight == nil && balanceUnknownSide == nil
    }
}

/// One sensor's values for a single second of the ride.
public struct SourceValues: Codable, Equatable, Sendable {
    public var power: Int?
    public var cadence: Int?
    public var heartRate: Int?
    public var balanceRight: Double?
    public var balanceUnknownSide: Double?

    public init(power: Int? = nil, cadence: Int? = nil, heartRate: Int? = nil,
                balanceRight: Double? = nil, balanceUnknownSide: Double? = nil) {
        self.power = power
        self.cadence = cadence
        self.heartRate = heartRate
        self.balanceRight = balanceRight
        self.balanceUnknownSide = balanceUnknownSide
    }

    public var isEmpty: Bool {
        power == nil && cadence == nil && heartRate == nil && balanceRight == nil && balanceUnknownSide == nil
    }

    // Short keys keep the crash-recovery journal small.
    enum CodingKeys: String, CodingKey {
        case power = "p", cadence = "c", heartRate = "h", balanceRight = "br", balanceUnknownSide = "bu"
    }
}

/// Everything recorded for one wall-clock second.
public struct SecondSample: Codable, Equatable, Sendable {
    /// Unix time in whole seconds.
    public var time: Int64
    /// Values keyed by `SourceInfo.id`. Sources without data that second are absent.
    public var values: [String: SourceValues]

    public init(time: Int64, values: [String: SourceValues] = [:]) {
        self.time = time
        self.values = values
    }

    enum CodingKeys: String, CodingKey {
        case time = "t", values = "v"
    }
}

/// A complete (or recovered) ride.
public struct Ride: Equatable, Sendable {
    public var startedAt: Date
    public var eventName: String
    /// Sources in the order they first delivered data.
    public var sources: [SourceInfo]
    public var samples: [SecondSample]

    public init(startedAt: Date, eventName: String, sources: [SourceInfo], samples: [SecondSample]) {
        self.startedAt = startedAt
        self.eventName = eventName
        self.sources = sources
        self.samples = samples
    }

    /// Power sources that delivered at least one power value.
    public var powerSources: [SourceInfo] {
        sources.filter { source in
            source.kind.measuresPower && samples.contains { $0.values[source.id]?.power != nil }
        }
    }

    public var heartRateSources: [SourceInfo] {
        sources.filter { $0.kind == .heartRate }
    }

    /// Heart rate for one second, taken from the first heart-rate source that has a value.
    public func heartRate(in sample: SecondSample) -> Int? {
        for source in heartRateSources {
            if let hr = sample.values[source.id]?.heartRate { return hr }
        }
        return nil
    }
}
