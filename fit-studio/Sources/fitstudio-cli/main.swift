import FITStudioCore
import Foundation

let usage = """
Usage:
  fitstudio info FILE                         summary, channels and file details
  fitstudio adjust IN OUT --CHANNEL PERCENT…  scale channels, e.g. --power -2.5 --heart_rate 3
                    [--all PERCENT]           (--all applies to every adjustable channel)
  fitstudio compare REFERENCE OTHER [--channel power] [--by-start] [--offset SECONDS]
                    [--auto-align] [--ignore-zeros]
  fitstudio csv FILE [OUT] [--imperial]       export records as CSV (stdout without OUT)

Channel names are the FIT field names shown by `info` (power, heart_rate, cadence, speed, …).
"""

struct CLIError: Error, CustomStringConvertible {
    var description: String
}

func load(_ path: String) throws -> (FITFile, Activity) {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let file = try FITFile(data: data)
    return (file, Activity(file: file))
}

func number(_ value: Double?, _ decimals: Int = 0) -> String {
    guard let value else { return "–" }
    return String(format: "%.\(decimals)f", value)
}

func duration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
}

/// Parses "--name value" pairs after the positional arguments.
func options(_ arguments: ArraySlice<String>) throws -> (positional: [String], values: [String: String], flags: Set<String>) {
    var positional: [String] = [], values: [String: String] = [:], flags: Set<String> = []
    var iterator = arguments.makeIterator()
    let booleanFlags: Set<String> = ["by-start", "auto-align", "ignore-zeros", "imperial"]
    while let argument = iterator.next() {
        if argument.hasPrefix("--") {
            let name = String(argument.dropFirst(2))
            if booleanFlags.contains(name) {
                flags.insert(name)
            } else {
                guard let value = iterator.next() else { throw CLIError(description: "\(argument) needs a value") }
                values[name] = value
            }
        } else {
            positional.append(argument)
        }
    }
    return (positional, values, flags)
}

func info(_ path: String) throws {
    let (file, activity) = try load(path)
    let info = activity.info
    print(URL(fileURLWithPath: path).lastPathComponent)
    print("  Created by   \(info.creator ?? "unknown")")
    print("  Sport        \(info.sport ?? "–")")
    if let date = activity.startDate { print("  Start        \(ISO8601DateFormatter().string(from: date))") }
    print("  Duration     \(duration(info.elapsedTime ?? activity.duration))")
    if let distance = info.distance ?? activity.distance() { print("  Distance     \(number(distance / 1000, 2)) km") }
    if let power = activity.powerMetrics() {
        print("  Power        avg \(number(power.average)) W · NP \(number(power.normalized)) W · max \(number(power.maximum)) W · \(number(power.work)) kJ")
    }
    print("  Laps         \(info.laps.count)")
    print("  Records      \(activity.times.count) (FIT protocol \(info.protocolVersion), profile \(info.profileVersion))")
    for warning in info.warnings { print("  Warning: \(warning)") }
    print("\nChannels (min / avg / max):")
    for channel in activity.channels {
        let stats = activity.stats(for: channel)
        let flag = channel.isAdjustable ? "" : "  (not adjustable)"
        print("  \(channel.key.rawValue.padding(toLength: 28, withPad: " ", startingAt: 0)) "
              + "\(number(stats?.minimum, 1)) / \(number(stats?.average, 1)) / \(number(stats?.maximum, 1)) \(channel.units)\(flag)")
    }
    if !info.devices.isEmpty {
        print("\nDevices:")
        for device in info.devices {
            print("  \(device.deviceIndex.map { "#\($0)" } ?? "  ") \(device.name)\(device.type.map { " (\($0))" } ?? "")")
        }
    }
    print("\nMessages: " + info.messageCounts.map { "\($0.name) \($0.count)" }.joined(separator: ", "))
    if !file.segments.allSatisfy(\.crcIsValid) { print("Checksum: not valid") }
}

func adjust(_ arguments: ArraySlice<String>) throws {
    let parsed = try options(arguments)
    guard parsed.positional.count == 2 else { throw CLIError(description: usage) }
    let (file, activity) = try load(parsed.positional[0])
    var percents: [ChannelKey: Double] = [:]
    if let all = parsed.values["all"] {
        guard let value = Double(all) else { throw CLIError(description: "--all needs a number") }
        for channel in activity.channels where channel.isAdjustable { percents[channel.key] = value }
    }
    for (name, text) in parsed.values where name != "all" {
        guard let value = Double(text) else { throw CLIError(description: "--\(name) needs a number") }
        let key = ChannelKey(name)
        guard let channel = activity.channel(key) else {
            throw CLIError(description: "No channel \"\(name)\". Channels: \(activity.channels.map(\.key.rawValue).joined(separator: ", "))")
        }
        guard channel.isAdjustable else { throw CLIError(description: "\(channel.name) can't be adjusted") }
        percents[key] = value
    }
    guard !percents.isEmpty else { throw CLIError(description: "Nothing to adjust. Give e.g. --power 5") }
    let result = FITAdjuster.adjust(file, activity: activity, percents: percents)
    try result.data.write(to: URL(fileURLWithPath: parsed.positional[1]))
    for (key, count) in result.report.valuesChanged.sorted(by: { $0.key < $1.key }) {
        print("\(key.rawValue): \(count) values × \(number(1 + (percents[key] ?? 0) / 100, 4))")
    }
    print("\(result.report.summaryValuesChanged) lap/session values updated")
    if result.report.repairedTruncatedFile { print("The original was incomplete; the copy has a valid header and checksum.") }
    print("Wrote \(parsed.positional[1])")
}

func compare(_ arguments: ArraySlice<String>) throws {
    let parsed = try options(arguments)
    guard parsed.positional.count == 2 else { throw CLIError(description: usage) }
    let (_, reference) = try load(parsed.positional[0])
    let (_, other) = try load(parsed.positional[1])
    let key = ChannelKey(parsed.values["channel"] ?? "power")
    guard let a = reference.channel(key), let b = other.channel(key) else {
        throw CLIError(description: "Both files need a \"\(key.rawValue)\" channel.")
    }
    let referenceSeries = Analysis.perSecond(a, in: reference)
    let otherSeries = Analysis.perSecond(b, in: other)
    var shift = Comparator.baseShift(reference: referenceSeries, other: otherSeries, alignByClock: !parsed.flags.contains("by-start"))
    shift += Int(parsed.values["offset"] ?? "0") ?? 0
    if parsed.flags.contains("auto-align"),
       let best = Comparator.bestShift(reference: referenceSeries.values, other: otherSeries.values, around: shift, range: 600) {
        print("Auto-aligned: other file shifted \(best.shift - shift) s (correlation \(number(best.correlation, 3)))")
        shift = best.shift
    }
    guard let result = Comparator.compare(reference: referenceSeries.values, other: otherSeries.values, shift: shift,
                                          ignoreZeros: parsed.flags.contains("ignore-zeros")) else {
        throw CLIError(description: "The files don't overlap. Try --by-start or --auto-align.")
    }
    print("Compared \(result.overlapSeconds) s of \(a.name.lowercased())")
    print("  Reference  avg \(number(result.referenceAverage, 1)) \(a.units)")
    print("  Other      avg \(number(result.otherAverage, 1)) \(b.units)  (\(number(result.differencePercent, 2))%)")
    print("  Mean abs difference \(number(result.meanAbsoluteDifference, 1)), RMS \(number(result.rmsDifference, 1)), correlation \(number(result.correlation, 3))")
    if let slope = result.slope, let intercept = result.intercept {
        print("  Fit: other ≈ \(number(slope, 3)) × reference \(intercept >= 0 ? "+" : "−") \(number(abs(intercept), 1))")
    }
    for band in result.bands {
        print("  \(number(band.lower))–\(number(band.upper)) \(a.units): \(number(band.differencePercent, 2))% over \(band.seconds) s")
    }
    if let suggestion = result.suggestedAdjustment {
        print("Suggested adjustment for the other file: \(number(suggestion, 2))%  (fitstudio adjust OTHER OUT --\(key.rawValue) \(number(suggestion, 2)))")
    }
}

func csv(_ arguments: ArraySlice<String>) throws {
    let parsed = try options(arguments)
    guard (1...2).contains(parsed.positional.count) else { throw CLIError(description: usage) }
    let (_, activity) = try load(parsed.positional[0])
    let text = CSVExporter.csv(activity, system: parsed.flags.contains("imperial") ? .imperial : .metric)
    if parsed.positional.count == 2 {
        try text.write(toFile: parsed.positional[1], atomically: true, encoding: .utf8)
    } else {
        print(text, terminator: "")
    }
}

let arguments = CommandLine.arguments.dropFirst()
do {
    switch arguments.first {
    case "info" where arguments.count == 2: try info(arguments.last!)
    case "adjust": try adjust(arguments.dropFirst())
    case "compare": try compare(arguments.dropFirst())
    case "csv": try csv(arguments.dropFirst())
    default:
        print(usage)
        exit(arguments.isEmpty || arguments.first == "help" || arguments.first == "--help" ? 0 : 2)
    }
} catch {
    let message = (error as? CLIError)?.description ?? error.localizedDescription
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
