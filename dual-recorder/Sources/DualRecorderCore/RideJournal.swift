import Foundation

/// Crash-safe log of a ride in progress, written as JSON Lines while recording.
///
/// If the app quits unexpectedly (crash, power loss, forced restart) the journal is still on
/// disk and the ride can be rebuilt and exported on the next launch.
public enum RideJournal {
    public static let fileExtension = "ridejournal"

    struct Header: Codable, Equatable {
        var version: Int
        var startedAt: Double
        var eventName: String
    }

    /// Exactly one property is set per line.
    struct Line: Codable {
        var header: Header?
        var source: SourceInfo?
        var sample: SecondSample?
        var eventName: String?
    }

    static func encode(_ line: Line) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = (try? encoder.encode(line)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Rebuilds a ride from journal contents. Lines that can't be decoded (for example a
    /// half-written last line after a crash) are skipped.
    public static func decode(_ data: Data) -> Ride? {
        let decoder = JSONDecoder()
        var header: Header?
        var sources: [SourceInfo] = []
        var samples: [SecondSample] = []
        var eventName: String?
        for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let line = try? decoder.decode(Line.self, from: Data(lineData)) else { continue }
            if let h = line.header { header = h }
            if let s = line.source {
                if let index = sources.firstIndex(where: { $0.id == s.id }) {
                    sources[index] = s
                } else {
                    sources.append(s)
                }
            }
            if let sample = line.sample { samples.append(sample) }
            if let name = line.eventName { eventName = name }
        }
        guard let header else { return nil }
        return Ride(startedAt: Date(timeIntervalSince1970: header.startedAt),
                    eventName: eventName ?? header.eventName,
                    sources: sources, samples: samples)
    }

    public static func read(from url: URL) -> Ride? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }
}

/// Appends journal lines to a file, one write per line so little is lost on a crash.
public final class RideJournalWriter {
    public let url: URL
    private let handle: FileHandle

    public init(url: URL, startedAt: Date, eventName: String) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        write(.init(header: .init(version: 1, startedAt: startedAt.timeIntervalSince1970, eventName: eventName)))
    }

    public func add(source: SourceInfo) {
        write(.init(source: source))
    }

    public func add(sample: SecondSample) {
        write(.init(sample: sample))
    }

    public func update(eventName: String) {
        write(.init(eventName: eventName))
    }

    private func write(_ line: RideJournal.Line) {
        // A failed write must never stop the recording; the in-memory ride is still complete.
        try? handle.write(contentsOf: RideJournal.encode(line))
    }

    public func close() {
        try? handle.synchronize()
        try? handle.close()
    }

    /// Closes and deletes the journal (after the ride was exported).
    public func discard() {
        close()
        try? FileManager.default.removeItem(at: url)
    }
}
