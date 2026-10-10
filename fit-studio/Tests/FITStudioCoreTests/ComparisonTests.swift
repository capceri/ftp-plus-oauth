import XCTest
@testable import FITStudioCore

final class ComparisonTests: XCTestCase {
    private func wave(_ count: Int, scale: Double = 1, delay: Int = 0) -> [Double?] {
        (0..<count).map { i in
            let t = Double(i + delay)
            return (200 + 80 * sin(t / 23) + 40 * sin(t / 7.1) + (Int(t) % 97 < 10 ? 150 : 0)) * scale
        }
    }

    func testIdenticalSeries() throws {
        let values = wave(600)
        let result = try XCTUnwrap(Comparator.compare(reference: values, other: values, shift: 0))
        XCTAssertEqual(result.overlapSeconds, 600)
        XCTAssertEqual(result.meanDifference, 0)
        XCTAssertEqual(try XCTUnwrap(result.correlation), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.differencePercent), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.suggestedAdjustment), 0, accuracy: 1e-9)
    }

    func testProportionalDifference() throws {
        let reference = wave(1200)
        let other = wave(1200, scale: 1.05)
        let result = try XCTUnwrap(Comparator.compare(reference: reference, other: other, shift: 0))
        XCTAssertEqual(try XCTUnwrap(result.differencePercent), 5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.suggestedAdjustment), -4.7619, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(result.slope), 1.05, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.intercept), 0, accuracy: 1e-6)
        XCTAssertEqual(result.bands.count, 5)
        for band in result.bands {
            XCTAssertEqual(try XCTUnwrap(band.differencePercent), 5, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(band.lower, band.upper)
        }
        XCTAssertEqual(result.bands.map(\.seconds).reduce(0, +), 1200)
        // Applying the suggestion makes the averages match.
        let corrected = other.map { $0.map { $0 * (1 + result.suggestedAdjustment! / 100) } }
        let after = try XCTUnwrap(Comparator.compare(reference: reference, other: corrected, shift: 0))
        XCTAssertEqual(try XCTUnwrap(after.differencePercent), 0, accuracy: 1e-9)
    }

    func testShiftAndIgnoringZeros() throws {
        let reference: [Double?] = [0, 100, 200, 300, nil, 500]
        let other: [Double?] = [110, 210, 0, 510]
        // other[i] lines up with reference[i + 1].
        let pairs = Comparator.pairs(reference: reference, other: other, shift: 1)
        XCTAssertEqual(pairs.map(\.reference), [100, 200, 300])
        XCTAssertEqual(pairs.map(\.other), [110, 210, 0])
        XCTAssertEqual(Comparator.pairs(reference: reference, other: other, shift: 1, ignoreZeros: true).count, 2)
        XCTAssertTrue(Comparator.pairs(reference: reference, other: other, shift: 50).isEmpty)
        XCTAssertNil(Comparator.compare(reference: reference, other: other, shift: -50))
    }

    func testBestShiftFindsTheOffset() throws {
        let reference = wave(1800)
        let other = wave(1500, scale: 0.97, delay: 137)   // other started 137 s into the reference
        let best = try XCTUnwrap(Comparator.bestShift(reference: reference, other: other, around: 0, range: 300))
        XCTAssertEqual(best.shift, 137)
        XCTAssertGreaterThan(best.correlation, 0.99)
        let result = try XCTUnwrap(Comparator.compare(reference: reference, other: other, shift: best.shift))
        XCTAssertEqual(try XCTUnwrap(result.differencePercent), -3, accuracy: 1e-9)
    }

    func testBaseShiftByClock() {
        let a = PerSecondSeries(startUnix: 1000, values: [Double?](repeating: 1, count: 100))
        let b = PerSecondSeries(startUnix: 1030, values: [Double?](repeating: 1, count: 100))
        XCTAssertEqual(Comparator.baseShift(reference: a, other: b, alignByClock: true), 30)
        XCTAssertEqual(Comparator.baseShift(reference: a, other: b, alignByClock: false), 0)
        XCTAssertTrue(Comparator.overlapsByClock(reference: a, other: b))
        let c = PerSecondSeries(startUnix: 5000, values: [Double?](repeating: 1, count: 100))
        XCTAssertFalse(Comparator.overlapsByClock(reference: a, other: c))
    }

    func testDifferenceSeries() {
        let reference: [Double?] = [100, 200, nil, 400]
        let other: [Double?] = [110, 220, 300, 440]
        XCTAssertEqual(Comparator.differenceSeries(reference: reference, other: other, shift: 0), [10, 20, nil, 40])
        let percent = Comparator.differenceSeries(reference: reference, other: other, shift: 0, percent: true)
        XCTAssertEqual(percent.compactMap { $0 }.map { ($0 * 1000).rounded() / 1000 }, [10, 10, 10])
        XCTAssertEqual(Comparator.differenceSeries(reference: reference, other: other, shift: 1), [nil, -90, nil, -100])
    }

    /// Two files of the same ride: a power meter that reads 3% high against a trainer.
    func testComparingTwoFITFiles() throws {
        let trainer = Activity(file: try FITFile(bytes: TestFIT.ride(seconds: 300, power: { 200 + Double($0 % 13) * 5 }).file()))
        let pedals = Activity(file: try FITFile(bytes: TestFIT.ride(seconds: 300, power: { (200 + Double($0 % 13) * 5) * 1.03 }).file()))
        let a = Analysis.perSecond(try XCTUnwrap(trainer.channel(.power)), in: trainer)
        let b = Analysis.perSecond(try XCTUnwrap(pedals.channel(.power)), in: pedals)
        let shift = Comparator.baseShift(reference: a, other: b, alignByClock: true)
        let result = try XCTUnwrap(Comparator.compare(reference: a.values, other: b.values, shift: shift))
        XCTAssertEqual(result.overlapSeconds, 300)
        XCTAssertEqual(try XCTUnwrap(result.differencePercent), 3, accuracy: 0.1)
    }
}
