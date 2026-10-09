import CoreBluetooth
import DualRecorderCore
import Foundation

/// Bluetooth GATT identifiers used by the app.
enum GATT {
    static let cyclingPower = CBUUID(string: "1818")
    static let cyclingPowerMeasurement = CBUUID(string: "2A63")
    static let cyclingPowerControlPoint = CBUUID(string: "2A66")

    static let heartRate = CBUUID(string: "180D")
    static let heartRateMeasurement = CBUUID(string: "2A37")

    static let fitnessMachine = CBUUID(string: "1826")
    static let indoorBikeData = CBUUID(string: "2AD2")

    static let battery = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")

    static let sensorServices = [cyclingPower, heartRate, fitnessMachine]

    /// Best guess at what a newly found device is. The user can change power meter / trainer later.
    static func guessKind(services: [CBUUID], name: String) -> SensorKind? {
        if services.contains(fitnessMachine) { return .trainer }
        if services.contains(cyclingPower) {
            let trainerNames = ["KICKR", "TACX", "NEO", "FLUX", "ELITE", "DIRETO", "SUITO", "JUSTO", "SARIS",
                                "ZWIFT HUB", "WATTBIKE", "JETBLACK", "MAGENE", "THINKRIDER"]
            let upper = name.uppercased()
            return trainerNames.contains { upper.contains($0) } && !upper.contains("ASSIOMA") ? .trainer : .powerMeter
        }
        if services.contains(heartRate) { return .heartRate }
        return nil
    }
}

/// A sensor the user added. Holds connection state, the latest values and zero-offset status.
final class Sensor: ObservableObject, Identifiable {
    enum ConnectionState {
        case disconnected, connecting, connected
    }

    enum ZeroOffsetState: Equatable {
        case idle
        case inProgress
        case succeeded(offset: Int?)
        case failed(String)
    }

    /// What the connection indicator shows.
    enum LinkStatus: Equatable {
        /// Switched off: not connected, not recorded.
        case off
        case bluetoothUnavailable
        /// Waiting for the sensor to come into range or wake up.
        case searching
        case connectedNoData
        case live
    }

    let id: UUID
    @Published var advertisedName: String
    @Published var nickname: String
    @Published var kind: SensorKind
    /// Record switch. When off the sensor is disconnected and left out of rides.
    @Published var isEnabled: Bool
    @Published var state: ConnectionState = .disconnected
    @Published var battery: Int?
    @Published var zeroOffset: ZeroOffsetState = .idle
    /// When the last decoded notification arrived. Not published: it changes several times a second.
    var lastDataAt: Date?

    // CoreBluetooth bookkeeping.
    var peripheral: CBPeripheral?
    var controlPoint: CBCharacteristic?
    var crank = CrankCadenceCalculator()
    var zeroOffsetPending = false
    var zeroOffsetTimeout: DispatchWorkItem?

    init(saved: SavedSensor) {
        id = saved.id
        advertisedName = saved.name
        nickname = saved.nickname
        kind = saved.kind
        isEnabled = saved.isEnabled
    }

    var displayName: String {
        let trimmed = nickname.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? advertisedName : trimmed
    }

    var sourceInfo: SourceInfo {
        SourceInfo(id: id.uuidString, name: displayName, kind: kind)
    }

    var saved: SavedSensor {
        SavedSensor(id: id, name: advertisedName, nickname: nickname, kind: kind, isEnabled: isEnabled)
    }

    /// True if the sensor delivered data within `seconds`.
    func isLive(within seconds: TimeInterval = 5, now: Date = Date()) -> Bool {
        guard state == .connected, let last = lastDataAt else { return false }
        return now.timeIntervalSince(last) <= seconds
    }

    func linkStatus(bluetoothOn: Bool, now: Date = Date()) -> LinkStatus {
        guard isEnabled else { return .off }
        guard bluetoothOn else { return .bluetoothUnavailable }
        switch state {
        case .connected:
            return isLive(within: 5, now: now) ? .live : .connectedNoData
        case .connecting, .disconnected:
            return .searching
        }
    }
}

/// A device found while scanning that hasn't been added yet.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var kind: SensorKind
    var rssi: Int?
    /// Already connected to the Mac by another app (typically Zwift); it can be shared.
    var connectedElsewhere: Bool
}
