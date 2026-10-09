import Foundation

/// Little-endian reader over a GATT characteristic value.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init<D: Collection>(_ data: D) where D.Element == UInt8 {
        bytes = Array(data)
    }

    var remaining: Int { bytes.count - offset }

    mutating func skip(_ count: Int) -> Bool {
        guard remaining >= count else { return false }
        offset += count
        return true
    }

    mutating func uint8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func int16() -> Int16? {
        uint16().map { Int16(bitPattern: $0) }
    }

    mutating func uint24() -> UInt32? {
        guard remaining >= 3 else { return nil }
        defer { offset += 3 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
    }

    mutating func uint32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

/// Cycling Power Measurement (characteristic 0x2A63).
public struct CyclingPowerMeasurement: Equatable, Sendable {
    public var instantaneousPower: Int
    /// Pedal power balance in percent (the characteristic sends 1/2 % units).
    public var pedalPowerBalance: Double?
    /// True when `pedalPowerBalance` is the left pedal's share; false when the side is unknown.
    public var balanceReferenceIsLeft: Bool
    public var cumulativeCrankRevolutions: UInt16?
    /// Last crank event time in 1/1024 s, rolls over every 64 s.
    public var lastCrankEventTime: UInt16?

    public init(instantaneousPower: Int, pedalPowerBalance: Double? = nil, balanceReferenceIsLeft: Bool = false,
                cumulativeCrankRevolutions: UInt16? = nil, lastCrankEventTime: UInt16? = nil) {
        self.instantaneousPower = instantaneousPower
        self.pedalPowerBalance = pedalPowerBalance
        self.balanceReferenceIsLeft = balanceReferenceIsLeft
        self.cumulativeCrankRevolutions = cumulativeCrankRevolutions
        self.lastCrankEventTime = lastCrankEventTime
    }

    public static func parse<D: Collection>(_ data: D) -> CyclingPowerMeasurement? where D.Element == UInt8 {
        var reader = ByteReader(data)
        guard let flags = reader.uint16(), let power = reader.int16() else { return nil }
        var result = CyclingPowerMeasurement(instantaneousPower: Int(power))
        if flags & 0x0001 != 0 {
            guard let balance = reader.uint8() else { return nil }
            // 0xFF would be outside 0...100 %; treat anything above 200 half-percent units as absent.
            if balance <= 200 {
                result.pedalPowerBalance = Double(balance) / 2
                result.balanceReferenceIsLeft = flags & 0x0002 != 0
            }
        }
        if flags & 0x0004 != 0 { // accumulated torque
            guard reader.skip(2) else { return nil }
        }
        if flags & 0x0010 != 0 { // wheel revolution data
            guard reader.skip(6) else { return nil }
        }
        if flags & 0x0020 != 0 { // crank revolution data
            guard let revs = reader.uint16(), let time = reader.uint16() else { return nil }
            result.cumulativeCrankRevolutions = revs
            result.lastCrankEventTime = time
        }
        // Later optional fields (extreme magnitudes/angles, dead spots, energy) aren't needed.
        return result
    }
}

/// FTMS Indoor Bike Data (characteristic 0x2AD2). Trainers may split a full set of
/// fields across several notifications, so every field is optional.
public struct IndoorBikeData: Equatable, Sendable {
    public var speedKmh: Double?
    public var cadence: Double?
    public var power: Int?
    public var heartRate: Int?

    public init(speedKmh: Double? = nil, cadence: Double? = nil, power: Int? = nil, heartRate: Int? = nil) {
        self.speedKmh = speedKmh
        self.cadence = cadence
        self.power = power
        self.heartRate = heartRate
    }

    public static func parse<D: Collection>(_ data: D) -> IndoorBikeData? where D.Element == UInt8 {
        var reader = ByteReader(data)
        guard let flags = reader.uint16() else { return nil }
        var result = IndoorBikeData()
        // Bit 0 is "More Data": instantaneous speed is present when it is 0.
        if flags & 0x0001 == 0 {
            guard let speed = reader.uint16() else { return nil }
            result.speedKmh = Double(speed) / 100
        }
        if flags & 0x0002 != 0 { guard reader.skip(2) else { return nil } } // average speed
        if flags & 0x0004 != 0 {
            guard let cadence = reader.uint16() else { return nil }
            result.cadence = Double(cadence) / 2
        }
        if flags & 0x0008 != 0 { guard reader.skip(2) else { return nil } } // average cadence
        if flags & 0x0010 != 0 { guard reader.skip(3) else { return nil } } // total distance
        if flags & 0x0020 != 0 { guard reader.skip(2) else { return nil } } // resistance level
        if flags & 0x0040 != 0 {
            guard let power = reader.int16() else { return nil }
            result.power = Int(power)
        }
        if flags & 0x0080 != 0 { guard reader.skip(2) else { return nil } } // average power
        if flags & 0x0100 != 0 { guard reader.skip(5) else { return nil } } // expended energy
        if flags & 0x0200 != 0 {
            guard let hr = reader.uint8() else { return nil }
            if hr > 0 { result.heartRate = Int(hr) }
        }
        return result
    }
}

/// Heart Rate Measurement (characteristic 0x2A37).
public enum HeartRateMeasurement {
    public static func parse<D: Collection>(_ data: D) -> Int? where D.Element == UInt8 {
        var reader = ByteReader(data)
        guard let flags = reader.uint8() else { return nil }
        if flags & 0x01 != 0 {
            return reader.uint16().map(Int.init)
        }
        return reader.uint8().map(Int.init)
    }
}

/// Cycling Power Control Point (characteristic 0x2A66) requests and responses.
public enum CyclingPowerControlPoint {
    public static let startOffsetCompensationOpCode: UInt8 = 0x0C
    public static let responseOpCode: UInt8 = 0x20

    public enum ResultCode: UInt8, Sendable {
        case success = 0x01
        case opCodeNotSupported = 0x02
        case invalidParameter = 0x03
        case operationFailed = 0x04
    }

    public struct Response: Equatable, Sendable {
        public var requestOpCode: UInt8
        /// nil when the sensor sent a result code outside the standard set.
        public var result: ResultCode?
        public var rawResult: UInt8
        /// For offset compensation: the raw offset (force in N or torque in 1/32 Nm), if sent.
        public var offset: Int?
    }

    public static var startOffsetCompensationRequest: [UInt8] { [startOffsetCompensationOpCode] }

    public static func parseResponse<D: Collection>(_ data: D) -> Response? where D.Element == UInt8 {
        var reader = ByteReader(data)
        guard reader.uint8() == responseOpCode, let request = reader.uint8(), let raw = reader.uint8() else {
            return nil
        }
        var response = Response(requestOpCode: request, result: ResultCode(rawValue: raw), rawResult: raw, offset: nil)
        if request == startOffsetCompensationOpCode, raw == ResultCode.success.rawValue, let offset = reader.int16() {
            response.offset = Int(offset)
        }
        return response
    }
}

/// Turns the cumulative crank revolution counter of a Cycling Power Measurement into cadence.
public struct CrankCadenceCalculator: Sendable {
    /// After this long without a new crank revolution, cadence is reported as 0.
    public var stoppedAfter: TimeInterval
    private var previousRevolutions: UInt16?
    private var previousEventTime: UInt16?
    private var lastRevolutionAt: TimeInterval?
    private var lastCadence: Double?

    public init(stoppedAfter: TimeInterval = 3) {
        self.stoppedAfter = stoppedAfter
    }

    /// - Parameter receivedAt: local time the notification arrived (any monotonic clock, seconds).
    /// - Returns: cadence in rpm, or nil until there is enough data.
    public mutating func update(revolutions: UInt16, eventTime: UInt16, receivedAt: TimeInterval) -> Double? {
        defer {
            previousRevolutions = revolutions
            previousEventTime = eventTime
        }
        guard let prevRevs = previousRevolutions, let prevTime = previousEventTime else {
            lastRevolutionAt = receivedAt
            return nil
        }
        let deltaRevs = revolutions &- prevRevs
        let deltaTicks = eventTime &- prevTime
        if deltaRevs > 0, deltaTicks > 0 {
            let cadence = Double(deltaRevs) / (Double(deltaTicks) / 1024) * 60
            lastRevolutionAt = receivedAt
            // A huge value means the counters jumped (sensor restart, missed rollovers): skip it.
            guard cadence < 250 else { return lastCadence }
            lastCadence = cadence
            return cadence
        }
        if let last = lastRevolutionAt, receivedAt - last >= stoppedAfter {
            lastCadence = 0
            return 0
        }
        return lastCadence
    }
}
