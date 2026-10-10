import Foundation

/// What an adjustment changed.
public struct AdjustmentReport: Sendable, Equatable {
    /// Record values changed, per channel.
    public var valuesChanged: [ChannelKey: Int] = [:]
    /// Lap, session and other summary values changed to stay consistent with the records.
    public var summaryValuesChanged = 0
    /// The original file was incomplete; the copy has a corrected header and checksum.
    public var repairedTruncatedFile = false

    public var totalValuesChanged: Int { valuesChanged.values.reduce(0, +) }
}

/// Scales recorded values by a percentage per channel, rewriting them in place.
///
/// Every value of an adjusted channel is multiplied by (1 + percent / 100) in real units (so
/// scale and offset are respected), rounded to the field's resolution and clamped to its valid
/// range. Missing values stay missing. Summary values derived from the records — lap and session
/// averages, maximums, totals, Normalized Power, work, TSS — are scaled to match, so the file stays
/// consistent. Everything else (positions, device info, developer data, events) is untouched, and
/// the file's checksum is recomputed.
public enum FITAdjuster {
    /// Messages whose summary fields follow the records.
    public static let summaryMessages: Set<UInt16> = [
        FITMessageNumber.lap, FITMessageNumber.session, FITMessageNumber.length,
        FITMessageNumber.segmentLap, FITMessageNumber.split, FITMessageNumber.splitSummary,
    ]

    /// Record fields that follow another channel instead of being adjusted on their own.
    public static let followers: [String: String] = ["accumulated_power": "power"]

    /// Integer fields that have a separate fractional part (1/128 units).
    static let fractionPairs: [String: String] = [
        "cadence": "fractional_cadence",
        "avg_cadence": "avg_fractional_cadence",
        "max_cadence": "max_fractional_cadence",
    ]

    /// Summary field names that follow a record channel, with the power the factor is raised to.
    public static func summaryLinks(for key: ChannelKey) -> [(name: String, exponent: Double)] {
        let name = key.rawValue
        guard !key.isDeveloper, !name.hasPrefix("field_") else { return [] }
        let base = [name, "avg_\(name)", "max_\(name)", "min_\(name)", "total_\(name)"]
        var links = (base + base.map { "enhanced_\($0)" }).map { ($0, 1.0) }
        switch name {
        case "power":
            links += [("normalized_power", 1), ("total_work", 1), ("avg_power_position", 1), ("max_power_position", 1),
                      ("intensity_factor", 1), ("training_stress_score", 2)]
        case "altitude":
            links += [("total_ascent", 1), ("total_descent", 1)]
        case "cadence":
            links += [("avg_cadence_position", 1), ("max_cadence_position", 1)]
        default:
            break
        }
        return links
    }

    private struct Target {
        var key: ChannelKey
        var factor: Double
    }

    public static func adjust(_ file: FITFile, activity: Activity, percents: [ChannelKey: Double]) -> (data: Data, report: AdjustmentReport) {
        var recordTargets: [UInt8: Target] = [:]
        var developerTargets: [FITDeveloperFieldKey: Target] = [:]
        var summaryTargets: [UInt16: [UInt8: Target]] = [:]

        for channel in activity.channels where channel.isAdjustable {
            guard let percent = percents[channel.key], percent.isFinite, percent != 0 else { continue }
            let target = Target(key: channel.key, factor: max(0, 1 + percent / 100))
            switch channel.source {
            case .native(let fields):
                for field in fields { recordTargets[field] = target }
                for (follower, leader) in followers where leader == channel.key.rawValue {
                    if let number = FITProfile.fieldNumber(message: FITMessageNumber.record, name: follower) {
                        recordTargets[number] = target
                    }
                }
                if channel.key == .power,
                   let number = FITProfile.fieldNumber(message: FITMessageNumber.record, name: "compressed_accumulated_power") {
                    recordTargets[number] = target
                }
                for message in summaryMessages {
                    for link in summaryLinks(for: channel.key) {
                        guard let number = FITProfile.fieldNumber(message: message, name: link.name) else { continue }
                        summaryTargets[message, default: [:]][number] = Target(key: channel.key, factor: pow(target.factor, link.exponent))
                    }
                }
            case .developer(let key):
                developerTargets[key] = target
            }
        }

        let original = file.bytes
        var bytes = original
        var report = AdjustmentReport()
        let compressedPower = FITProfile.fieldNumber(message: FITMessageNumber.record, name: "compressed_accumulated_power")
        var accumulation: (segment: Int, lastRaw: Double, unwrapped: Double)?

        for message in file.messages {
            let definition = file.definitions[message.definition]
            let bigEndian = definition.isBigEndian
            let global = message.globalNumber
            let targets: [UInt8: Target]
            if global == FITMessageNumber.record {
                targets = recordTargets
            } else if let summary = summaryTargets[global] {
                targets = summary
            } else {
                continue
            }

            for field in definition.fields {
                guard let target = targets[field.number], field.baseType.isNumeric else { continue }
                let profile = FITProfile.field(message: global, number: field.number)
                let offset = message.dataOffset + field.offset

                if field.number == compressedPower && global == FITMessageNumber.record {
                    // Accumulated power that wraps at 65 536: unwrap, scale, wrap again.
                    guard let raw = field.baseType.read(original, at: offset, bigEndian: bigEndian) else { continue }
                    var unwrapped = raw
                    if let previous = accumulation, previous.segment == message.segment {
                        unwrapped = previous.unwrapped + (raw - previous.lastRaw + 65536).truncatingRemainder(dividingBy: 65536)
                    }
                    accumulation = (message.segment, raw, unwrapped)
                    let scaled = (unwrapped * target.factor).rounded().truncatingRemainder(dividingBy: 65536)
                    field.baseType.write(scaled, into: &bytes, at: offset, bigEndian: bigEndian)
                    count(&report, global: global, key: target.key)
                    continue
                }

                if let profile, let fractionName = fractionPairs[profile.name],
                   let fractionNumber = FITProfile.fieldNumber(message: global, name: fractionName),
                   let fraction = definition.field(fractionNumber), fraction.baseType.isNumeric {
                    if scaleWithFraction(&bytes, original: original, whole: field, fraction: fraction, message: message,
                                         bigEndian: bigEndian, factor: target.factor) {
                        count(&report, global: global, key: target.key)
                    }
                    continue
                }

                let scale = profile?.scale ?? 1
                let valueOffset = profile?.offset ?? 0
                var changed = false
                for element in 0..<field.count {
                    let position = offset + element * field.baseType.size
                    if scaleValue(&bytes, original: original, at: position, type: field.baseType, bigEndian: bigEndian,
                                  factor: target.factor, scale: scale, offset: valueOffset) {
                        changed = true
                    }
                }
                if changed { count(&report, global: global, key: target.key) }
            }

            if global == FITMessageNumber.record && !developerTargets.isEmpty {
                for field in definition.developerFields {
                    guard let target = developerTargets[field.key], let description = file.developerFields[field.key],
                          description.baseType.isNumeric, field.size >= description.baseType.size else { continue }
                    var changed = false
                    for element in 0..<(field.size / description.baseType.size) {
                        let position = message.dataOffset + field.offset + element * description.baseType.size
                        if scaleValue(&bytes, original: original, at: position, type: description.baseType, bigEndian: bigEndian,
                                      factor: target.factor, scale: description.scale, offset: description.offset) {
                            changed = true
                        }
                    }
                    if changed { count(&report, global: global, key: target.key) }
                }
            }
        }

        // Checksums. A file that was never closed properly gets a valid header and checksum.
        for (index, segment) in file.segments.enumerated() {
            if segment.hasCRC {
                let crc = FITCRC.compute(bytes[segment.start..<segment.recordsEnd])
                FITBaseType.writeBits(UInt64(crc), into: &bytes, at: segment.recordsEnd, count: 2, bigEndian: false)
            } else if index == file.segments.count - 1 {
                bytes.removeSubrange(segment.recordsEnd...)
                let dataSize = segment.recordsEnd - segment.start - segment.headerSize
                FITBaseType.writeBits(UInt64(dataSize), into: &bytes, at: segment.start + 4, count: 4, bigEndian: false)
                if segment.headerSize >= 14 {
                    let headerCRC = FITCRC.compute(bytes[segment.start..<(segment.start + 12)])
                    FITBaseType.writeBits(UInt64(headerCRC), into: &bytes, at: segment.start + 12, count: 2, bigEndian: false)
                }
                let crc = FITCRC.compute(bytes[segment.start..<segment.recordsEnd])
                bytes.append(UInt8(crc & 0xFF))
                bytes.append(UInt8(crc >> 8))
                report.repairedTruncatedFile = true
            }
        }
        return (Data(bytes), report)
    }

    private static func count(_ report: inout AdjustmentReport, global: UInt16, key: ChannelKey) {
        if global == FITMessageNumber.record {
            report.valuesChanged[key, default: 0] += 1
        } else {
            report.summaryValuesChanged += 1
        }
    }

    /// Scales one value in real units. Returns false when there's no value to scale.
    private static func scaleValue(_ bytes: inout [UInt8], original: [UInt8], at position: Int, type: FITBaseType,
                                   bigEndian: Bool, factor: Double, scale: Double, offset: Double) -> Bool {
        guard let raw = type.read(original, at: position, bigEndian: bigEndian) else { return false }
        let physical = raw / scale - offset
        type.write((physical * factor + offset) * scale, into: &bytes, at: position, bigEndian: bigEndian)
        return true
    }

    /// Scales a value split into a whole part and a 1/128 fraction (e.g. cadence + fractional_cadence).
    private static func scaleWithFraction(_ bytes: inout [UInt8], original: [UInt8], whole: FITFieldDefinition,
                                          fraction: FITFieldDefinition, message: FITMessage, bigEndian: Bool,
                                          factor: Double) -> Bool {
        let wholeOffset = message.dataOffset + whole.offset
        let fractionOffset = message.dataOffset + fraction.offset
        guard let wholeRaw = whole.baseType.read(original, at: wholeOffset, bigEndian: bigEndian) else { return false }
        guard let fractionRaw = fraction.baseType.read(original, at: fractionOffset, bigEndian: bigEndian) else {
            whole.baseType.write(wholeRaw * factor, into: &bytes, at: wholeOffset, bigEndian: bigEndian)
            return true
        }
        let scaled = (wholeRaw + fractionRaw / 128) * factor
        var newWhole = scaled.rounded(.down)
        var newFraction = ((scaled - newWhole) * 128).rounded()
        if newFraction >= 128 {
            newWhole += 1
            newFraction = 0
        }
        whole.baseType.write(newWhole, into: &bytes, at: wholeOffset, bigEndian: bigEndian)
        fraction.baseType.write(newFraction, into: &bytes, at: fractionOffset, bigEndian: bigEndian)
        return true
    }
}
