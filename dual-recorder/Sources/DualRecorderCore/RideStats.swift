import Foundation

/// Summary statistics for one power source over a ride.
public struct SourceStats: Equatable, Sendable {
    public var source: SourceInfo
    public var averagePower: Int?
    public var normalizedPower: Int?
    public var maxPower: Int?
    public var averageCadence: Int?
    public var maxCadence: Int?
    public var averageHeartRate: Int?
    public var maxHeartRate: Int?
    /// Share of the ride's seconds that have a power value from this source (0...1).
    public var coverage: Double
}

/// How two power sources compare over the seconds where both have data.
public struct PowerComparison: Equatable, Sendable {
    public var reference: SourceInfo
    public var other: SourceInfo
    public var referenceAverage: Double
    public var otherAverage: Double
    public var overlapSeconds: Int

    /// How much higher (positive) or lower (negative) `reference` reads than `other`, in percent.
    public var differencePercent: Double? {
        otherAverage > 0 ? (referenceAverage - otherAverage) / otherAverage * 100 : nil
    }
}

public enum RideStats {
    public static func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    /// Normalized Power: 4th root of the mean of the 4th powers of the 30 s rolling average.
    /// Missing seconds count as 0 W. Returns nil for rides shorter than 30 s.
    public static func normalizedPower(_ power: [Int?]) -> Int? {
        let window = 30
        guard power.count >= window else { return nil }
        let watts = power.map { Double($0 ?? 0) }
        var rolling = watts[0..<window].reduce(0, +)
        var sum = pow(rolling / Double(window), 4)
        var count = 1
        for i in window..<watts.count {
            rolling += watts[i] - watts[i - window]
            sum += pow(rolling / Double(window), 4)
            count += 1
        }
        return Int(pow(sum / Double(count), 0.25).rounded())
    }

    public static func stats(for source: SourceInfo, in ride: Ride) -> SourceStats {
        let power = ride.samples.map { $0.values[source.id]?.power }
        let cadence = ride.samples.compactMap { $0.values[source.id]?.cadence }
        let heartRate = ride.samples.compactMap { ride.heartRate(in: $0) }
        let presentPower = power.compactMap { $0 }
        // Average cadence ignores coasting, like most head units.
        let pedalling = cadence.filter { $0 > 0 }
        return SourceStats(
            source: source,
            averagePower: average(presentPower),
            normalizedPower: normalizedPower(power),
            maxPower: presentPower.max(),
            averageCadence: average(pedalling),
            maxCadence: cadence.max(),
            averageHeartRate: average(heartRate),
            maxHeartRate: heartRate.max(),
            coverage: ride.samples.isEmpty ? 0 : Double(presentPower.count) / Double(ride.samples.count)
        )
    }

    /// Compares two sources over the given samples (seconds where both have power).
    public static func compare(_ reference: SourceInfo, with other: SourceInfo,
                               over samples: some Collection<SecondSample>) -> PowerComparison? {
        var referenceSum = 0, otherSum = 0, overlap = 0
        for sample in samples {
            guard let a = sample.values[reference.id]?.power, let b = sample.values[other.id]?.power else { continue }
            referenceSum += a
            otherSum += b
            overlap += 1
        }
        guard overlap > 0 else { return nil }
        return PowerComparison(reference: reference, other: other,
                               referenceAverage: Double(referenceSum) / Double(overlap),
                               otherAverage: Double(otherSum) / Double(overlap),
                               overlapSeconds: overlap)
    }

    /// The pair the app compares: the first power meter (e.g. pedals) against the first trainer.
    public static func comparisonPair(in sources: [SourceInfo]) -> (powerMeter: SourceInfo, trainer: SourceInfo)? {
        guard let meter = sources.first(where: { $0.kind == .powerMeter }),
              let trainer = sources.first(where: { $0.kind == .trainer }) else { return nil }
        return (meter, trainer)
    }
}

/// What the app shows after a ride is saved.
public struct RideSummary: Equatable, Sendable {
    public var startedAt: Date
    public var duration: TimeInterval
    public var eventName: String
    public var sources: [SourceStats]
    public var comparison: PowerComparison?
    public var files: [URL]

    public init(ride: Ride, files: [URL]) {
        startedAt = ride.startedAt
        if let first = ride.samples.first, let last = ride.samples.last {
            duration = TimeInterval(last.time - first.time + 1)
        } else {
            duration = 0
        }
        eventName = ride.eventName
        sources = ride.powerSources.map { RideStats.stats(for: $0, in: ride) }
        if let pair = RideStats.comparisonPair(in: ride.powerSources) {
            comparison = RideStats.compare(pair.powerMeter, with: pair.trainer, over: ride.samples)
        }
        self.files = files
    }
}
