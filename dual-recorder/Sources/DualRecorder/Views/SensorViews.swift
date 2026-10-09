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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(sensor.displayName).font(.body.weight(.medium))
                    Text(sensor.kind.label)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.caption).foregroundStyle(Color.secondary)
                    if let battery = sensor.battery {
                        Label("\(battery)%", systemImage: batterySymbol(battery))
                            .font(.caption)
                            .foregroundStyle(battery <= 15 ? Color.red : Color.secondary)
                    }
                }
                if let zero = zeroOffsetMessage {
                    Text(zero.text)
                        .font(.caption)
                        .foregroundStyle(zero.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(liveText)
                .font(.system(.title3, design: .rounded).weight(.medium))
                .monospacedDigit()
            if sensor.kind == .powerMeter {
                Button("Zero Offset") { sensors.zeroOffset(sensor) }
                    .disabled(sensor.state != .connected || sensor.zeroOffset == .inProgress)
                    .help("Calibrate the power meter. Unclip, keep the cranks still, then click.")
            }
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
                }
                Divider()
                Button("Forget Sensor…", role: .destructive) { confirmingForget = true }
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
            Text("It will be disconnected and no longer recorded. You can add it again later.")
        }
    }

    private var isLive: Bool {
        sensor.isLive(within: 5)
    }

    private var statusColor: Color {
        sensor.state == .connected && !isLive ? .orange : sensor.state.color
    }

    private var statusText: String {
        if sensor.state == .connected && !isLive { return "Connected · no data yet" }
        if sensor.state == .connecting && sensor.kind == .powerMeter { return "Waiting… turn the cranks to wake it" }
        return sensor.state.label
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
