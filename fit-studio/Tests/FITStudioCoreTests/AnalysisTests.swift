import XCTest
@testable import FITStudioCore

final class AnalysisTests: XCTestCase {
    func testPerSecondHoldsShortGapsAndBreaksLongOnes() {
        let series = Analysis.perSecond(times: [0, 0.5, 3, 20], values: [100, 200, 300, 400], startUnix: 10, maxGap: 5)
        XCTAssertEqual(series.startUnix, 10)
        XCTAssertEqual(series.values.count, 21)
        XCTAssertEqual(series.values[0], 150)            // two samples in one second are averaged
        XCTAssertEqual(series.values[1], 150)            // held
        XCTAssertEqual(series.values[3], 300)
        XCTAssertEqual(series.values[8], 300)            // held for maxGap seconds
        XCTAssertNil(series.values[9] ?? nil)            // then missing
        XCTAssertEqual(series.values[20], 400)
    }

    func testStats() throws {
        let stats = try XCTUnwrap(Analysis.stats([nil, 0, 100, 200, nil]))
        XCTAssertEqual(stats.minimum, 0)
        XCTAssertEqual(stats.maximum, 200)
        XCTAssertEqual(stats.average, 100)
        XCTAssertEqual(stats.averageNonZero, 150)
        XCTAssertEqual(stats.seconds, 3)
        XCTAssertEqual(stats.coverage, 1)
        XCTAssertNil(Analysis.stats([nil, nil]))
    }

    func testNormalizedPower() throws {
        XCTAssertEqual(try XCTUnwrap(Analysis.normalizedPower([Double](repeating: 250, count: 600))), 250, accuracy: 1e-9)
        XCTAssertNil(Analysis.normalizedPower([Double](repeating: 250, count: 29)))
        // Alternating 1-minute blocks of 100 W and 300 W: NP is above the 200 W average.
        let blocks = (0..<1200).map { ($0 / 60) % 2 == 0 ? 100.0 : 300.0 }
        let np = try XCTUnwrap(Analysis.normalizedPower(blocks))
        XCTAssertGreaterThan(np, 230)
        XCTAssertLessThan(np, 260)
    }

    func testMeanMaximal() {
        let watts = [Double](repeating: 100, count: 100) + [Double](repeating: 400, count: 20) + [Double](repeating: 100, count: 100)
        let curve = Analysis.meanMaximal(watts, durations: [1, 20, 60, 300])
        XCTAssertEqual(curve.map(\.duration), [1, 20, 60])   // longer than the data: left out
        XCTAssertEqual(curve[0].watts, 400)
        XCTAssertEqual(curve[1].watts, 400)
        XCTAssertEqual(curve[2].watts, 200)
    }

    func testPowerMetrics() throws {
        let metrics = try XCTUnwrap(Analysis.powerMetrics([Double?](repeating: 200, count: 3600)))
        XCTAssertEqual(metrics.average, 200)
        XCTAssertEqual(metrics.work, 720)
        XCTAssertEqual(try XCTUnwrap(metrics.intensityFactor(ftp: 250)), 0.8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(metrics.trainingStressScore(ftp: 250)), 64, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(metrics.variabilityIndex), 1, accuracy: 1e-9)
    }

    func testRollingAverageAndSmoothing() {
        XCTAssertEqual(Analysis.rollingAverage([1, 2, 3, nil, 5], window: 2), [1, 1.5, 2.5, nil, 5])
        XCTAssertEqual(Analysis.smooth(times: [0, 1, 2, 10], values: [10, 20, 30, 40], window: 3), [10, 15, 20, 40])
    }

    func testElevationChangeIgnoresNoise() {
        let altitude: [Double?] = [100, 100.5, 99.8, 100.4, 105, 110, 109.5, 104, nil, 100]
        let change = Analysis.elevationChange(altitude, threshold: 2)
        XCTAssertEqual(change.ascent, 10)
        XCTAssertEqual(change.descent, 10)
    }

    func testChartPointsKeepPeaksAndBreakAtGaps() {
        let x = (0..<10_000).map(Double.init)
        var y: [Double?] = x.map { 100 + sin($0 / 50) * 10 }
        y[5000] = 999
        y[7000] = nil
        let points = Analysis.chartPoints(x: x, y: y, maxPoints: 500)
        XCTAssertLessThanOrEqual(points.count, 520)
        XCTAssertTrue(points.contains { $0.y == 999 && $0.x == 5000 })
        XCTAssertEqual(Set(points.map(\.segment)), [0, 1])
        XCTAssertEqual(points.map(\.x), points.map(\.x).sorted())

        let gapped = Analysis.chartPoints(x: [0, 1, 2, 100, 101], y: [1, 2, 3, 4, 5], gap: 10)
        XCTAssertEqual(gapped.map(\.segment), [0, 0, 0, 1, 1])
    }

    func testRangeStatsOnActivity() throws {
        let file = try FITFile(bytes: TestFIT.ride(seconds: 100, power: { $0 < 50 ? 100 : 300 }).file())
        let activity = Activity(file: file)
        XCTAssertEqual(activity.powerMetrics(in: 0...49)?.average, 100)
        XCTAssertEqual(activity.powerMetrics(in: 50...99)?.average, 300)
        XCTAssertEqual(activity.powerMetrics()?.average, 200)
        XCTAssertEqual(activity.distance(), 800)
        XCTAssertEqual(activity.distance(in: 10...19), 72)
    }

    func testAdjustedPreview() throws {
        let activity = Activity(file: try FITFile(bytes: TestFIT.ride(seconds: 10).file()))
        let preview = activity.adjusted(by: [.power: 10, .balance: 50])
        XCTAssertEqual(try XCTUnwrap(preview.channel(.power)?.values.first ?? nil), 220, accuracy: 1e-9)
        XCTAssertEqual(preview.channel(.heartRate)?.values, activity.channel(.heartRate)?.values)
    }

    func testDisplayUnits() {
        XCTAssertEqual(Quantity.speed.displayUnit(.metric, fallback: "").convert(10), 36, accuracy: 1e-9)
        XCTAssertEqual(Quantity.speed.displayUnit(.imperial, fallback: "").convert(10), 22.369, accuracy: 0.001)
        XCTAssertEqual(Quantity.temperature.displayUnit(.imperial, fallback: "").convert(20), 68, accuracy: 1e-9)
        XCTAssertEqual(Quantity.distance.displayUnit(.imperial, fallback: "").convert(1609.344), 1, accuracy: 1e-9)
        XCTAssertEqual(Quantity.other.displayUnit(.imperial, fallback: "W").symbol, "W")
    }

    func testNames() {
        XCTAssertEqual(FITNames.humanize("indoor_cycling"), "Indoor cycling")
        XCTAssertEqual(FITNames.productDisplayName("edge_1040"), "Edge 1040")
        XCTAssertEqual(FITNames.productDisplayName("fr965"), "FR965")
        XCTAssertEqual(FITNames.productDisplayName("hrm_pro_plus"), "HRM Pro Plus")
        XCTAssertEqual(FITNames.manufacturer(32), "Wahoo")
        XCTAssertEqual(FITNames.manufacturer(23), "Suunto")
        XCTAssertEqual(FITNames.sport(2, subSport: 6), "Cycling · Indoor cycling")
        XCTAssertEqual(FITNames.sport(1, subSport: 0), "Running")
    }
}
