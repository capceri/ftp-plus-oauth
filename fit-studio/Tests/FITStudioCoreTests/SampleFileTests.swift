import XCTest
@testable import FITStudioCore

/// Writes original and adjusted files for `scripts/validate_fit.py` when FIT_OUTPUT_DIR is set
/// (CI does this), so Garmin's FIT SDK independently checks the adjusted files.
final class SampleFileTests: XCTestCase {
    func testWriteSampleFilesForExternalValidation() throws {
        guard let path = ProcessInfo.processInfo.environment["FIT_OUTPUT_DIR"] else {
            throw XCTSkip("FIT_OUTPUT_DIR not set")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let cases: [(name: String, file: FITFile, percents: [ChannelKey: Double])] = [
            ("garmin-power-plus10", try FixtureTests.fixture(), [.power: 10]),
            ("garmin-mixed", try FixtureTests.fixture(),
             [.power: -4, .heartRate: 3, .cadence: 2.5, .speed: 5, .distance: 5, .altitude: -10, ChannelKey("dev:power2"): -4]),
            ("bigendian-power-minus3", try FITFile(bytes: TestFIT.ride(seconds: 600, bigEndian: true).file()), [.power: -3]),
        ]
        var manifest: [[String: Any]] = []
        for item in cases {
            let original = directory.appendingPathComponent("\(item.name).original.fit")
            let adjusted = directory.appendingPathComponent("\(item.name).adjusted.fit")
            try Data(item.file.bytes).write(to: original)
            let result = FITAdjuster.adjust(item.file, activity: Activity(file: item.file), percents: item.percents)
            try result.data.write(to: adjusted)
            manifest.append([
                "original": original.lastPathComponent,
                "adjusted": adjusted.lastPathComponent,
                "percents": Dictionary(uniqueKeysWithValues: item.percents.map { ($0.key.rawValue, $0.value) }),
            ])
        }
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: directory.appendingPathComponent("adjustments.json"))
    }
}
