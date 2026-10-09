import Foundation

/// One FIT `record` message (one second of data).
public struct FITRecord: Equatable, Sendable {
    public var unixTime: Int64
    public var power: Int?
    public var cadence: Int?
    public var heartRate: Int?
    /// Right pedal's share in percent, or the balance with unknown side (`balanceIsRight == false`).
    public var balance: Double?
    public var balanceIsRight: Bool

    public init(unixTime: Int64, power: Int? = nil, cadence: Int? = nil, heartRate: Int? = nil,
                balance: Double? = nil, balanceIsRight: Bool = true) {
        self.unixTime = unixTime
        self.power = power
        self.cadence = cadence
        self.heartRate = heartRate
        self.balance = balance
        self.balanceIsRight = balanceIsRight
    }
}

/// A sensor listed in the file's `device_info` messages.
public struct FITDevice: Equatable, Sendable {
    public var name: String
    public var kind: SensorKind

    public init(name: String, kind: SensorKind) {
        self.name = name
        self.kind = kind
    }
}

/// Builds a FIT activity file (indoor cycling) from per-second records.
public enum FITActivityEncoder {
    public static let appName = "Dual Recorder"

    // FIT profile constants (see the Garmin FIT SDK's Profile.xlsx).
    enum Message {
        static let fileID: UInt16 = 0
        static let session: UInt16 = 18
        static let lap: UInt16 = 19
        static let record: UInt16 = 20
        static let event: UInt16 = 21
        static let deviceInfo: UInt16 = 23
        static let activity: UInt16 = 34
    }

    static let fileTypeActivity: UInt8 = 4
    static let manufacturerDevelopment: UInt16 = 255
    static let manufacturerFavero: UInt16 = 263
    static let sportCycling: UInt8 = 2
    static let subSportIndoorCycling: UInt8 = 6
    static let eventTimer: UInt8 = 0
    static let eventSession: UInt8 = 8
    static let eventLap: UInt8 = 9
    static let eventActivity: UInt8 = 26
    static let eventTypeStart: UInt8 = 0
    static let eventTypeStop: UInt8 = 1
    static let eventTypeStopAll: UInt8 = 4
    static let sourceTypeBluetoothLowEnergy: UInt8 = 3
    static let sourceTypeLocal: UInt8 = 5
    static let lapTriggerSessionEnd: UInt8 = 7
    static let sessionTriggerActivityEnd: UInt8 = 0

    static func antDeviceType(for kind: SensorKind) -> UInt8 {
        switch kind {
        case .powerMeter: return 11   // bike_power
        case .trainer: return 17      // fitness_equipment
        case .heartRate: return 120   // heart_rate
        }
    }

    /// - Parameters:
    ///   - records: one per second, in time order.
    ///   - devices: sensors that contributed data (listed as device_info).
    ///   - timeZone: used for the activity's local timestamp.
    ///   - serialNumber: identifies the "device" that created the file.
    public static func encode(records: [FITRecord], devices: [FITDevice],
                              timeZone: TimeZone = .current, serialNumber: UInt32 = 1) -> Data {
        precondition(!records.isEmpty, "A FIT activity needs at least one record")
        let start = records.first!.unixTime
        let end = records.last!.unixTime
        let startTS = FITWriter.fitTimestamp(unixSeconds: start)
        let endTS = FITWriter.fitTimestamp(unixSeconds: end)
        let elapsedMillis = UInt32(clamping: (end - start) * 1000)

        var writer = FITWriter()

        writer.write(global: Message.fileID, fields: [
            (0, .enumeration(fileTypeActivity)),
            (1, .uint16(manufacturerDevelopment)),
            (2, .uint16(1)),
            (3, .uint32z(serialNumber == 0 ? 1 : serialNumber)),
            (4, .uint32(startTS)),
            (8, .string(appName, size: 20)),
        ])

        // device_index 0 is the "creator" (this app); sensors follow.
        writer.write(global: Message.deviceInfo, fields: [
            (253, .uint32(startTS)),
            (0, .uint8(0)),
            (2, .uint16(manufacturerDevelopment)),
            (4, .uint16(1)),
            (5, .uint16(100)),        // software version 1.00
            (25, .enumeration(sourceTypeLocal)),
            (27, .string(appName, size: 20)),
        ])
        for (index, device) in devices.enumerated() {
            let manufacturer = device.name.uppercased().contains("ASSIOMA") ? manufacturerFavero : manufacturerDevelopment
            writer.write(global: Message.deviceInfo, fields: [
                (253, .uint32(startTS)),
                (0, .uint8(UInt8(clamping: index + 1))),
                (1, .uint8(antDeviceType(for: device.kind))),
                (2, .uint16(manufacturer)),
                (25, .enumeration(sourceTypeBluetoothLowEnergy)),
                (27, .string(device.name, size: 32)),
            ])
        }

        writer.write(global: Message.event, fields: [
            (253, .uint32(startTS)),
            (0, .enumeration(eventTimer)),
            (1, .enumeration(eventTypeStart)),
        ])

        // Only include record fields that carry data somewhere in the file.
        let hasPower = records.contains { $0.power != nil }
        let hasCadence = records.contains { $0.cadence != nil }
        let hasHeartRate = records.contains { $0.heartRate != nil }
        let hasBalance = records.contains { $0.balance != nil }
        for record in records {
            var fields: [(UInt8, FITValue)] = [(253, .uint32(FITWriter.fitTimestamp(unixSeconds: record.unixTime)))]
            if hasHeartRate { fields.append((3, .uint8(record.heartRate.map { UInt8(clamping: $0) }))) }
            if hasCadence { fields.append((4, .uint8(record.cadence.map { UInt8(clamping: $0) }))) }
            if hasPower { fields.append((7, .uint16(record.power.map { UInt16(clamping: max($0, 0)) }))) }
            if hasBalance { fields.append((30, .uint8(encodeBalance(record)))) }
            writer.write(global: Message.record, fields: fields)
        }

        writer.write(global: Message.event, fields: [
            (253, .uint32(endTS)),
            (0, .enumeration(eventTimer)),
            (1, .enumeration(eventTypeStopAll)),
        ])

        let totals = Totals(records)
        writer.write(global: Message.lap, fields: [
            (254, .uint16(0)),
            (253, .uint32(endTS)),
            (0, .enumeration(eventLap)),
            (1, .enumeration(eventTypeStop)),
            (2, .uint32(startTS)),
            (7, .uint32(elapsedMillis)),
            (8, .uint32(elapsedMillis)),
            (15, .uint8(totals.avgHeartRate)),
            (16, .uint8(totals.maxHeartRate)),
            (17, .uint8(totals.avgCadence)),
            (18, .uint8(totals.maxCadence)),
            (19, .uint16(totals.avgPower)),
            (20, .uint16(totals.maxPower)),
            (24, .enumeration(lapTriggerSessionEnd)),
            (25, .enumeration(sportCycling)),
            (33, .uint16(totals.normalizedPower)),
            (39, .enumeration(subSportIndoorCycling)),
        ])

        writer.write(global: Message.session, fields: [
            (254, .uint16(0)),
            (253, .uint32(endTS)),
            (0, .enumeration(eventSession)),
            (1, .enumeration(eventTypeStop)),
            (2, .uint32(startTS)),
            (5, .enumeration(sportCycling)),
            (6, .enumeration(subSportIndoorCycling)),
            (7, .uint32(elapsedMillis)),
            (8, .uint32(elapsedMillis)),
            (16, .uint8(totals.avgHeartRate)),
            (17, .uint8(totals.maxHeartRate)),
            (18, .uint8(totals.avgCadence)),
            (19, .uint8(totals.maxCadence)),
            (20, .uint16(totals.avgPower)),
            (21, .uint16(totals.maxPower)),
            (25, .uint16(0)),
            (26, .uint16(1)),
            (28, .enumeration(sessionTriggerActivityEnd)),
            (34, .uint16(totals.normalizedPower)),
        ])

        let offset = Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(end))))
        writer.write(global: Message.activity, fields: [
            (253, .uint32(endTS)),
            (0, .uint32(elapsedMillis)),
            (1, .uint16(1)),
            (2, .enumeration(0)),     // manual
            (3, .enumeration(eventActivity)),
            (4, .enumeration(eventTypeStop)),
            (5, .uint32(FITWriter.fitTimestamp(unixSeconds: end + offset))),
        ])

        return writer.finish()
    }

    /// FIT left_right_balance: bits 0-6 = percent, bit 7 set = the percent is the right pedal's.
    static func encodeBalance(_ record: FITRecord) -> UInt8? {
        guard let balance = record.balance, balance.isFinite else { return nil }
        let percent = UInt8(clamping: Int(balance.rounded()))
        guard percent <= 100 else { return nil }
        return record.balanceIsRight ? (percent | 0x80) : percent
    }

    private struct Totals {
        var avgPower: UInt16?
        var maxPower: UInt16?
        var normalizedPower: UInt16?
        var avgCadence: UInt8?
        var maxCadence: UInt8?
        var avgHeartRate: UInt8?
        var maxHeartRate: UInt8?

        init(_ records: [FITRecord]) {
            let power = records.compactMap(\.power)
            let cadence = records.compactMap(\.cadence)
            let heartRate = records.compactMap(\.heartRate)
            avgPower = RideStats.average(power).map { UInt16(clamping: $0) }
            maxPower = power.max().map { UInt16(clamping: $0) }
            if !power.isEmpty {
                normalizedPower = RideStats.normalizedPower(records.map(\.power)).map { UInt16(clamping: $0) }
            }
            avgCadence = RideStats.average(cadence.filter { $0 > 0 }).map { UInt8(clamping: $0) }
            maxCadence = cadence.max().map { UInt8(clamping: $0) }
            avgHeartRate = RideStats.average(heartRate).map { UInt8(clamping: $0) }
            maxHeartRate = heartRate.max().map { UInt8(clamping: $0) }
        }
    }
}
