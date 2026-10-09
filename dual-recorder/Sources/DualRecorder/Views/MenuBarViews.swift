import AppKit
import DualRecorderCore
import SwiftUI

/// The menu bar item: an icon, plus live power and a warning symbol while recording.
struct MenuBarLabel: View {
    @ObservedObject var recorder: RecordingController
    @ObservedObject var sensors: SensorManager

    var body: some View {
        if recorder.isRecording {
            Image(systemName: recorder.silentSources.isEmpty ? "record.circle" : "exclamationmark.triangle.fill")
            Text(labelText)
        } else {
            Image(systemName: "bolt.circle")
        }
    }

    private var labelText: String {
        let meter = sensors.sensors.first { $0.kind == .powerMeter } ?? sensors.sensors.first { $0.kind.measuresPower }
        if let meter, let watts = recorder.displayPower(for: meter.id.uuidString) {
            return "\(watts) W"
        }
        return Format.duration(recorder.elapsed)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var sensors: SensorManager
    @EnvironmentObject private var recorder: RecordingController
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(recorder.isRecording ? "Recording" : "Dual Recorder")
                    .font(.headline)
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
                Spacer()
                if recorder.isRecording {
                    Text(Format.duration(recorder.elapsed))
                        .font(.headline)
                        .monospacedDigit()
                }
            }

            if sensors.sensors.isEmpty {
                Text("No sensors added yet.").foregroundStyle(Color.secondary)
            }
            ForEach(sensors.sensors) { sensor in
                MenuBarSensorRow(sensor: sensor)
            }
            if let live = recorder.liveComparison {
                Text("Gap (10 s): \(comparisonText(live))")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Divider()

            if recorder.isRecording {
                Button {
                    if confirmingStop {
                        confirmingStop = false
                        recorder.stop()
                    } else {
                        confirmingStop = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirmingStop = false }
                    }
                } label: {
                    Text(confirmingStop ? "Click again to stop & save" : "Stop & Save")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    recorder.start()
                } label: {
                    Text("Start Recording").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            HStack {
                Button("Open Window") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct MenuBarSensorRow: View {
    @ObservedObject var sensor: Sensor
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: sensor.kind.symbol)
                .foregroundStyle(sensor.kind.tint)
                .frame(width: 18)
            Circle()
                .fill(sensor.state == .connected && sensor.isLive(within: 5) ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(sensor.displayName).lineLimit(1)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(recorder.silentSources.contains(sensor.id.uuidString) ? Color.red : Color.primary)
        }
    }

    private var value: String {
        let id = sensor.id.uuidString
        if sensor.kind == .heartRate {
            return recorder.values(for: id)?.heartRate.map { "\($0) bpm" } ?? "–"
        }
        return recorder.displayPower(for: id).map { "\($0) W" } ?? "–"
    }
}
