import Foundation

/// The FIT base types (low 5 bits of the base type byte in a field definition).
public enum FITBaseType: UInt8, CaseIterable, Sendable {
    case enumeration = 0, sint8, uint8, sint16, uint16, sint32, uint32, string, float32, float64,
         uint8z, uint16z, uint32z, byte, sint64, uint64, uint64z

    public init?(definitionByte: UInt8) {
        self.init(rawValue: definitionByte & 0x1F)
    }

    /// The byte written in definition messages (bit 7 marks multi-byte types).
    public var definitionByte: UInt8 { size > 1 ? rawValue | 0x80 : rawValue }

    public var size: Int {
        switch self {
        case .enumeration, .sint8, .uint8, .string, .uint8z, .byte: return 1
        case .sint16, .uint16, .uint16z: return 2
        case .sint32, .uint32, .float32, .uint32z: return 4
        case .float64, .sint64, .uint64, .uint64z: return 8
        }
    }

    public var name: String {
        switch self {
        case .enumeration: return "enum"
        default: return String(describing: self)
        }
    }

    /// Whether values are quantities that can be plotted and scaled (not enums, strings or raw bytes).
    public var isNumeric: Bool {
        switch self {
        case .enumeration, .string, .byte: return false
        default: return true
        }
    }

    var isSigned: Bool {
        switch self {
        case .sint8, .sint16, .sint32, .sint64: return true
        default: return false
        }
    }

    var isFloat: Bool { self == .float32 || self == .float64 }

    var isZeroInvalid: Bool { self == .uint8z || self == .uint16z || self == .uint32z || self == .uint64z }

    /// Reads one value at `offset`. Returns nil for the type's "invalid" marker (no data).
    public func read(_ bytes: [UInt8], at offset: Int, bigEndian: Bool) -> Double? {
        let bits = FITBaseType.readBits(bytes, at: offset, count: size, bigEndian: bigEndian)
        switch self {
        case .enumeration, .uint8, .byte:
            return bits == 0xFF ? nil : Double(bits)
        case .uint16:
            return bits == 0xFFFF ? nil : Double(bits)
        case .uint32:
            return bits == 0xFFFF_FFFF ? nil : Double(bits)
        case .uint64:
            return bits == UInt64.max ? nil : Double(bits)
        case .uint8z, .uint16z, .uint32z, .uint64z:
            return bits == 0 ? nil : Double(bits)
        case .sint8:
            return bits == 0x7F ? nil : Double(Int8(truncatingIfNeeded: bits))
        case .sint16:
            return bits == 0x7FFF ? nil : Double(Int16(truncatingIfNeeded: bits))
        case .sint32:
            return bits == 0x7FFF_FFFF ? nil : Double(Int32(truncatingIfNeeded: bits))
        case .sint64:
            return bits == 0x7FFF_FFFF_FFFF_FFFF ? nil : Double(Int64(bitPattern: bits))
        case .float32:
            guard bits != 0xFFFF_FFFF else { return nil }
            let value = Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
            return value.isFinite ? value : nil
        case .float64:
            guard bits != UInt64.max else { return nil }
            let value = Double(bitPattern: bits)
            return value.isFinite ? value : nil
        case .string:
            return nil
        }
    }

    /// Writes `value` (a raw, unscaled value) at `offset`, rounded and clamped to the type's valid
    /// range so it never turns into the "invalid" marker. Does nothing for non-numeric types.
    public func write(_ value: Double, into bytes: inout [UInt8], at offset: Int, bigEndian: Bool) {
        guard isNumeric, value.isFinite else { return }
        let bits: UInt64
        switch self {
        case .float32:
            bits = UInt64(Float(value).bitPattern)
        case .float64:
            bits = value.bitPattern
        case .sint8:
            bits = UInt64(truncatingIfNeeded: Int64(clamp(value.rounded(), -128, 126)))
        case .sint16:
            bits = UInt64(truncatingIfNeeded: Int64(clamp(value.rounded(), -32768, 32766)))
        case .sint32:
            bits = UInt64(truncatingIfNeeded: Int64(clamp(value.rounded(), -2_147_483_648, 2_147_483_646)))
        case .sint64:
            bits = UInt64(bitPattern: FITBaseType.int64(value.rounded()))
        case .uint8:
            bits = UInt64(clamp(value.rounded(), 0, 254))
        case .uint8z:
            bits = UInt64(clamp(value.rounded(), 1, 255))
        case .uint16:
            bits = UInt64(clamp(value.rounded(), 0, 65534))
        case .uint16z:
            bits = UInt64(clamp(value.rounded(), 1, 65535))
        case .uint32:
            bits = UInt64(clamp(value.rounded(), 0, 4_294_967_294))
        case .uint32z:
            bits = UInt64(clamp(value.rounded(), 1, 4_294_967_295))
        case .uint64:
            bits = min(FITBaseType.uint64(value.rounded()), UInt64.max - 1)
        case .uint64z:
            bits = max(FITBaseType.uint64(value.rounded()), 1)
        case .enumeration, .string, .byte:
            return
        }
        FITBaseType.writeBits(bits, into: &bytes, at: offset, count: size, bigEndian: bigEndian)
    }

    static func readBits(_ bytes: [UInt8], at offset: Int, count: Int, bigEndian: Bool) -> UInt64 {
        var value: UInt64 = 0
        if bigEndian {
            for i in 0..<count { value = value << 8 | UInt64(bytes[offset + i]) }
        } else {
            for i in stride(from: count - 1, through: 0, by: -1) { value = value << 8 | UInt64(bytes[offset + i]) }
        }
        return value
    }

    static func writeBits(_ value: UInt64, into bytes: inout [UInt8], at offset: Int, count: Int, bigEndian: Bool) {
        for i in 0..<count {
            let byte = UInt8(truncatingIfNeeded: value >> UInt64(8 * i))
            bytes[offset + (bigEndian ? count - 1 - i : i)] = byte
        }
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        Swift.min(Swift.max(value, low), high)
    }

    private static func int64(_ value: Double) -> Int64 {
        if value <= -9.223372036854775e18 { return Int64.min }
        if value >= 9.223372036854775e18 { return Int64.max - 1 }
        return Int64(value)
    }

    private static func uint64(_ value: Double) -> UInt64 {
        if value <= 0 { return 0 }
        if value >= 1.8446744073709550e19 { return UInt64.max }
        return UInt64(value)
    }
}
