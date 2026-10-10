import AppKit
import FITStudioCore
import SwiftUI

struct AdjustView: View {
    @EnvironmentObject private var store: FileStore
    @ObservedObject var file: LoadedFile
    @AppStorage(SettingsKey.unitSystem) private var system: UnitSystem = .metric
    @AppStorage("linkSpeedDistance") private var linkSpeedDistance = true
    @State private var allPercent: Double = 0

    private var activity: Activity { file.activity }
    private var adjustable: [Channel] { activity.channels.filter(\.isAdjustable) }
    private var fixed: [Channel] { activity.channels.filter { !$0.isAdjustable } }
    private var hasSpeedAndDistance: Bool { activity.channel(.speed) != nil && activity.channel(.distance) != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro
                if let save = file.lastSave {
                    savedBanner(save.report, url: save.url)
                }
                allChannelsRow
                channelGrid
                if !fixed.isEmpty {
                    fixedChannels
                }
                actions
            }
            .padding(20)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Adjust by percentage").font(.title2.bold())
            Text("Every recorded value of a channel is multiplied by the percentage you set, e.g. +2.5% turns 200 W into 205 W. Lap and session values that come from it (averages, maximums, totals, NP, TSS) are updated to match, so the file stays consistent. Everything else is copied unchanged.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your original file is never changed. Use Save Adjusted Copy to write a new file. Charts, Summary and Compare already show the adjusted values.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func savedBanner(_ report: AdjustmentReport, url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved “\(url.lastPathComponent)”").bold()
                Text("\(report.totalValuesChanged.formatted()) recorded values and \(report.summaryValuesChanged.formatted()) lap/session values adjusted\(report.repairedTruncatedFile ? ". The incomplete original was repaired in the copy" : "").\(file.hasUnsavedAdjustments ? " You’ve changed the adjustments since." : "")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Open Copy") { store.open([url]) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12)))
    }

    private var allChannelsRow: some View {
        HStack(spacing: 10) {
            Text("Set every channel to")
            TextField("Percent", value: $allPercent, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text("%")
            Button("Apply to All") {
                for channel in adjustable { file.setAdjustment(channel.key, to: allPercent) }
            }
            Spacer()
            if hasSpeedAndDistance {
                Toggle("Keep speed and distance in step", isOn: $linkSpeedDistance)
                    .help("Changing one also changes the other, so speed × time still matches distance.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private var channelGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("Channel")
                Text("Adjustment").gridCellColumns(2)
                Text("Average").gridColumnAlignment(.trailing)
                Text("Maximum").gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(adjustable) { channel in
                AdjustRow(file: file, channel: channel, system: system, percent: binding(channel.key),
                          linked: file.linkedSummaryFields(channel.key))
                Divider()
            }
        }
    }

    private var fixedChannels: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not adjustable").font(.headline)
            ForEach(fixed) { channel in
                Text("\(channel.name): \(reason(channel))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reason(_ channel: Channel) -> String {
        if let leader = FITAdjuster.followers[channel.key.rawValue], let name = activity.channel(ChannelKey(leader))?.name {
            return "follows \(name) automatically."
        }
        if channel.key == .balance { return "a left/right split, which a percentage would distort." }
        return "not a measurement that can be scaled."
    }

    private var actions: some View {
        HStack {
            Button("Reset All") {
                file.resetAdjustments()
                allPercent = 0
            }
            .disabled(!file.hasAdjustments)
            Spacer()
            Button {
                store.saveAdjustedCopy(of: file)
            } label: {
                Label("Save Adjusted Copy…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!file.hasAdjustments)
        }
    }

    private func binding(_ key: ChannelKey) -> Binding<Double> {
        Binding(
            get: { file.adjustment(key) },
            set: { value in
                file.setAdjustment(key, to: value)
                guard linkSpeedDistance, hasSpeedAndDistance else { return }
                if key == .speed { file.setAdjustment(.distance, to: value) }
                if key == .distance { file.setAdjustment(.speed, to: value) }
            })
    }
}

private struct AdjustRow: View {
    @ObservedObject var file: LoadedFile
    let channel: Channel
    let system: UnitSystem
    @Binding var percent: Double
    let linked: [String]

    var body: some View {
        let stats = file.stats(channel.key)
        let factor = 1 + percent / 100
        GridRow(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(channel.name).bold()
                } icon: {
                    Image(systemName: ChannelStyle.symbol(channel.key)).foregroundStyle(ChannelStyle.color(channel.key))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 280, alignment: .leading)
            }
            Slider(value: $percent, in: -25...25, step: 0.5)
                .frame(minWidth: 140, maxWidth: 220)
                .tint(percent == 0 ? .secondary : ChannelStyle.color(channel.key))
            HStack(spacing: 4) {
                TextField("0", value: $percent, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Text("%")
                Stepper("", value: $percent, in: -99...500, step: 0.5).labelsHidden()
            }
            beforeAfter(stats?.average, factor: factor)
                .gridColumnAlignment(.trailing)
            beforeAfter(stats?.maximum, factor: factor)
                .gridColumnAlignment(.trailing)
        }
    }

    private var detail: String {
        var text = "\(channel.values.compactMap { $0 }.count.formatted()) values"
        if !linked.isEmpty { text += " · also updates " + linked.prefix(6).joined(separator: ", ").lowercased() }
        if linked.count > 6 { text += "…" }
        if !channel.isDocumented { text += " · undocumented field, scaled as stored" }
        return text
    }

    @ViewBuilder
    private func beforeAfter(_ value: Double?, factor: Double) -> some View {
        if let value {
            if factor == 1 {
                Text(Format.value(value, channel: channel, system: system)).monospacedDigit()
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Format.value(value * factor, channel: channel, system: system)).monospacedDigit().bold()
                    Text("was \(Format.value(value, channel: channel, system: system))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } else {
            Text("–")
        }
    }
}
