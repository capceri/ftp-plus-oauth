import CoreBluetooth
import DualRecorderCore
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var sensors: SensorManager
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BluetoothStatusBanner()
                ForEach(recorder.recoverableRides) { item in
                    RecoveryBanner(item: item)
                }
                if let error = recorder.lastError, !recorder.showingSummary {
                    Banner(text: error, symbol: "exclamationmark.triangle.fill", tint: .orange)
                }
                RecordingPanel()
                SensorsPanel()
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 620)
        .sheet(isPresented: $recorder.showingSummary) {
            if let summary = recorder.summary {
                SummaryView(summary: summary)
                    .environmentObject(recorder)
            }
        }
    }
}

struct Banner: View {
    var text: String
    var symbol: String
    var tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .foregroundStyle(Color.primary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.18)))
    }
}

struct BluetoothStatusBanner: View {
    @EnvironmentObject private var sensors: SensorManager

    var body: some View {
        if let message {
            Banner(text: message, symbol: "exclamationmark.triangle.fill", tint: .yellow)
        }
    }

    private var message: String? {
        switch sensors.bluetoothState {
        case .poweredOff:
            return "Bluetooth is off. Turn it on to connect your sensors."
        case .unauthorized:
            return "Dual Recorder isn't allowed to use Bluetooth. Allow it in System Settings › Privacy & Security › Bluetooth."
        case .unsupported:
            return "This Mac doesn't support Bluetooth Low Energy."
        default:
            return nil
        }
    }
}

struct RecoveryBanner: View {
    let item: RecoverableRide
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.title)
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unfinished ride found").bold()
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            Button("Discard", role: .destructive) { recorder.discard(item) }
            Button("Save FIT Files") { recorder.recover(item) }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.isRecording)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.15)))
    }

    private var subtitle: String {
        var parts = [item.ride.startedAt.formatted(date: .abbreviated, time: .shortened),
                     Format.duration(TimeInterval(item.ride.samples.count))]
        if !item.ride.eventName.isEmpty { parts.append(item.ride.eventName) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Recording

struct RecordingPanel: View {
    // Observed so the Start button reacts as soon as a record switch changes.
    @EnvironmentObject private var sensors: SensorManager
    @EnvironmentObject private var recorder: RecordingController
    @State private var confirmingStop = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    if recorder.isRecording {
                        Label("Recording", systemImage: "record.circle")
                            .font(.headline)
                            .foregroundStyle(Color.red)
                    } else {
                        Text("Ready to record")
                            .font(.headline)
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    Text(Format.duration(recorder.elapsed))
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(recorder.isRecording ? Color.primary : Color.secondary)
                }

                TextField("Event name (optional, added to the file name)", text: $recorder.eventName)
                    .textFieldStyle(.roundedBorder)

                ConnectionSummary()

                LiveTiles()

                if recorder.isRecording {
                    Button(role: .destructive) {
                        confirmingStop = true
                    } label: {
                        Label("Stop & Save", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                } else {
                    Button {
                        recorder.start()
                    } label: {
                        Label("Start Recording", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                    .disabled(!recorder.hasRecordableSensors)
                }

                HStack {
                    Text("When you stop, one FIT file per power source is saved to your Documents folder.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    if !recorder.isRecording, recorder.summary != nil {
                        Button("Last Ride…") { recorder.showingSummary = true }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            .padding(8)
        }
        .confirmationDialog("Stop recording and save the FIT files?", isPresented: $confirmingStop) {
            Button("Stop & Save", role: .destructive) { recorder.stop() }
            Button("Keep Recording", role: .cancel) {}
        }
    }
}

struct LiveTiles: View {
    @EnvironmentObject private var sensors: SensorManager
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        let powerSensors = sensors.sensors.filter { $0.isEnabled && $0.kind.measuresPower }
        let heartRateSensor = sensors.sensors.first { $0.isEnabled && $0.kind == .heartRate }
        if powerSensors.isEmpty && heartRateSensor == nil {
            Text(sensors.sensors.isEmpty
                 ? "Add your sensors below to see live data here."
                 : "Switch on the sensors you want to record below.")
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(powerSensors) { sensor in
                    let id = sensor.id.uuidString
                    Tile(title: sensor.displayName, symbol: sensor.kind.symbol, tint: sensor.kind.tint,
                         value: recorder.displayPower(for: id).map(String.init) ?? "–", unit: "W",
                         detail: recorder.values(for: id)?.cadence.map { "\($0) rpm" } ?? "– rpm",
                         warning: recorder.silentSources.contains(id))
                }
                if let sensor = heartRateSensor {
                    let id = sensor.id.uuidString
                    Tile(title: sensor.displayName, symbol: "heart.fill", tint: .red,
                         value: recorder.values(for: id)?.heartRate.map(String.init) ?? "–", unit: "bpm",
                         detail: "Heart rate", warning: recorder.silentSources.contains(id))
                }
                if let live = recorder.liveComparison {
                    Tile(title: "\(live.reference.name) vs \(live.other.name)", symbol: "arrow.left.arrow.right",
                         tint: .purple, value: Format.percent(live.differencePercent), unit: "",
                         detail: recorder.isRecording
                            ? "10 s · ride \(Format.percent(recorder.rideComparison?.differencePercent))"
                            : "last 10 s")
                }
            }
        }
    }
}

struct Tile: View {
    var title: String
    var symbol: String
    var tint: Color
    var value: String
    var unit: String
    var detail: String
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: warning ? "exclamationmark.triangle.fill" : symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(warning ? Color.red : tint)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(unit)
                    .foregroundStyle(Color.secondary)
            }
            Text(warning ? "No data" : detail)
                .font(.caption)
                .foregroundStyle(warning ? Color.red : Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(warning ? Color.red : Color.clear, lineWidth: 2))
    }
}
