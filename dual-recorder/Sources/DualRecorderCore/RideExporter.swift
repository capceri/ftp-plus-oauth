import Foundation

/// A FIT file ready to be written to disk.
public struct ExportFile: Equatable, Sendable {
    public var fileName: String
    public var data: Data
    /// The power source the file was made for (nil for a heart-rate-only file).
    public var source: SourceInfo?
}

/// Turns a ride into FIT files: one per power source, each including heart rate.
public enum RideExporter {
    public static func files(for ride: Ride, timeZone: TimeZone = .current) -> [ExportFile] {
        guard !ride.samples.isEmpty else { return [] }
        let heartRateDevices = ride.heartRateSources
            .filter { source in ride.samples.contains { $0.values[source.id]?.heartRate != nil } }
            .map { FITDevice(name: $0.name, kind: $0.kind) }

        let powerSources = ride.powerSources
        if powerSources.isEmpty {
            guard !heartRateDevices.isEmpty else { return [] }
            let records = ride.samples.map { FITRecord(unixTime: $0.time, heartRate: ride.heartRate(in: $0)) }
            let data = FITActivityEncoder.encode(records: records, devices: heartRateDevices, timeZone: timeZone)
            let name = ExportNaming.fileName(startedAt: ride.startedAt, eventName: ride.eventName,
                                             sourceName: "Heart Rate", timeZone: timeZone)
            return [ExportFile(fileName: name, data: data, source: nil)]
        }

        // Several sources can share a display name (e.g. two unnamed power meters); keep file names unique.
        var usedNames: Set<String> = []
        return powerSources.map { source in
            let records = ride.samples.map { sample -> FITRecord in
                let values = sample.values[source.id]
                var record = FITRecord(unixTime: sample.time, power: values?.power, cadence: values?.cadence,
                                       heartRate: ride.heartRate(in: sample))
                if let right = values?.balanceRight {
                    record.balance = right
                    record.balanceIsRight = true
                } else if let unknown = values?.balanceUnknownSide {
                    record.balance = unknown
                    record.balanceIsRight = false
                }
                return record
            }
            let devices = [FITDevice(name: source.name, kind: source.kind)] + heartRateDevices
            let data = FITActivityEncoder.encode(records: records, devices: devices, timeZone: timeZone,
                                                 serialNumber: stableSerial(for: source.id))
            var name = ExportNaming.fileName(startedAt: ride.startedAt, eventName: ride.eventName,
                                             sourceName: source.name, timeZone: timeZone)
            var counter = 2
            while usedNames.contains(name) {
                name = ExportNaming.fileName(startedAt: ride.startedAt, eventName: ride.eventName,
                                             sourceName: "\(source.name) \(counter)", timeZone: timeZone)
                counter += 1
            }
            usedNames.insert(name)
            return ExportFile(fileName: name, data: data, source: source)
        }
    }

    /// Writes the ride's FIT files into `directory` without overwriting existing files.
    /// - Returns: the URLs written.
    public static func write(_ ride: Ride, to directory: URL, timeZone: TimeZone = .current) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try files(for: ride, timeZone: timeZone).map { file in
            let url = ExportNaming.uniqueURL(directory.appendingPathComponent(file.fileName))
            try file.data.write(to: url, options: .atomic)
            return url
        }
    }

    /// A deterministic non-zero serial number per sensor, so files from the same sensor look alike.
    static func stableSerial(for id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash == 0 ? 1 : hash
    }
}

public enum ExportNaming {
    /// e.g. "2026-10-09 1830 ZRL Race - Assioma.fit"
    public static func fileName(startedAt: Date, eventName: String, sourceName: String,
                                timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: startedAt)
        let stamp = String(format: "%04d-%02d-%02d %02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0)
        var parts = [stamp]
        let event = sanitize(eventName)
        if !event.isEmpty { parts.append(event) }
        var name = parts.joined(separator: " ")
        let source = sanitize(sourceName)
        if !source.isEmpty { name += " - " + source }
        return name + ".fit"
    }

    /// Removes characters that are awkward in macOS file names and collapses whitespace.
    public static func sanitize(_ text: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = text.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var result = String(collapsed.prefix(80))
        while result.hasPrefix(".") { result.removeFirst() }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Returns `url`, or "name (2).fit", "name (3).fit"… if a file already exists there.
    public static func uniqueURL(_ url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base) (\(index))").appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
