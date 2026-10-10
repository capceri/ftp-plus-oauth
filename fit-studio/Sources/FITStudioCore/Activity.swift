import Foundation

/// Identifies a data channel, consistently across files: the profile field name for standard
/// fields ("power"), "field_N" for undocumented ones and "dev:<name>" for developer fields.
public struct ChannelKey: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
    public var isDeveloper: Bool { rawValue.hasPrefix("dev:") }

    public static func < (lhs: ChannelKey, rhs: ChannelKey) -> Bool { lhs.rawValue < rhs.rawValue }

    public static let power = ChannelKey("power")
    public static let heartRate = ChannelKey("heart_rate")
    public static let cadence = ChannelKey("cadence")
    public static let speed = ChannelKey("speed")
    public static let distance = ChannelKey("distance")
    public static let altitude = ChannelKey("altitude")
    public static let temperature = ChannelKey("temperature")
    public static let balance = ChannelKey("left_right_balance")
}

/// What a channel measures, for unit conversion.
public enum Quantity: String, Sendable {
    case speed, distance, altitude, temperature, other
}

public enum ChannelSource: Sendable, Equatable {
    /// Record fields, most preferred first (e.g. enhanced_speed, then speed).
    case native([UInt8])
    case developer(FITDeveloperFieldKey)
}

/// One series of values from the file's `record` messages, aligned with `Activity.times`.
public struct Channel: Identifiable, Sendable {
    public var key: ChannelKey
    public var name: String
    /// Units of `values` (FIT units: m/s, m, °C, …).
    public var units: String
    public var quantity: Quantity
    public var source: ChannelSource
    /// Whether the percentage adjustment can be applied (numbers only, not balance or positions).
    public var isAdjustable: Bool
    /// False for fields the FIT profile doesn't describe (manufacturer-specific data).
    public var isDocumented: Bool
    public var values: [Double?]

    public var id: ChannelKey { key }
}

public struct Coordinate: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
}

public struct DeviceSummary: Sendable, Identifiable, Equatable {
    public var id: Int
    public var deviceIndex: Int?
    public var name: String
    public var type: String?
    public var serialNumber: UInt32?
    public var softwareVersion: Double?
    public var batteryStatus: String?
    public var batteryVoltage: Double?
    public var batteryLevel: Double?
    public var source: String?
}

public struct LapSummary: Sendable, Identifiable, Equatable {
    public var id: Int
    /// Seconds from the activity start.
    public var start: Double
    public var end: Double
    public var timerTime: Double?
    public var distance: Double?
}

public struct MessageCount: Sendable, Identifiable, Equatable {
    public var globalNumber: UInt16
    public var name: String
    public var count: Int
    public var id: UInt16 { globalNumber }
}

/// File-level information shown in the summary.
public struct ActivityInfo: Sendable {
    public var fileType: String?
    public var creator: String?
    public var serialNumber: UInt32?
    public var timeCreated: Date?
    public var sport: String?
    public var elapsedTime: Double?
    public var timerTime: Double?
    public var distance: Double?
    public var calories: Double?
    public var ascent: Double?
    public var descent: Double?
    public var devices: [DeviceSummary] = []
    public var laps: [LapSummary] = []
    public var messageCounts: [MessageCount] = []
    public var developerFields: [FITDeveloperFieldDescription] = []
    public var warnings: [String] = []
    public var protocolVersion = ""
    public var profileVersion = ""
    public var byteCount = 0

    public init() {}
}

/// The activity in a FIT file as time series, plus file information.
///
/// Records sharing a timestamp are merged into one row, so each row is one moment in time.
public struct Activity: Sendable {
    /// Unix time of the first row, when the records have timestamps.
    public var startUnix: Int64?
    /// Seconds since the first row, one per row.
    public var times: [Double]
    public var channels: [Channel]
    /// One per row when the file has GPS positions, otherwise empty.
    public var positions: [Coordinate?]
    public var info: ActivityInfo

    public var startDate: Date? { startUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    public var duration: Double { times.last ?? 0 }
    public var hasPositions: Bool { !positions.isEmpty }

    public func channel(_ key: ChannelKey) -> Channel? {
        channels.first { $0.key == key }
    }

    public init(file: FITFile) {
        let built = ActivityBuilder(file: file)
        startUnix = built.startUnix
        times = built.times
        channels = built.channels
        positions = built.positions
        info = ActivityBuilder.info(file: file, startUnix: built.startUnix)
    }

    public init(startUnix: Int64?, times: [Double], channels: [Channel], positions: [Coordinate?] = [], info: ActivityInfo = ActivityInfo()) {
        self.startUnix = startUnix
        self.times = times
        self.channels = channels
        self.positions = positions
        self.info = info
    }

    /// A copy with each channel's values multiplied by its adjustment (percent), for previews.
    public func adjusted(by percents: [ChannelKey: Double]) -> Activity {
        var copy = self
        for i in copy.channels.indices {
            guard copy.channels[i].isAdjustable, let percent = percents[copy.channels[i].key], percent != 0 else { continue }
            let factor = 1 + percent / 100
            copy.channels[i].values = copy.channels[i].values.map { $0.map { $0 * factor } }
        }
        return copy
    }
}

// MARK: - Building

enum ActivityRules {
    /// Record fields shown as part of another channel.
    static let mergedInto: [String: String] = [
        "enhanced_speed": "speed",
        "enhanced_altitude": "altitude",
        "cadence256": "cadence",
        "enhanced_respiration_rate": "respiration_rate",
    ]

    /// Lower-resolution fields used only when a record lacks the preferred one.
    static let secondaryFields: Set<String> = ["speed", "altitude", "cadence256", "respiration_rate"]

    static let unitOverrides: [String: String] = ["respiration_rate": "br/min", "cadence": "rpm"]

    static func isSecondary(_ recordField: UInt8) -> Bool {
        FITProfile.field(message: FITMessageNumber.record, number: recordField).map { secondaryFields.contains($0.name) } ?? false
    }

    /// Record fields that aren't channels: timestamp, positions, packed or wrapped values, and
    /// fractional cadence (added to cadence instead).
    static let excludedRecordFields: Set<UInt8> = [253, 0, 1, 8, 28, 48, 53]

    static let preferredOrder: [String] = [
        "power", "heart_rate", "cadence", "speed", "distance", "altitude", "grade", "temperature",
        "left_right_balance",
    ]

    static let displayNames: [String: String] = [
        "heart_rate": "Heart rate",
        "altitude": "Elevation",
        "left_right_balance": "Balance (right)",
        "accumulated_power": "Accumulated power",
        "gps_accuracy": "GPS accuracy",
        "motor_power": "Motor power",
        "core_temperature": "Core temperature",
    ]

    static func quantity(for key: String) -> Quantity {
        switch key {
        case "speed", "ball_speed": return .speed
        case "distance": return .distance
        case "altitude": return .altitude
        case "temperature", "core_temperature": return .temperature
        default: return .other
        }
    }

    static func displayName(for key: String) -> String {
        displayNames[key] ?? FITNames.humanize(key)
    }
}

private struct ActivityBuilder {
    var startUnix: Int64?
    var times: [Double] = []
    var channels: [Channel] = []
    var positions: [Coordinate?] = []

    private struct Spec {
        var key: ChannelKey
        var name: String
        var units: String
        var quantity: Quantity
        var documented: Bool
        var adjustable: Bool
        var fieldNumbers: [UInt8] = []
        var developerKey: FITDeveloperFieldKey?
        var sortRank: (Int, Int, String)
    }

    private enum Kind {
        case plain, balance, cadence(fraction: FITFieldDefinition?)
    }

    private struct Reader {
        var field: FITFieldDefinition
        var channel: Int
        var priority: UInt8
        var scale: Double
        var offset: Double
        var kind: Kind
    }

    init(file: FITFile) {
        let records = file.messages.filter { $0.globalNumber == FITMessageNumber.record }
        guard !records.isEmpty else { return }

        // Row times: fill missing timestamps from the previous record, sort if needed, merge equal ones.
        var unix: [Int64?] = []
        unix.reserveCapacity(records.count)
        var last: Int64?
        for record in records {
            if let ts = record.timestamp { last = FITFile.unixTime(ts) }
            unix.append(last)
        }
        let firstKnown = unix.first { $0 != nil } ?? nil
        let resolved: [Int64] = unix.enumerated().map { index, value in value ?? firstKnown ?? Int64(index) }
        var order = Array(records.indices)
        if zip(resolved, resolved.dropFirst()).contains(where: { $0 > $1 }) {
            order.sort { resolved[$0] < resolved[$1] || (resolved[$0] == resolved[$1] && $0 < $1) }
        }
        var rowOfRecord = [Int](repeating: 0, count: records.count)
        var rowUnix: [Int64] = []
        for index in order {
            if rowUnix.last != resolved[index] { rowUnix.append(resolved[index]) }
            rowOfRecord[index] = rowUnix.count - 1
        }
        let start = rowUnix[0]
        startUnix = firstKnown == nil ? nil : start
        times = rowUnix.map { Double($0 - start) }
        let rowCount = rowUnix.count

        // Discover channels from the record definitions.
        let definitionIndexes = Set(records.map(\.definition)).sorted()
        var specs: [Spec] = []
        var specIndex: [ChannelKey: Int] = [:]
        var developerNames: [String: FITDeveloperFieldKey] = [:]
        var hasPositions = false

        func spec(for key: ChannelKey, make: () -> Spec) -> Int {
            if let index = specIndex[key] { return index }
            specs.append(make())
            specIndex[key] = specs.count - 1
            return specs.count - 1
        }

        var readers: [Int: [Reader]] = [:]
        for definitionIndex in definitionIndexes {
            let definition = file.definitions[definitionIndex]
            var list: [Reader] = []
            for field in definition.fields {
                if field.number == 0 || field.number == 1 { hasPositions = hasPositions || field.baseType == .sint32 }
                guard !ActivityRules.excludedRecordFields.contains(field.number), field.count == 1 else { continue }
                let profile = FITProfile.field(message: FITMessageNumber.record, number: field.number)
                let index: Int
                var kind = Kind.plain
                var priority: UInt8 = 0
                if let profile {
                    let isBalance = profile.name == "left_right_balance"
                    guard (profile.isQuantity && !profile.isArray && field.baseType.isNumeric) || isBalance else { continue }
                    let name = ActivityRules.mergedInto[profile.name] ?? profile.name
                    priority = ActivityRules.secondaryFields.contains(profile.name) ? 1 : 0
                    let key = ChannelKey(name)
                    let units = ActivityRules.unitOverrides[name] ?? FITNames.units(profile.units)
                    index = spec(for: key) {
                        let preferred = ActivityRules.preferredOrder.firstIndex(of: name)
                        return Spec(key: key, name: ActivityRules.displayName(for: name),
                                    units: isBalance ? "%" : units,
                                    quantity: ActivityRules.quantity(for: name), documented: true,
                                    adjustable: !isBalance && FITAdjuster.followers[name] == nil,
                                    sortRank: preferred.map { (0, $0, "") } ?? (1, Int(field.number), ""))
                    }
                    if isBalance { kind = .balance }
                    if name == "cadence" && profile.name == "cadence" { kind = .cadence(fraction: definition.field(53)) }
                    if !specs[index].fieldNumbers.contains(field.number) { specs[index].fieldNumbers.append(field.number) }
                    list.append(Reader(field: field, channel: index, priority: priority,
                                       scale: profile.scale, offset: profile.offset, kind: kind))
                } else {
                    guard field.baseType.isNumeric else { continue }
                    let key = ChannelKey("field_\(field.number)")
                    index = spec(for: key) {
                        Spec(key: key, name: "Field \(field.number)", units: "", quantity: .other, documented: false,
                             adjustable: true, sortRank: (3, Int(field.number), ""))
                    }
                    if !specs[index].fieldNumbers.contains(field.number) { specs[index].fieldNumbers.append(field.number) }
                    list.append(Reader(field: field, channel: index, priority: 0, scale: 1, offset: 0, kind: .plain))
                }
            }
            readers[definitionIndex] = list
        }

        // Developer fields (one channel per field; keyed by name so files can be compared).
        var developerReaders: [Int: [(FITDeveloperFieldDefinition, Int, FITDeveloperFieldDescription)]] = [:]
        for definitionIndex in definitionIndexes {
            let definition = file.definitions[definitionIndex]
            for field in definition.developerFields {
                guard let description = file.developerFields[field.key], description.baseType.isNumeric,
                      field.size == description.baseType.size else { continue }
                var keyName = "dev:" + description.name.lowercased().replacingOccurrences(of: " ", with: "_")
                if let existing = developerNames[keyName], existing != field.key {
                    keyName += "_\(field.developerIndex)_\(field.number)"
                }
                developerNames[keyName] = field.key
                let key = ChannelKey(keyName)
                let index = spec(for: key) {
                    Spec(key: key, name: description.name, units: FITNames.units(description.units), quantity: .other,
                         documented: true, adjustable: true, developerKey: field.key,
                         sortRank: (2, 0, description.name.lowercased()))
                }
                developerReaders[definitionIndex, default: []].append((field, index, description))
            }
        }

        // Read the values.
        var values = [[Double?]](repeating: [Double?](repeating: nil, count: rowCount), count: specs.count)
        var priorities = [[UInt8]](repeating: [UInt8](repeating: .max, count: rowCount), count: specs.count)
        var latitudes = [Double?](repeating: nil, count: hasPositions ? rowCount : 0)
        var longitudes = latitudes
        let bytes = file.bytes
        let semicircles = 180.0 / 2_147_483_648.0

        for (recordIndex, record) in records.enumerated() {
            let row = rowOfRecord[recordIndex]
            let definition = file.definitions[record.definition]
            let bigEndian = definition.isBigEndian
            for reader in readers[record.definition] ?? [] {
                guard reader.priority <= priorities[reader.channel][row],
                      let raw = reader.field.baseType.read(bytes, at: record.dataOffset + reader.field.offset, bigEndian: bigEndian)
                else { continue }
                var value = raw / reader.scale - reader.offset
                switch reader.kind {
                case .plain:
                    break
                case .balance:
                    let percent = Double(Int(raw) & 0x7F)
                    guard percent <= 100 else { continue }
                    // Bit 7 set: the percentage is the right pedal's. Otherwise the side is unknown.
                    value = percent
                case .cadence(let fraction):
                    if let fraction, let extra = fraction.baseType.read(bytes, at: record.dataOffset + fraction.offset, bigEndian: bigEndian) {
                        value += extra / 128
                    }
                }
                values[reader.channel][row] = value
                priorities[reader.channel][row] = reader.priority
            }
            for (field, channel, description) in developerReaders[record.definition] ?? [] {
                guard let raw = description.baseType.read(bytes, at: record.dataOffset + field.offset, bigEndian: bigEndian) else { continue }
                values[channel][row] = raw / description.scale - description.offset
            }
            if hasPositions,
               let lat = definition.field(0), let lon = definition.field(1), lat.baseType == .sint32, lon.baseType == .sint32,
               let latRaw = FITBaseType.sint32.read(bytes, at: record.dataOffset + lat.offset, bigEndian: bigEndian),
               let lonRaw = FITBaseType.sint32.read(bytes, at: record.dataOffset + lon.offset, bigEndian: bigEndian) {
                latitudes[row] = latRaw * semicircles
                longitudes[row] = lonRaw * semicircles
            }
        }

        var built: [(Spec, Channel)] = []
        for (index, spec) in specs.enumerated() where values[index].contains(where: { $0 != nil }) {
            let fields = spec.fieldNumbers.sorted { !ActivityRules.isSecondary($0) && ActivityRules.isSecondary($1) }
            let source: ChannelSource = spec.developerKey.map { .developer($0) } ?? .native(fields)
            built.append((spec, Channel(key: spec.key, name: spec.name, units: spec.units, quantity: spec.quantity,
                                        source: source, isAdjustable: spec.adjustable, isDocumented: spec.documented,
                                        values: values[index])))
        }
        built.sort { $0.0.sortRank < $1.0.sortRank }
        channels = built.map(\.1)

        if hasPositions, latitudes.contains(where: { $0 != nil }) {
            positions = zip(latitudes, longitudes).map { lat, lon in
                guard let lat, let lon, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
                return Coordinate(latitude: lat, longitude: lon)
            }
        }
    }

    // MARK: Info

    static func info(file: FITFile, startUnix: Int64?) -> ActivityInfo {
        var info = ActivityInfo()
        info.warnings = file.warnings
        info.byteCount = file.bytes.count
        if let segment = file.segments.first {
            info.protocolVersion = "\(segment.protocolVersion >> 4).\(segment.protocolVersion & 0x0F)"
            // Profile 21.41 is stored as 2141; versions with a 3-digit minor (21.218) as 21218.
            let version = Int(segment.profileVersion)
            info.profileVersion = version >= 10000 ? "\(version / 1000).\(version % 1000)" : String(format: "%d.%02d", version / 100, version % 100)
        }

        if let fileID = file.messages.first(where: { $0.globalNumber == FITMessageNumber.fileID }) {
            info.fileType = file.rawValue(0, in: fileID).flatMap { FITProfile.typeValueName("file", Int($0)) }.map { FITNames.humanize($0) }
            let manufacturer = file.rawValue(1, in: fileID)
            let maker = FITNames.manufacturer(manufacturer)
            let product = FITNames.product(manufacturer: manufacturer, product: file.rawValue(2, in: fileID),
                                           productName: file.string(8, in: fileID))
            info.creator = [maker, product].compactMap { $0 }.joined(separator: " ")
            if info.creator?.isEmpty == true { info.creator = nil }
            info.serialNumber = file.rawValue(3, in: fileID).map { UInt32($0) }
            info.timeCreated = file.rawValue(4, in: fileID).map { FITFile.date(UInt32($0)) }
        }

        let sessions = file.messages(FITMessageNumber.session)
        if let session = sessions.first {
            info.sport = FITNames.sport(file.rawValue(5, in: session), subSport: file.rawValue(6, in: session))
            func total(_ name: String) -> Double? {
                let values = sessions.compactMap { file.value(named: name, in: $0) }
                return values.isEmpty ? nil : values.reduce(0, +)
            }
            info.elapsedTime = total("total_elapsed_time")
            info.timerTime = total("total_timer_time")
            info.distance = total("total_distance")
            info.calories = total("total_calories")
            info.ascent = total("total_ascent")
            info.descent = total("total_descent")
        } else if let sport = file.messages.first(where: { $0.globalNumber == FITMessageNumber.sport }) {
            info.sport = FITNames.sport(file.rawValue(0, in: sport), subSport: file.rawValue(1, in: sport))
        }

        var devices: [Int: DeviceSummary] = [:]
        var anonymous: [DeviceSummary] = []
        for message in file.messages(FITMessageNumber.deviceInfo) {
            let index = file.rawValue(0, in: message).map(Int.init)
            let manufacturer = file.rawValue(2, in: message)
            let product = FITNames.product(manufacturer: manufacturer, product: file.rawValue(4, in: message),
                                           productName: file.string(27, in: message))
            let maker = FITNames.manufacturer(manufacturer)
            var type: String?
            if let raw = file.rawValue(1, in: message) {
                // device_type's meaning depends on source_type (ANT+, BLE or local).
                let table = file.rawValue(25, in: message) == 3 ? "ble_device_type" : "antplus_device_type"
                type = FITProfile.typeValueName(table, Int(raw)).map { FITNames.humanize($0) }
            }
            var summary = devices[index ?? -1] ?? DeviceSummary(id: index ?? (1000 + anonymous.count), deviceIndex: index, name: "")
            let name = [maker, product].compactMap { $0 }.joined(separator: " ")
            if !name.isEmpty { summary.name = name }
            if index == 0 && summary.name.isEmpty { summary.name = info.creator ?? "Recording device" }
            summary.type = type ?? summary.type
            summary.serialNumber = file.rawValue(3, in: message).map { UInt32($0) } ?? summary.serialNumber
            summary.softwareVersion = file.value(5, in: message) ?? summary.softwareVersion
            summary.batteryVoltage = file.value(10, in: message) ?? summary.batteryVoltage
            summary.batteryLevel = file.value(32, in: message) ?? summary.batteryLevel
            summary.batteryStatus = file.rawValue(11, in: message)
                .flatMap { FITProfile.typeValueName("battery_status", Int($0)) }.map { FITNames.humanize($0) } ?? summary.batteryStatus
            summary.source = file.rawValue(25, in: message)
                .flatMap { FITProfile.typeValueName("source_type", Int($0)) }.map { FITNames.humanize($0) } ?? summary.source
            if summary.name.isEmpty { summary.name = type ?? "Device \(index.map(String.init) ?? "")" }
            if let index { devices[index] = summary } else { anonymous.append(summary) }
        }
        info.devices = devices.values.sorted { ($0.deviceIndex ?? 0) < ($1.deviceIndex ?? 0) } + anonymous

        if let startUnix {
            for (i, lap) in file.messages(FITMessageNumber.lap).enumerated() {
                guard let lapStart = file.rawValue(2, in: lap).map({ FITFile.unixTime(UInt32($0)) }) else { continue }
                let elapsed = file.value(named: "total_elapsed_time", in: lap)
                let end = elapsed.map { Double(lapStart - startUnix) + $0 }
                    ?? lap.timestamp.map { Double(FITFile.unixTime($0) - startUnix) } ?? Double(lapStart - startUnix)
                info.laps.append(LapSummary(id: i + 1, start: Double(lapStart - startUnix), end: end,
                                            timerTime: file.value(named: "total_timer_time", in: lap),
                                            distance: file.value(named: "total_distance", in: lap)))
            }
        }

        var counts: [UInt16: Int] = [:]
        for message in file.messages { counts[message.globalNumber, default: 0] += 1 }
        info.messageCounts = counts.keys.sorted().map {
            MessageCount(globalNumber: $0, name: FITProfile.messageName($0).map { FITNames.humanize($0) } ?? "Message \($0)",
                         count: counts[$0] ?? 0)
        }
        info.developerFields = file.developerFields.values.sorted {
            ($0.key.developerIndex, $0.key.number) < ($1.key.developerIndex, $1.key.number)
        }
        return info
    }
}
