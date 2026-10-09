import AppKit
import DualRecorderCore
import SwiftUI

struct SummaryView: View {
    let summary: RideSummary
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: summary.files.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(summary.files.isEmpty ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.eventName.isEmpty ? "Ride saved" : summary.eventName)
                        .font(.title2.bold())
                    Text("\(summary.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Format.duration(summary.duration))")
                        .foregroundStyle(Color.secondary)
                }
            }

            if let error = recorder.lastError {
                Text(error)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !summary.sources.isEmpty {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Avg")
                        Text("NP")
                        Text("Max")
                        Text("Cadence")
                        Text("HR")
                        Text("Data")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    Divider()
                    ForEach(summary.sources, id: \.source.id) { stats in
                        GridRow {
                            Label(stats.source.name, systemImage: stats.source.kind.symbol)
                                .lineLimit(1)
                            Text(Format.watts(stats.averagePower))
                            Text(Format.watts(stats.normalizedPower))
                            Text(Format.watts(stats.maxPower))
                            Text(stats.averageCadence.map { "\($0) rpm" } ?? "–")
                            Text(stats.averageHeartRate.map { "\($0) bpm" } ?? "–")
                            Text(Format.percent(stats.coverage * 100, signed: false))
                                .foregroundStyle(stats.coverage < 0.99 ? Color.orange : Color.primary)
                        }
                        .monospacedDigit()
                    }
                }
                if summary.sources.contains(where: { $0.coverage < 0.99 }) {
                    Text("“Data” under 100% means that sensor dropped out for part of the ride.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }

            if let comparison = summary.comparison, let diff = comparison.differencePercent {
                let direction = diff >= 0 ? "higher" : "lower"
                Label {
                    Text("\(comparison.reference.name) read \(String(format: "%.1f", abs(diff)))% \(direction) than \(comparison.other.name): \(Int(comparison.referenceAverage.rounded())) W vs \(Int(comparison.otherAverage.rounded())) W over \(Format.duration(TimeInterval(comparison.overlapSeconds))).")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(Color.purple)
                }
            }

            if !summary.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved to \(summary.files[0].deletingLastPathComponent().path)")
                        .font(.headline)
                    ForEach(summary.files, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "doc")
                            .textSelection(.enabled)
                    }
                }
            }

            HStack {
                if !summary.files.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(summary.files)
                    }
                }
                Spacer()
                Button("Done") { recorder.dismissSummary() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 600)
    }
}
