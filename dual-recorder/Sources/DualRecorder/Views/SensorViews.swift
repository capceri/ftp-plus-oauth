import DualRecorderCore
import SwiftUI

struct SensorsPanel: View {
    @EnvironmentObject private var sensors: SensorManager
    @EnvironmentObject private var recorder: RecordingController
    @State private var addingSensor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sensors").font(.headline)
                Spacer()
                Button {
                    addingSensor = true
                } label: {
                    Label("Add Sensor…", systemImage: "plus")
                }
                .disabled(sensors.bluetoothState != .poweredOn)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    if sensors.sensors.isEmpty {
                        Text("No sensors yet. Wake your Assioma pedals by turning the cranks, then click Add Sensor. Sensors are remembered and reconnect automatically.")
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 8)
                    }
                    ForEach(sensors.sensors) { sensor in
                        SensorRow(sensor: sensor)
                        if sensor.id != sensors.sensors.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .sheet(isPresented: $addingSensor) {
            AddSensorSheet()
                .environmentObject(sensors)
        }
    }
}

struct SensorRow: View {
    @ObservedObject var sensor: Sensor
    @EnvironmentObject private var sensors: SensorManager
    @EnvironmentObject private var recorder: RecordingController
    @State private var renaming = false
    @State private var draftName = ""
    @State private var confirmingForget = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sensor.kind.symbol)
                .font(.title2)
                .foregroundStyle(sensor.kind.tint)
                .frame(width: 30)
                .opacity(sensor.isEnabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(sensor.displayName).font(.body.weight(.medium))
                    Text(sensor.kind.label)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                .opacity(sensor.isEnabled ? 1 : 0.55)
                HStack(spacing: 8) {
                    StatusBadge(status: status)
                    if sensor.isEnabled, let battery = sensor.battery {
                        Label("\(battery)%", systemImage: batterySymbol(battery))
                            .font(.caption)
                            .foregroundStyle(battery <= 15 ? Color.red : Color.secondary)
                    }
                }
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                if let zero = zeroOffsetMessage {
                    Text(zero.text)
                        .font(.caption)
                        .foregroundStyle(zero.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if sensor.isEnabled {
                Text(liveText)
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .monospacedDigit()
            }
            if sensor.kind == .powerMeter && sensor.isEnabled {
                Button("Zero Offset") { sensors.zeroOffset(sensor) }
                    .disabled(sensor.state != .connected || sensor.zeroOffset == .inProgress)
                    .help("Calibrate the power meter. Unclip, keep the cranks still, then click.")
            }
            Toggle("Record", isOn: Binding(get: { sensor.isEnabled },
                                           set: { sensors.setEnabled($0, for: sensor) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(recorder.isRecording)
                .help(toggleHelp)
            Menu {
                Button("Rename…") {
                    draftName = sensor.displayName
                    renaming = true
                }
                if sensor.kind.measuresPower {
                    Picker("Use As", selection: Binding(get: { sensor.kind },
                                                        set: { sensors.setKind($0, for: sensor) })) {
                        Text("Power meter (pedals, cranks…)").tag(SensorKind.powerMeter)
                        Text("Smart trainer").tag(SensorKind.trainer)
                    }
                    // Changing it reconnects the sensor, which would leave a gap in a ride.
                    .disabled(recorder.isRecording)
                }
                Divider()
                Button("Forget Sensor…", role: .destructive) { confirmingForget = true }
                    .disabled(recorder.isRecording)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 10)
        .alert("Rename Sensor", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Save") { sensors.rename(sensor, to: draftName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The name is shown here and used in the FIT file name.")
        }
        .confirmationDialog("Forget \(sensor.displayName)?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { sensors.forget(sensor) }
        } message: {
            Text("It will be disconnected and removed from the list. You can add it again later.")
        }
    }

    private var status: Sensor.LinkStatus {
        sensor.linkStatus(bluetoothOn: sensors.bluetoothState == .poweredOn)
    }

    private var hint: String? {
        switch status {
        case .off:
            return "Not recorded. Switch on to connect it."
        case .searching where sensor.kind == .powerMeter:
            return "Turn the cranks to wake the pedals."
        default:
            return nil
        }
    }

    private var toggleHelp: String {
        if recorder.isRecording { return "Locked while recording." }
        return sensor.isEnabled
            ? "Recorded. Switch off to disconnect it and leave it out of rides."
            : "Not recorded. Switch on to connect and record it."
    }

    private var liveText: String {
        let values = recorder.values(for: sensor.id.uuidString)
        switch sensor.kind {
        case .heartRate:
            return values?.heartRate.map { "\($0) bpm" } ?? "–"
        case .powerMeter, .trainer:
            return recorder.displayPower(for: sensor.id.uuidString).map { "\($0) W" } ?? "–"
        }
    }

    private var zeroOffsetMessage: (text: String, color: Color)? {
        guard sensor.isEnabled else { return nil }
        switch sensor.zeroOffset {
        case .idle:
            return nil
        case .inProgress:
            return ("Zeroing… keep the cranks still.", .orange)
        case .succeeded(let offset):
            return (offset.map { "Zero offset done (offset \($0))." } ?? "Zero offset done.", .green)
        case .failed(let message):
            return (message, .red)
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

/// Coloured capsule showing whether a sensor is connected.
struct StatusBadge: View {
    let status: Sensor.LinkStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(status.label)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(status == .off ? Color.secondary : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(status.color.opacity(0.16)))
    }
}

/// One line above the Start button saying which sensors are connected.
struct ConnectionSummary: View {
    @EnvironmentObject private var sensors: SensorManager
    // Observed so the summary refreshes every second along with the live data.
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        let bluetoothOn = sensors.bluetoothState == .poweredOn
        let enabled = sensors.sensors.filter(\.isEnabled)
        let liveCount = enabled.filter { $0.linkStatus(bluetoothOn: bluetoothOn) == .live }.count
        let allLive = !enabled.isEmpty && liveCount == enabled.count
        HStack(spacing: 10) {
            Image(systemName: allLive ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(allLive ? Color.green : Color.orange)
            Text(sensors.sensors.isEmpty ? "No sensors added yet"
                 : headline(enabled: enabled.count, live: liveCount, bluetoothOn: bluetoothOn))
                .font(.callout.weight(.medium))
            Spacer(minLength: 8)
            ForEach(enabled) { sensor in
                SensorChip(sensor: sensor, bluetoothOn: bluetoothOn)
            }
        }
    }

    private func headline(enabled: Int, live: Int, bluetoothOn: Bool) -> String {
        if enabled == 0 { return "No sensors switched on to record" }
        if !bluetoothOn { return "Bluetooth is off" }
        if live == enabled { return enabled == 1 ? "Sensor connected" : "All \(enabled) sensors connected" }
        return "\(live) of \(enabled) sensors connected"
    }
}

struct SensorChip: View {
    @ObservedObject var sensor: Sensor
    let bluetoothOn: Bool

    var body: some View {
        let status = sensor.linkStatus(bluetoothOn: bluetoothOn)
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(sensor.displayName)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(status.color.opacity(0.16)))
        .help("\(sensor.displayName): \(status.label)")
    }
}

struct AddSensorSheet: View {
    @EnvironmentObject private var sensors: SensorManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add Sensor").font(.title2.bold())
                Spacer()
                ProgressView().controlSize(.small)
            }
            Text("Wake your sensors: turn the Assioma cranks, wear the heart-rate strap. Sensors that Zwift is already connected to on this Mac show up too; they are shared, not taken away from Zwift.")
                .font(.callout)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                if sensors.discovered.isEmpty {
                    Text("Searching…").foregroundStyle(Color.secondary)
                }
                ForEach(sensors.discovered) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.kind.symbol)
                            .foregroundStyle(device.kind.tint)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(detail(for: device))
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        Button("Add") { sensors.add(device) }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 440)
        .onAppear { sensors.startScan() }
        .onDisappear { sensors.stopScan() }
    }

    private func detail(for device: DiscoveredDevice) -> String {
        if device.connectedElsewhere { return "\(device.kind.label) · in use by another app (will be shared)" }
        guard let rssi = device.rssi else { return device.kind.label }
        return "\(device.kind.label) · signal \(rssi) dBm"
    }
}
