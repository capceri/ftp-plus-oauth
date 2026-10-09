import XCTest
@testable import DualRecorderCore

final class SamplerTests: XCTestCase {
    func testAveragesReadingsWithinASecond() {
        var sampler = SecondSampler()
        sampler.add(SensorReading(power: 200, cadence: 90), from: "pm", at: 100.1)
        sampler.add(SensorReading(power: 300, cadence: 92), from: "pm", at: 100.6)
        sampler.add(SensorReading(heartRate: 150), from: "hr", at: 100.5)
        let sample = sampler.flush(second: 100)
        XCTAssertEqual(sample.time, 100)
        XCTAssertEqual(sample.values["pm"], SourceValues(power: 250, cadence: 91))
        XCTAssertEqual(sample.values["hr"], SourceValues(heartRate: 150))
    }

    func testCarriesLastValueForwardUntilStale() {
        var sampler = SecondSampler(staleAfter: 3)
        sampler.add(SensorReading(power: 180), from: "pm", at: 100.2)
        XCTAssertEqual(sampler.flush(second: 100).values["pm"]?.power, 180)
        XCTAssertEqual(sampler.flush(second: 101).values["pm"]?.power, 180)
        XCTAssertEqual(sampler.flush(second: 103).values["pm"]?.power, 180)
        XCTAssertNil(sampler.flush(second: 104).values["pm"])
    }

    func testZeroPowerIsRecordedNotDropped() {
        var sampler = SecondSampler()
        sampler.add(SensorReading(power: 0, cadence: 0), from: "pm", at: 50.5)
        XCTAssertEqual(sampler.flush(second: 50).values["pm"], SourceValues(power: 0, cadence: 0))
    }

    func testRemoveSource() {
        var sampler = SecondSampler()
        sampler.add(SensorReading(power: 100), from: "a", at: 1)
        sampler.add(SensorReading(power: 200), from: "b", at: 1)
        sampler.remove(source: "a")
        XCTAssertEqual(Set(sampler.flush(second: 1).values.keys), ["b"])
    }
}

final class StatsTests: XCTestCase {
    let pedals = SourceInfo(id: "p", name: "Assioma", kind: .powerMeter)
    let trainer = SourceInfo(id: "t", name: "KICKR", kind: .trainer)
    let strap = SourceInfo(id: "h", name: "HRM", kind: .heartRate)

    func testNormalizedPower() {
        XCTAssertNil(RideStats.normalizedPower(Array(repeating: 200, count: 29)))
        XCTAssertEqual(RideStats.normalizedPower(Array(repeating: 200, count: 60)), 200)
        // Alternating 1-minute blocks of 100 W and 300 W: NP is above the 200 W average.
        let blocks = (0..<600).map { ($0 / 60) % 2 == 0 ? 100 : 300 }
        let np = RideStats.normalizedPower(blocks)!
        XCTAssertGreaterThan(np, 230)
        XCTAssertLessThan(np, 260)
    }

    func testStatsAndComparison() throws {
        let samples = (0..<60).map { (i: Int) -> SecondSample in
            let values: [String: SourceValues] = [
                "p": SourceValues(power: 210, cadence: i < 50 ? 90 : 0),
                "t": SourceValues(power: 200, cadence: 89),
                "h": SourceValues(heartRate: 140 + i % 2),
            ]
            return SecondSample(time: Int64(1000 + i), values: values)
        }
        let ride = Ride(startedAt: Date(timeIntervalSince1970: 1000), eventName: "",
                        sources: [pedals, trainer, strap], samples: samples)
        let stats = RideStats.stats(for: pedals, in: ride)
        XCTAssertEqual(stats.averagePower, 210)
        XCTAssertEqual(stats.normalizedPower, 210)
        XCTAssertEqual(stats.maxPower, 210)
        XCTAssertEqual(stats.averageCadence, 90, "coasting seconds don't count towards average cadence")
        XCTAssertEqual(stats.maxHeartRate, 141)
        XCTAssertEqual(stats.coverage, 1.0)

        let summary = RideSummary(ride: ride, files: [])
        XCTAssertEqual(summary.duration, 60)
        XCTAssertEqual(summary.sources.count, 2)
        let comparison = try XCTUnwrap(summary.comparison)
        XCTAssertEqual(comparison.reference, pedals)
        XCTAssertEqual(comparison.differencePercent!, 5, accuracy: 0.001)
        XCTAssertEqual(comparison.overlapSeconds, 60)
    }

    func testCoverageReflectsDropouts() {
        let samples = (0..<10).map { (i: Int) -> SecondSample in
            let values: [String: SourceValues] = i < 5 ? ["p": SourceValues(power: 100)] : [:]
            return SecondSample(time: Int64(i), values: values)
        }
        let ride = Ride(startedAt: Date(), eventName: "", sources: [pedals], samples: samples)
        XCTAssertEqual(RideStats.stats(for: pedals, in: ride).coverage, 0.5)
    }
}

final class JournalTests: XCTestCase {
    func testRoundTripSurvivesTruncatedLastLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ride.\(RideJournal.fileExtension)")
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let source = SourceInfo(id: "abc", name: "Assioma", kind: .powerMeter)

        let writer = try RideJournalWriter(url: url, startedAt: start, eventName: "Race")
        writer.add(source: source)
        let samples = (0..<3).map { (i: Int) -> SecondSample in
            let values: [String: SourceValues] = ["abc": SourceValues(power: 200 + i, cadence: 90, balanceRight: 49.5)]
            return SecondSample(time: 1_760_000_001 + Int64(i), values: values)
        }
        samples.forEach(writer.add(sample:))
        writer.update(eventName: "ZRL Race")
        writer.close()

        // Simulate a crash in the middle of writing a line.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"sample\":{\"t\":17600".utf8))
        try handle.close()

        let ride = try XCTUnwrap(RideJournal.read(from: url))
        XCTAssertEqual(ride.startedAt, start)
        XCTAssertEqual(ride.eventName, "ZRL Race")
        XCTAssertEqual(ride.sources, [source])
        XCTAssertEqual(ride.samples, samples)
    }

    func testJournalWithoutHeaderIsIgnored() {
        XCTAssertNil(RideJournal.decode(Data("garbage\n".utf8)))
    }
}

final class ExportTests: XCTestCase {
    let pedals = SourceInfo(id: "p", name: "Assioma", kind: .powerMeter)
    let trainer = SourceInfo(id: "t", name: "KICKR", kind: .trainer)
    let strap = SourceInfo(id: "h", name: "HRM-Pro", kind: .heartRate)
    let utc = TimeZone(identifier: "UTC")!
    let start = Date(timeIntervalSince1970: 1_760_034_600) // 2025-10-09 18:30:00 UTC

    func ride(sources: [SourceInfo], eventName: String = "ZRL Race") -> Ride {
        let values: [String: SourceValues] = [
            "p": SourceValues(power: 250, cadence: 90, balanceRight: 51),
            "t": SourceValues(power: 245, cadence: 90),
            "h": SourceValues(heartRate: 150),
        ]
        let samples = (0..<120).map { SecondSample(time: 1_760_034_600 + Int64($0), values: values) }
        return Ride(startedAt: start, eventName: eventName, sources: sources, samples: samples)
    }

    func testOneFilePerPowerSource() {
        let files = RideExporter.files(for: ride(sources: [pedals, trainer, strap]), timeZone: utc)
        XCTAssertEqual(files.map(\.fileName), [
            "2025-10-09 1830 ZRL Race - Assioma.fit",
            "2025-10-09 1830 ZRL Race - KICKR.fit",
        ])
        XCTAssertEqual(files.map(\.source), [pedals, trainer])
    }

    func testHeartRateOnlyRide() {
        let files = RideExporter.files(for: ride(sources: [strap], eventName: ""), timeZone: utc)
        XCTAssertEqual(files.map(\.fileName), ["2025-10-09 1830 - Heart Rate.fit"])
    }

    func testDuplicateSourceNamesGetDistinctFiles() {
        let other = SourceInfo(id: "t", name: "Assioma", kind: .powerMeter)
        let files = RideExporter.files(for: ride(sources: [pedals, other]), timeZone: utc)
        XCTAssertEqual(Set(files.map(\.fileName)).count, 2)
    }

    func testFileNameSanitizing() {
        XCTAssertEqual(ExportNaming.sanitize("  WTRL: TTT / Stage 3?  "), "WTRL TTT Stage 3")
        XCTAssertEqual(ExportNaming.sanitize("..hidden"), "hidden")
        XCTAssertEqual(ExportNaming.fileName(startedAt: start, eventName: " ", sourceName: "ASSIOMA12345", timeZone: utc),
                       "2025-10-09 1830 - ASSIOMA12345.fit")
    }

    func testWriteDoesNotOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let r = ride(sources: [pedals])
        let first = try RideExporter.write(r, to: directory, timeZone: utc)
        let second = try RideExporter.write(r, to: directory, timeZone: utc)
        XCTAssertEqual(first.map(\.lastPathComponent), ["2025-10-09 1830 ZRL Race - Assioma.fit"])
        XCTAssertEqual(second.map(\.lastPathComponent), ["2025-10-09 1830 ZRL Race - Assioma (2).fit"])
    }
}
