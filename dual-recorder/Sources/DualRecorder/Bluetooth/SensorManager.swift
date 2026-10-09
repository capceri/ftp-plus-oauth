import CoreBluetooth
import DualRecorderCore
import Foundation

/// Finds, connects and reads Bluetooth sensors. All CoreBluetooth callbacks arrive on the main queue.
///
/// Saved sensors are reconnected automatically: a CoreBluetooth connection request never times
/// out, so pedals that are asleep connect as soon as they wake up. Sensors that Zwift (or any other
/// app on this Mac) is already connected to are shared rather than fought over, and the app only
/// ever *reads* from trainers, so Zwift keeps control of resistance.
final class SensorManager: NSObject, ObservableObject {
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var sensors: [Sensor] = []
    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var isScanning = false

    /// Called for every decoded sensor notification.
    var onReading: ((Sensor, SensorReading, Date) -> Void)?

    private var central: CBCentralManager!
    /// Peripherals seen while scanning; CoreBluetooth requires us to keep them alive.
    private var scannedPeripherals: [UUID: CBPeripheral] = [:]
    private let defaultsKey = "savedSensors"

    override init() {
        super.init()
        loadSavedSensors()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var isBluetoothAuthorized: Bool {
        CBManager.authorization == .allowedAlways || CBManager.authorization == .notDetermined
    }

    func sensor(id: String) -> Sensor? {
        sensors.first { $0.id.uuidString == id }
    }

    // MARK: Scanning

    func startScan() {
        discovered = []
        isScanning = true
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: GATT.sensorServices,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        addPeripheralsConnectedElsewhere()
    }

    func stopScan() {
        isScanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    /// Sensors already connected to this Mac (e.g. by Zwift) don't advertise, so scanning can't see them.
    private func addPeripheralsConnectedElsewhere() {
        let lookups: [(CBUUID, SensorKind)] = [
            (GATT.fitnessMachine, .trainer), (GATT.cyclingPower, .powerMeter), (GATT.heartRate, .heartRate),
        ]
        for (service, kind) in lookups {
            for peripheral in central.retrieveConnectedPeripherals(withServices: [service]) {
                let name = peripheral.name ?? "Unnamed sensor"
                let guessed = kind == .powerMeter ? (GATT.guessKind(services: [service], name: name) ?? kind) : kind
                noteDiscovered(peripheral, name: name, kind: guessed, rssi: nil, connectedElsewhere: true)
            }
        }
    }

    private func noteDiscovered(_ peripheral: CBPeripheral, name: String, kind: SensorKind, rssi: Int?,
                                connectedElsewhere: Bool) {
        guard !sensors.contains(where: { $0.id == peripheral.identifier }) else { return }
        scannedPeripherals[peripheral.identifier] = peripheral
        if let index = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            // A trainer exposes both FTMS and Cycling Power: never downgrade it to a power meter.
            if discovered[index].kind != .trainer { discovered[index].kind = kind }
            if let rssi { discovered[index].rssi = rssi }
            if !name.isEmpty { discovered[index].name = name }
        } else {
            discovered.append(DiscoveredDevice(id: peripheral.identifier, name: name, kind: kind, rssi: rssi,
                                               connectedElsewhere: connectedElsewhere))
        }
    }

    // MARK: Managing saved sensors

    func add(_ device: DiscoveredDevice) {
        guard !sensors.contains(where: { $0.id == device.id }) else { return }
        let sensor = Sensor(saved: SavedSensor(id: device.id, name: device.name, nickname: "", kind: device.kind))
        sensor.peripheral = scannedPeripherals[device.id]
        sensors.append(sensor)
        discovered.removeAll { $0.id == device.id }
        save()
        connect(sensor)
    }

    func forget(_ sensor: Sensor) {
        if let peripheral = sensor.peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        sensors.removeAll { $0.id == sensor.id }
        save()
    }

    func rename(_ sensor: Sensor, to nickname: String) {
        sensor.nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
        objectWillChange.send()
    }

    func setKind(_ kind: SensorKind, for sensor: Sensor) {
        guard sensor.kind != kind else { return }
        sensor.kind = kind
        save()
        objectWillChange.send()
        // Reconnect so the right characteristics get subscribed (FTMS for trainers, CPS for power meters).
        // (A pending connection picks up the new kind when it completes.)
        if let peripheral = sensor.peripheral, sensor.state == .connected {
            unsubscribeAll(peripheral)
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func loadSavedSensors() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([SavedSensor].self, from: data) else { return }
        sensors = saved.map(Sensor.init(saved:))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sensors.map(\.saved)) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: Connecting

    private func connect(_ sensor: Sensor) {
        guard central.state == .poweredOn else { return }
        if sensor.peripheral == nil {
            sensor.peripheral = central.retrievePeripherals(withIdentifiers: [sensor.id]).first
        }
        guard let peripheral = sensor.peripheral else {
            sensor.state = .disconnected
            return
        }
        peripheral.delegate = self
        sensor.state = .connecting
        // No timeout: completes whenever the sensor is in range and awake.
        central.connect(peripheral, options: nil)
    }

    private func connectAllSaved() {
        for sensor in sensors where sensor.state == .disconnected {
            connect(sensor)
        }
    }

    private func sensor(for peripheral: CBPeripheral) -> Sensor? {
        sensors.first { $0.id == peripheral.identifier }
    }

    /// Drops our notification subscriptions. Other apps' subscriptions (Zwift's) are unaffected.
    private func unsubscribeAll(_ peripheral: CBPeripheral) {
        for service in peripheral.services ?? [] {
            for characteristic in service.characteristics ?? [] where characteristic.isNotifying {
                peripheral.setNotifyValue(false, for: characteristic)
            }
        }
    }

    // MARK: Zero offset (power meters)

    /// Sends the standard Cycling Power "Start Offset Compensation" command.
    /// Do this with the bike still and the cranks unloaded (unclipped).
    func zeroOffset(_ sensor: Sensor) {
        guard sensor.kind == .powerMeter else { return }
        guard sensor.state == .connected, let peripheral = sensor.peripheral else {
            sensor.zeroOffset = .failed("Not connected. Spin the cranks to wake the pedals, then try again.")
            return
        }
        guard let controlPoint = sensor.controlPoint else {
            sensor.zeroOffset = .failed("This sensor doesn't offer zero offset over Bluetooth.")
            return
        }
        sensor.zeroOffset = .inProgress
        sensor.zeroOffsetTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak sensor] in
            guard let sensor, sensor.zeroOffset == .inProgress else { return }
            sensor.zeroOffsetPending = false
            sensor.zeroOffset = .failed("No response from the sensor. Try again.")
        }
        sensor.zeroOffsetTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)

        if controlPoint.isNotifying {
            sendZeroOffsetRequest(peripheral, controlPoint)
        } else {
            // Responses come back as indications, which must be enabled first.
            sensor.zeroOffsetPending = true
            peripheral.setNotifyValue(true, for: controlPoint)
        }
    }

    private func sendZeroOffsetRequest(_ peripheral: CBPeripheral, _ controlPoint: CBCharacteristic) {
        peripheral.writeValue(Data(CyclingPowerControlPoint.startOffsetCompensationRequest),
                              for: controlPoint, type: .withResponse)
    }

    private func finishZeroOffset(_ sensor: Sensor, _ state: Sensor.ZeroOffsetState) {
        sensor.zeroOffsetTimeout?.cancel()
        sensor.zeroOffsetTimeout = nil
        sensor.zeroOffsetPending = false
        sensor.zeroOffset = state
    }

    private func handleControlPointResponse(_ sensor: Sensor, _ data: Data) {
        guard let response = CyclingPowerControlPoint.parseResponse(data),
              response.requestOpCode == CyclingPowerControlPoint.startOffsetCompensationOpCode,
              sensor.zeroOffset == .inProgress else { return }
        switch response.result {
        case .success:
            finishZeroOffset(sensor, .succeeded(offset: response.offset))
        case .opCodeNotSupported:
            finishZeroOffset(sensor, .failed("This sensor doesn't support zero offset over Bluetooth."))
        case .invalidParameter:
            finishZeroOffset(sensor, .failed("The sensor rejected the request."))
        case .operationFailed:
            finishZeroOffset(sensor, .failed("Zero offset failed. Unclip, keep the cranks still and try again."))
        case nil:
            finishZeroOffset(sensor, .failed("Zero offset failed (code \(response.rawResult))."))
        }
    }

    // MARK: Data

    private func deliver(_ reading: SensorReading, from sensor: Sensor) {
        guard !reading.isEmpty else { return }
        let now = Date()
        sensor.lastDataAt = now
        onReading?(sensor, reading, now)
    }
}

// MARK: - CBCentralManagerDelegate

extension SensorManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn {
            connectAllSaved()
            if isScanning { startScan() }
        } else {
            for sensor in sensors {
                sensor.state = .disconnected
                sensor.lastDataAt = nil
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unnamed sensor"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        guard let kind = GATT.guessKind(services: services, name: name) else { return }
        // 127 means "RSSI not available".
        let rssi = RSSI.intValue == 127 ? nil : RSSI.intValue
        noteDiscovered(peripheral, name: name, kind: kind, rssi: rssi, connectedElsewhere: false)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let sensor = sensor(for: peripheral) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        sensor.state = .connected
        sensor.crank = CrankCadenceCalculator()
        sensor.controlPoint = nil
        if let name = peripheral.name, !name.isEmpty, name != sensor.advertisedName {
            sensor.advertisedName = name
            save()
        }
        peripheral.delegate = self
        peripheral.discoverServices(GATT.sensorServices + [GATT.battery])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let sensor = sensor(for: peripheral) else { return }
        sensor.state = .disconnected
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak sensor] in
            guard let self, let sensor, self.sensors.contains(where: { $0 === sensor }) else { return }
            self.connect(sensor)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let sensor = sensor(for: peripheral) else { return }
        sensor.state = .disconnected
        sensor.lastDataAt = nil
        if sensor.zeroOffset == .inProgress {
            finishZeroOffset(sensor, .failed("The sensor disconnected."))
        }
        // Still saved: queue a reconnect, which completes as soon as the sensor is back.
        connect(sensor)
    }
}

// MARK: - CBPeripheralDelegate

extension SensorManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let sensor = sensor(for: peripheral), let services = peripheral.services else { return }
        // A device with the Fitness Machine service is a trainer, whatever it was first taken for.
        if services.contains(where: { $0.uuid == GATT.fitnessMachine }), sensor.kind == .powerMeter {
            sensor.kind = .trainer
            save()
        }
        for service in services {
            switch service.uuid {
            case GATT.cyclingPower:
                peripheral.discoverCharacteristics([GATT.cyclingPowerMeasurement, GATT.cyclingPowerControlPoint], for: service)
            case GATT.fitnessMachine:
                peripheral.discoverCharacteristics([GATT.indoorBikeData], for: service)
            case GATT.heartRate:
                peripheral.discoverCharacteristics([GATT.heartRateMeasurement], for: service)
            case GATT.battery:
                peripheral.discoverCharacteristics([GATT.batteryLevel], for: service)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let sensor = sensor(for: peripheral) else { return }
        let hasFTMS = peripheral.services?.contains { $0.uuid == GATT.fitnessMachine } ?? false
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case GATT.cyclingPowerMeasurement:
                // Trainers with FTMS are read through Indoor Bike Data instead, which includes cadence.
                let wanted = sensor.kind == .powerMeter || (sensor.kind == .trainer && !hasFTMS)
                if wanted { peripheral.setNotifyValue(true, for: characteristic) }
            case GATT.cyclingPowerControlPoint:
                // Only power meters get calibration. Nothing is ever written to a trainer.
                if sensor.kind == .powerMeter { sensor.controlPoint = characteristic }
            case GATT.indoorBikeData:
                if sensor.kind == .trainer { peripheral.setNotifyValue(true, for: characteristic) }
            case GATT.heartRateMeasurement:
                if sensor.kind == .heartRate { peripheral.setNotifyValue(true, for: characteristic) }
            case GATT.batteryLevel:
                if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
                if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let sensor = sensor(for: peripheral),
              characteristic.uuid == GATT.cyclingPowerControlPoint, sensor.zeroOffsetPending else { return }
        sensor.zeroOffsetPending = false
        if let error {
            finishZeroOffset(sensor, .failed("Couldn't start zero offset: \(error.localizedDescription)"))
        } else {
            sendZeroOffsetRequest(peripheral, characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let sensor = sensor(for: peripheral), characteristic.uuid == GATT.cyclingPowerControlPoint,
              let error else { return }
        finishZeroOffset(sensor, .failed("Couldn't send zero offset: \(error.localizedDescription)"))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let sensor = sensor(for: peripheral), let data = characteristic.value else { return }
        switch characteristic.uuid {
        case GATT.cyclingPowerMeasurement:
            guard let measurement = CyclingPowerMeasurement.parse(data) else { return }
            var cadence: Double?
            if let revs = measurement.cumulativeCrankRevolutions, let time = measurement.lastCrankEventTime {
                cadence = sensor.crank.update(revolutions: revs, eventTime: time,
                                              receivedAt: ProcessInfo.processInfo.systemUptime)
            }
            deliver(SensorReading(measurement, cadence: cadence), from: sensor)
        case GATT.indoorBikeData:
            guard let bikeData = IndoorBikeData.parse(data) else { return }
            deliver(SensorReading(bikeData), from: sensor)
        case GATT.heartRateMeasurement:
            guard let bpm = HeartRateMeasurement.parse(data), bpm > 0 else { return }
            deliver(SensorReading(heartRate: bpm), from: sensor)
        case GATT.cyclingPowerControlPoint:
            handleControlPointResponse(sensor, data)
        case GATT.batteryLevel:
            if let level = data.first { sensor.battery = Int(min(level, 100)) }
        default:
            break
        }
    }
}
