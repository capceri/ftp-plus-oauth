import Foundation

/// A channel resampled to one value per second.
public struct PerSecondSeries: Sendable, Equatable {
    /// Unix time of index 0 (nil when the file has no timestamps; index 0 is then the first record).
    public var startUnix: Int64?
    public var values: [Double?]

    public init(startUnix: Int64?, values: [Double?]) {
        self.startUnix = startUnix
        self.values = values
    }
}

public struct ChannelStats: Sendable, Equatable {
    public var minimum: Double
    public var maximum: Double
    public var average: Double
    /// Average of the non-zero seconds (cadence while pedalling, power while not coasting).
    public var averageNonZero: Double?
    /// Seconds with a value.
    public var seconds: Int
    /// Share of the covered time span that has values (0...1).
    public var coverage: Double
}

public struct PowerMetrics: Sendable, Equatable {
    public var average: Double
    public var normalized: Double?
    public var maximum: Double
    /// Kilojoules.
    public var work: Double
    public var seconds: Int
    /// Best average power for each duration in seconds (the power curve).
    public var curve: [CurvePoint]

    public struct CurvePoint: Sendable, Equatable, Identifiable {
        public var duration: Int
        public var watts: Double
        public var id: Int { duration }
    }

    public var variabilityIndex: Double? {
        guard let normalized, average > 0 else { return nil }
        return normalized / average
    }

    public func intensityFactor(ftp: Double) -> Double? {
        guard let normalized, ftp > 0 else { return nil }
        return normalized / ftp
    }

    public func trainingStressScore(ftp: Double) -> Double? {
        guard let normalized, let intensity = intensityFactor(ftp: ftp) else { return nil }
        return Double(seconds) * normalized * intensity / (ftp * 3600) * 100
    }
}

public struct ChartPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    /// Lines are broken between segments (gaps in the data).
    public var segment: Int

    public init(x: Double, y: Double, segment: Int) {
        self.x = x
        self.y = y
        self.segment = segment
    }
}

public enum Analysis {
    /// Standard power curve durations, in seconds.
    public static let curveDurations = [1, 5, 10, 15, 30, 60, 120, 180, 300, 600, 1200, 1800, 2700, 3600, 5400, 7200, 10800, 14400, 18000]

    /// Resamples to one value per second. Several samples in a second are averaged; a value is
    /// held for up to `maxGap` seconds when samples are sparse ("smart recording"). Longer gaps
    /// (pauses, dropouts) are nil.
    public static func perSecond(times: [Double], values: [Double?], startUnix: Int64?, maxGap: Int = 10) -> PerSecondSeries {
        guard let last = times.last, last >= 0, times.count == values.count else {
            return PerSecondSeries(startUnix: startUnix, values: [])
        }
        let count = Int(last.rounded(.down)) + 1
        var sums = [Double](repeating: 0, count: count)
        var counts = [Int](repeating: 0, count: count)
        for (time, value) in zip(times, values) {
            guard let value, time >= 0 else { continue }
            let second = min(Int(time.rounded(.down)), count - 1)
            sums[second] += value
            counts[second] += 1
        }
        var result = [Double?](repeating: nil, count: count)
        var held: Double?
        var heldAt = Int.min
        for second in 0..<count {
            if counts[second] > 0 {
                held = sums[second] / Double(counts[second])
                heldAt = second
                result[second] = held
            } else if let held, second - heldAt <= maxGap {
                result[second] = held
            }
        }
        return PerSecondSeries(startUnix: startUnix, values: result)
    }

    public static func perSecond(_ channel: Channel, in activity: Activity, maxGap: Int = 10) -> PerSecondSeries {
        perSecond(times: activity.times, values: channel.values, startUnix: activity.startUnix, maxGap: maxGap)
    }

    public static func stats(_ series: [Double?]) -> ChannelStats? {
        var minimum = Double.infinity, maximum = -Double.infinity, sum = 0.0, count = 0
        var nonZeroSum = 0.0, nonZeroCount = 0
        var first: Int?, last = 0
        for (index, value) in series.enumerated() {
            guard let value else { continue }
            if first == nil { first = index }
            last = index
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            sum += value
            count += 1
            if value != 0 {
                nonZeroSum += value
                nonZeroCount += 1
            }
        }
        guard count > 0, let first else { return nil }
        return ChannelStats(minimum: minimum, maximum: maximum, average: sum / Double(count),
                            averageNonZero: nonZeroCount > 0 ? nonZeroSum / Double(nonZeroCount) : nil,
                            seconds: count, coverage: Double(count) / Double(last - first + 1))
    }

    /// Normalized Power: fourth root of the mean fourth power of the 30 s rolling average.
    /// Seconds without data (pauses) are left out. Nil for less than 30 s of data.
    public static func normalizedPower(_ watts: [Double]) -> Double? {
        let window = 30
        guard watts.count >= window else { return nil }
        var rolling = watts[0..<window].reduce(0, +)
        var sum = pow(rolling / Double(window), 4)
        var count = 1
        for i in window..<watts.count {
            rolling += watts[i] - watts[i - window]
            sum += pow(rolling / Double(window), 4)
            count += 1
        }
        return pow(sum / Double(count), 0.25)
    }

    /// Best average over each duration (seconds without data are left out).
    public static func meanMaximal(_ values: [Double], durations: [Int] = curveDurations) -> [PowerMetrics.CurvePoint] {
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for (i, value) in values.enumerated() { prefix[i + 1] = prefix[i] + value }
        return durations.compactMap { duration in
            guard duration <= values.count else { return nil }
            var best = -Double.infinity
            for end in duration...values.count {
                best = max(best, prefix[end] - prefix[end - duration])
            }
            return PowerMetrics.CurvePoint(duration: duration, watts: best / Double(duration))
        }
    }

    public static func powerMetrics(_ series: [Double?]) -> PowerMetrics? {
        let watts = series.compactMap { $0 }
        guard !watts.isEmpty else { return nil }
        let total = watts.reduce(0, +)
        return PowerMetrics(average: total / Double(watts.count), normalized: normalizedPower(watts),
                            maximum: watts.max() ?? 0, work: total / 1000, seconds: watts.count,
                            curve: meanMaximal(watts))
    }

    /// Rolling average over `window` seconds (centred on nothing: each value averages the window
    /// ending at it). Gaps stay nil.
    public static func rollingAverage(_ series: [Double?], window: Int) -> [Double?] {
        guard window > 1 else { return series }
        var result = [Double?](repeating: nil, count: series.count)
        var sum = 0.0, count = 0
        for i in series.indices {
            if let value = series[i] { sum += value; count += 1 }
            if i >= window, let old = series[i - window] { sum -= old; count -= 1 }
            if series[i] != nil && count > 0 { result[i] = sum / Double(count) }
        }
        return result
    }

    /// Smooths irregularly spaced samples with a trailing time window, for charts.
    public static func smooth(times: [Double], values: [Double?], window: Double) -> [Double?] {
        guard window > 1 else { return values }
        var result = [Double?](repeating: nil, count: values.count)
        var start = 0
        var sum = 0.0, count = 0
        for i in values.indices {
            if let value = values[i] { sum += value; count += 1 }
            while times[start] <= times[i] - window {
                if let old = values[start] { sum -= old; count -= 1 }
                start += 1
            }
            if values[i] != nil && count > 0 { result[i] = sum / Double(count) }
        }
        return result
    }

    /// Climbing and descending, ignoring changes smaller than `threshold` metres (GPS/barometer noise).
    public static func elevationChange(_ altitude: [Double?], threshold: Double = 2) -> (ascent: Double, descent: Double) {
        var reference: Double?
        var ascent = 0.0, descent = 0.0
        for value in altitude {
            guard let value else { continue }
            guard let ref = reference else { reference = value; continue }
            if value >= ref + threshold {
                ascent += value - ref
                reference = value
            } else if value <= ref - threshold {
                descent += ref - value
                reference = value
            }
        }
        return (ascent, descent)
    }

    /// Reduces a series to at most about `maxPoints` points for drawing, keeping each bucket's
    /// minimum and maximum so peaks survive. Gaps longer than `gap` (in x units) or missing values
    /// start a new segment so lines aren't drawn across them.
    public static func chartPoints(x: [Double], y: [Double?], maxPoints: Int = 1500, gap: Double = .infinity) -> [ChartPoint] {
        precondition(x.count == y.count)
        var present: [(Double, Double, Int)] = []
        present.reserveCapacity(x.count)
        var segment = 0
        var previousX: Double?
        var lastWasNil = false
        for (xValue, yValue) in zip(x, y) {
            guard let yValue, yValue.isFinite, xValue.isFinite else { lastWasNil = true; continue }
            if let previousX, lastWasNil || xValue - previousX > gap { segment += 1 }
            present.append((xValue, yValue, segment))
            previousX = xValue
            lastWasNil = false
        }
        guard present.count > maxPoints, maxPoints >= 4, let first = present.first, let last = present.last, last.0 > first.0 else {
            return present.map { ChartPoint(x: $0.0, y: $0.1, segment: $0.2) }
        }

        let buckets = maxPoints / 2
        let width = (last.0 - first.0) / Double(buckets)
        var result: [ChartPoint] = []
        result.reserveCapacity(maxPoints + 2)
        var index = 0
        while index < present.count {
            let bucket = min(Int((present[index].0 - first.0) / width), buckets - 1)
            let currentSegment = present[index].2
            var minPoint = present[index], maxPoint = present[index]
            var end = index + 1
            while end < present.count, present[end].2 == currentSegment,
                  min(Int((present[end].0 - first.0) / width), buckets - 1) == bucket {
                if present[end].1 < minPoint.1 { minPoint = present[end] }
                if present[end].1 > maxPoint.1 { maxPoint = present[end] }
                end += 1
            }
            let pair = minPoint.0 <= maxPoint.0 ? [minPoint, maxPoint] : [maxPoint, minPoint]
            for point in pair where result.last.map({ $0.x != point.0 || $0.y != point.1 }) ?? true {
                result.append(ChartPoint(x: point.0, y: point.1, segment: point.2))
            }
            index = end
        }
        return result
    }
}

// MARK: - Activity statistics

public extension Activity {
    /// Statistics for each channel over the whole activity or a time range (seconds since start).
    func stats(for channel: Channel, in range: ClosedRange<Double>? = nil) -> ChannelStats? {
        Analysis.stats(Activity.slice(Analysis.perSecond(channel, in: self).values, range))
    }

    func powerMetrics(in range: ClosedRange<Double>? = nil) -> PowerMetrics? {
        guard let power = channel(.power) else { return nil }
        return Analysis.powerMetrics(Activity.slice(Analysis.perSecond(power, in: self).values, range))
    }

    /// Distance covered (the whole activity, or within a time range), from the distance channel.
    func distance(in range: ClosedRange<Double>? = nil) -> Double? {
        guard let channel = channel(.distance) else { return nil }
        let values = zip(times, channel.values).filter { range?.contains($0.0) ?? true }.compactMap(\.1)
        guard let first = values.first, let last = values.last else { return nil }
        return range == nil ? values.max() : last - first
    }

    func elevationChange(in range: ClosedRange<Double>? = nil) -> (ascent: Double, descent: Double)? {
        guard let channel = channel(.altitude) else { return nil }
        return Analysis.elevationChange(Activity.slice(Analysis.perSecond(channel, in: self).values, range))
    }

    private static func slice(_ values: [Double?], _ range: ClosedRange<Double>?) -> [Double?] {
        guard let range, !values.isEmpty else { return values }
        let lower = max(0, Int(range.lowerBound.rounded(.down)))
        let upper = min(values.count - 1, Int(range.upperBound.rounded(.down)))
        guard lower <= upper else { return [] }
        return Array(values[lower...upper])
    }
}
