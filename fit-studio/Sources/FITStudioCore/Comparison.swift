import Foundation

/// How one file's values differ from a reference file's over the seconds both have data.
public struct ComparisonResult: Sendable, Equatable {
    public var overlapSeconds: Int
    public var referenceAverage: Double
    public var otherAverage: Double
    /// Mean of (other − reference).
    public var meanDifference: Double
    public var meanAbsoluteDifference: Double
    public var rmsDifference: Double
    /// Pearson correlation of the two series (nil when one of them is constant).
    public var correlation: Double?
    /// Least-squares fit: other ≈ slope × reference + intercept.
    public var slope: Double?
    public var intercept: Double?
    /// The same comparison split by the reference's value, lowest to highest.
    public var bands: [ComparisonBand]

    /// How much higher (positive) or lower (negative) the other file reads, in percent.
    public var differencePercent: Double? {
        referenceAverage != 0 ? (otherAverage - referenceAverage) / referenceAverage * 100 : nil
    }

    /// The adjustment to apply to the other file so its average matches the reference, in percent.
    public var suggestedAdjustment: Double? {
        otherAverage > 0 ? (referenceAverage / otherAverage - 1) * 100 : nil
    }
}

public struct ComparisonBand: Sendable, Equatable, Identifiable {
    public var lower: Double
    public var upper: Double
    public var referenceAverage: Double
    public var otherAverage: Double
    public var seconds: Int

    public var id: Double { lower }

    public var differencePercent: Double? {
        referenceAverage != 0 ? (otherAverage - referenceAverage) / referenceAverage * 100 : nil
    }
}

/// Lines up two activities' per-second series and compares them.
///
/// A shift `s` means the other file's second `i` lines up with the reference's second `i + s`.
public enum Comparator {
    /// The shift that lines files up by clock time (their timestamps), or by their starts.
    public static func baseShift(reference: PerSecondSeries, other: PerSecondSeries, alignByClock: Bool) -> Int {
        guard alignByClock, let referenceStart = reference.startUnix, let otherStart = other.startUnix else { return 0 }
        return Int(otherStart - referenceStart)
    }

    /// Whether the two files' time spans overlap at all by clock time.
    public static func overlapsByClock(reference: PerSecondSeries, other: PerSecondSeries) -> Bool {
        guard reference.startUnix != nil, other.startUnix != nil else { return false }
        let shift = baseShift(reference: reference, other: other, alignByClock: true)
        return shift < reference.values.count && shift + other.values.count > 0
    }

    /// Pairs of (reference, other) values for the seconds where both have data.
    public static func pairs(reference: [Double?], other: [Double?], shift: Int, ignoreZeros: Bool = false) -> [(reference: Double, other: Double)] {
        var result: [(Double, Double)] = []
        let start = max(0, -shift)
        let end = min(other.count, reference.count - shift)
        guard start < end else { return [] }
        result.reserveCapacity(end - start)
        for i in start..<end {
            guard let b = other[i], let a = reference[i + shift] else { continue }
            if ignoreZeros && (a == 0 || b == 0) { continue }
            result.append((a, b))
        }
        return result
    }

    public static func compare(reference: [Double?], other: [Double?], shift: Int, ignoreZeros: Bool = false,
                               bandCount: Int = 5) -> ComparisonResult? {
        let pairs = pairs(reference: reference, other: other, shift: shift, ignoreZeros: ignoreZeros)
        guard !pairs.isEmpty else { return nil }
        let n = Double(pairs.count)
        var sumA = 0.0, sumB = 0.0, sumDiff = 0.0, sumAbs = 0.0, sumSquares = 0.0
        for (a, b) in pairs {
            sumA += a
            sumB += b
            sumDiff += b - a
            sumAbs += abs(b - a)
            sumSquares += (b - a) * (b - a)
        }
        let meanA = sumA / n, meanB = sumB / n
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for (a, b) in pairs {
            covariance += (a - meanA) * (b - meanB)
            varianceA += (a - meanA) * (a - meanA)
            varianceB += (b - meanB) * (b - meanB)
        }
        let correlation = varianceA > 0 && varianceB > 0 ? covariance / (varianceA * varianceB).squareRoot() : nil
        let slope = varianceA > 0 ? covariance / varianceA : nil
        return ComparisonResult(overlapSeconds: pairs.count, referenceAverage: meanA, otherAverage: meanB,
                                meanDifference: sumDiff / n, meanAbsoluteDifference: sumAbs / n,
                                rmsDifference: (sumSquares / n).squareRoot(), correlation: correlation,
                                slope: slope, intercept: slope.map { meanB - $0 * meanA },
                                bands: bands(pairs, count: bandCount))
    }

    /// Splits the pairs into bands of equal size by the reference's value.
    static func bands(_ pairs: [(reference: Double, other: Double)], count: Int) -> [ComparisonBand] {
        let bandCount = max(1, min(count, pairs.count / 30))
        let sorted = pairs.sorted { $0.reference < $1.reference }
        var result: [ComparisonBand] = []
        for band in 0..<bandCount {
            let slice = sorted[(band * sorted.count / bandCount)..<((band + 1) * sorted.count / bandCount)]
            guard let first = slice.first, let last = slice.last else { continue }
            let n = Double(slice.count)
            result.append(ComparisonBand(lower: first.reference, upper: last.reference,
                                         referenceAverage: slice.reduce(0) { $0 + $1.reference } / n,
                                         otherAverage: slice.reduce(0) { $0 + $1.other } / n,
                                         seconds: slice.count))
        }
        return result
    }

    /// Searches `around ± range` seconds for the shift where the two series correlate best
    /// (both smoothed over `smoothing` seconds first). Useful when the clocks of two devices
    /// disagree, or to line up two separate rides.
    public static func bestShift(reference: [Double?], other: [Double?], around: Int, range: Int,
                                 smoothing: Int = 5, minimumOverlap: Int = 60) -> (shift: Int, correlation: Double)? {
        let a = Analysis.rollingAverage(reference, window: smoothing).map { $0 ?? .nan }
        let b = Analysis.rollingAverage(other, window: smoothing).map { $0 ?? .nan }
        var best: (shift: Int, correlation: Double)?
        for shift in (around - range)...(around + range) {
            let start = max(0, -shift)
            let end = min(b.count, a.count - shift)
            guard end - start >= minimumOverlap else { continue }
            var n = 0.0, sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
            for i in start..<end {
                let y = b[i], x = a[i + shift]
                guard !x.isNaN, !y.isNaN else { continue }
                n += 1
                sumA += x
                sumB += y
                sumAA += x * x
                sumBB += y * y
                sumAB += x * y
            }
            guard n >= Double(minimumOverlap) else { continue }
            let covariance = sumAB - sumA * sumB / n
            let varianceA = sumAA - sumA * sumA / n
            let varianceB = sumBB - sumB * sumB / n
            guard varianceA > 0, varianceB > 0 else { continue }
            let r = covariance / (varianceA * varianceB).squareRoot()
            if best == nil || r > best!.correlation + 1e-12 || (abs(r - best!.correlation) <= 1e-12 && abs(shift - around) < abs(best!.shift - around)) {
                best = (shift, r)
            }
        }
        return best
    }

    /// (other − reference) for each of the reference's seconds, smoothed over `smoothing` seconds.
    public static func differenceSeries(reference: [Double?], other: [Double?], shift: Int, smoothing: Int = 1,
                                        percent: Bool = false) -> [Double?] {
        var result = [Double?](repeating: nil, count: reference.count)
        for j in reference.indices {
            let i = j - shift
            guard i >= 0, i < other.count, let a = reference[j], let b = other[i] else { continue }
            if percent {
                result[j] = a > 0 ? (b - a) / a * 100 : nil
            } else {
                result[j] = b - a
            }
        }
        guard smoothing > 1 else { return result }
        if percent {
            // Smooth the two series first so short spikes near zero don't dominate.
            let a = Analysis.rollingAverage(reference, window: smoothing)
            var shifted = [Double?](repeating: nil, count: reference.count)
            for j in reference.indices where j - shift >= 0 && j - shift < other.count { shifted[j] = other[j - shift] }
            let b = Analysis.rollingAverage(shifted, window: smoothing)
            return zip(a, b).enumerated().map { j, pair in
                guard result[j] != nil, let a = pair.0, let b = pair.1, a > 0 else { return nil }
                return (b - a) / a * 100
            }
        }
        return Analysis.rollingAverage(result, window: smoothing)
    }
}
