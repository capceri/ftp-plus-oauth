import Charts
import FITStudioCore
import SwiftUI

/// One compared file, ready to draw.
struct ComparedFile: Identifiable {
    var id: UUID { file.id }
    var file: LoadedFile
    var channel: Channel
    var color: Color
    var series: PerSecondSeries
    /// other[i] lines up with reference[i + shift] (0 for the reference).
    var shift: Int
    var baseShift: Int
    var result: ComparisonResult?
    var line: [PlotPoint]
    var difference: [PlotPoint]
}

struct CompareView: View {
    @EnvironmentObject private var store: FileStore
    @AppStorage(SettingsKey.unitSystem) private var system: UnitSystem = .metric
    @State private var aligning: Set<UUID> = []

    private var setup: CompareSetup { store.compare }

    var body: some View {
        Group {
            if store.files.count < 2 {
                EmptyState(title: "Compare two or more files",
                           message: "Open at least two FIT files, for example the same ride recorded by your pedals and your trainer. The comparison lines them up second by second.",
                           symbol: "arrow.left.arrow.right")
            } else if let reference = store.file(setup.referenceID) {
                content(reference: reference)
            } else {
                EmptyState(title: "Choose a reference file", message: "", symbol: "arrow.left.arrow.right")
                    .onAppear { if let first = store.files.first { store.compare.referenceID = first.id } }
            }
        }
        .navigationTitle("Compare")
    }

    // MARK: Content

    private func content(reference: LoadedFile) -> some View {
        let channels = availableChannels(reference: reference)
        let key = channels.contains(where: { $0.key == setup.channel }) ? setup.channel : (channels.first?.key ?? setup.channel)
        let compared = makeComparison(reference: reference, key: key)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                setupPanel(reference: reference, channels: channels, key: key)
                if let refEntry = compared.first {
                    if compared.count < 2 {
                        Banner(text: "Choose one or more files to compare with \(reference.name).", symbol: "info.circle", tint: .blue)
                    }
                    let noOverlap = compared.dropFirst().filter { $0.result == nil }
                    if !noOverlap.isEmpty {
                        HStack {
                            Banner(text: "\(noOverlap.map(\.file.name).joined(separator: ", ")) \(noOverlap.count == 1 ? "doesn’t" : "don’t") overlap the reference \(setup.alignByClock ? "in time. If they weren’t recorded at the same time, line them up by their starts" : "with the current offset").")
                            if setup.alignByClock {
                                Button("Line Up by Start") { store.compare.alignByClock = false }
                            }
                        }
                    }
                    OverlayChart(compared: compared, unit: refEntry.channel.displayUnit(system), decimals: refEntry.channel.decimals(system))
                    if compared.count > 1 {
                        DifferenceChart(compared: Array(compared.dropFirst()), percent: setup.differenceInPercent,
                                        unit: refEntry.channel.displayUnit(system), smoothing: setup.smoothing)
                        resultsTable(compared: compared)
                        ForEach(compared.dropFirst()) { entry in
                            if let result = entry.result, !result.bands.isEmpty {
                                BandsTable(entry: entry, reference: refEntry, system: system)
                            }
                        }
                        ScatterChart(reference: refEntry, others: Array(compared.dropFirst()), system: system,
                                     ignoreZeros: setup.ignoreZeros)
                        if key == .power {
                            CurveComparison(compared: compared)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    /// Channels of the reference that at least one other file also has (or all, if no other file is chosen).
    private func availableChannels(reference: LoadedFile) -> [Channel] {
        let others = setup.otherIDs.compactMap { store.file($0) }
        guard !others.isEmpty else { return reference.activity.channels }
        let shared = reference.activity.channels.filter { channel in
            others.contains { $0.activity.channel(channel.key) != nil }
        }
        return shared.isEmpty ? reference.activity.channels : shared
    }

    private func series(_ file: LoadedFile, _ key: ChannelKey) -> PerSecondSeries? {
        setup.includeAdjustments ? file.adjustedPerSecond(key) : file.perSecond(key)
    }

    private func makeComparison(reference: LoadedFile, key: ChannelKey) -> [ComparedFile] {
        guard let refChannel = reference.activity.channel(key), let refSeries = series(reference, key) else { return [] }
        let unit = refChannel.displayUnit(system)
        let gap = 15.0
        func line(_ values: [Double?], shift: Int) -> [PlotPoint] {
            let smoothed = Analysis.rollingAverage(values, window: setup.smoothing)
            let xs = values.indices.map { Double($0 + shift) }
            return Analysis.chartPoints(x: xs, y: smoothed.map { unit.convert($0) }, maxPoints: 1400, gap: gap)
                .enumerated().map { PlotPoint(id: $0.offset, x: $0.element.x, y: $0.element.y, segment: $0.element.segment) }
        }

        var entries = [ComparedFile(file: reference, channel: refChannel, color: ChannelStyle.fileColors[0], series: refSeries,
                                    shift: 0, baseShift: 0, result: nil, line: line(refSeries.values, shift: 0), difference: [])]
        for (index, id) in setup.otherIDs.enumerated() {
            guard let other = store.file(id) else { continue }
            let otherKey = setup.channel(for: id)
            guard let channel = other.activity.channel(otherKey) ?? other.activity.channel(key),
                  let otherSeries = series(other, channel.key) else { continue }
            let base = Comparator.baseShift(reference: refSeries, other: otherSeries, alignByClock: setup.alignByClock)
            let shift = base + setup.offset(id)
            let result = Comparator.compare(reference: refSeries.values, other: otherSeries.values, shift: shift,
                                            ignoreZeros: setup.ignoreZeros)
            var difference = Comparator.differenceSeries(reference: refSeries.values, other: otherSeries.values, shift: shift,
                                                         smoothing: max(1, setup.smoothing), percent: setup.differenceInPercent)
            if !setup.differenceInPercent { difference = difference.map { $0.map { $0 * unit.scale } } }
            let diffPoints = Analysis.chartPoints(x: difference.indices.map(Double.init), y: difference, maxPoints: 1400, gap: gap)
                .enumerated().map { PlotPoint(id: $0.offset, x: $0.element.x, y: $0.element.y, segment: $0.element.segment) }
            entries.append(ComparedFile(file: other, channel: channel,
                                        color: ChannelStyle.fileColors[min(index + 1, ChannelStyle.fileColors.count - 1)],
                                        series: otherSeries, shift: shift, baseShift: base, result: result,
                                        line: line(otherSeries.values, shift: shift), difference: diffPoints))
        }
        return entries
    }

    // MARK: Setup

    private func setupPanel(reference: LoadedFile, channels: [Channel], key: ChannelKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Picker("Reference", selection: Binding(
                    get: { setup.referenceID ?? reference.id },
                    set: { store.compare.makeReference($0) })) {
                    ForEach(store.files) { file in
                        Text(file.name).tag(file.id)
                    }
                }
                .frame(maxWidth: 320)
                Picker("Channel", selection: Binding(get: { key }, set: { store.compare.channel = $0 })) {
                    ForEach(channels) { channel in
                        Text(channel.name).tag(channel.key)
                    }
                }
                .frame(maxWidth: 240)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Compare with")
                ForEach(store.files.filter { $0.id != reference.id }) { file in
                    let index = setup.otherIDs.firstIndex(of: file.id)
                    Button {
                        store.compare.toggleOther(file.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: index == nil ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(index.map { ChannelStyle.fileColors[min($0 + 1, ChannelStyle.fileColors.count - 1)] } ?? .secondary)
                            Text(file.name).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(index == nil ? 0.04 : 0.1)))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 20) {
                Picker("Line up by", selection: $store.compare.alignByClock) {
                    Text("Clock time").tag(true)
                    Text("Start of each file").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 330)
                Picker("Smoothing", selection: $store.compare.smoothing) {
                    Text("Off").tag(1)
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                    Text("30 s").tag(30)
                    Text("60 s").tag(60)
                }
                .frame(maxWidth: 170)
                Picker("Difference", selection: $store.compare.differenceInPercent) {
                    Text("%").tag(true)
                    Text("Units").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }
            HStack(spacing: 20) {
                Toggle("Ignore seconds where either is zero", isOn: $store.compare.ignoreZeros)
                    .help("Coasting often starts a second earlier on one device than the other. Leaving zeros out compares only the pedalling.")
                Toggle("Include adjustments", isOn: $store.compare.includeAdjustments)
                    .help("Compare with each file’s pending adjustments applied.")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    // MARK: Results

    private func resultsTable(compared: [ComparedFile]) -> some View {
        let reference = compared[0]
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Results",
                          subtitle: "Over the seconds both files have data. Positive differences mean the file reads higher than \(reference.file.name).")
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("File").gridColumnAlignment(.leading)
                    Text("Offset").gridColumnAlignment(.leading)
                    Text("Overlap")
                    Text("Average")
                    Text("Difference")
                    Text("Mean abs")
                    Text("Correlation")
                    Text("Fit")
                    Text("Suggested").gridColumnAlignment(.leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                GridRow {
                    fileLabel(reference)
                    Text("Reference").foregroundStyle(.secondary)
                    Text("")
                    Text(averageText(compared.dropFirst().compactMap(\.result).first?.referenceAverage, channel: reference.channel))
                    Text("")
                    Text("")
                    Text("")
                    Text("")
                    Text("")
                }
                ForEach(compared.dropFirst()) { entry in
                    resultRow(entry, reference: reference)
                }
            }
            .monospacedDigit()
        }
    }

    private func resultRow(_ entry: ComparedFile, reference: ComparedFile) -> some View {
        let result = entry.result
        let unit = reference.channel.displayUnit(system)
        return GridRow {
            VStack(alignment: .leading, spacing: 3) {
                fileLabel(entry)
                if entry.file.activity.channels.count > 1 {
                    Picker("", selection: Binding(
                        get: { entry.channel.key },
                        set: { store.compare.otherChannels[entry.id] = $0 == store.compare.channel ? nil : $0 })) {
                        ForEach(entry.file.activity.channels.filter(\.isAdjustable)) { channel in
                            Text(channel.name).tag(channel.key)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 170)
                }
            }
            HStack(spacing: 4) {
                TextField("0", value: Binding(get: { setup.offset(entry.id) }, set: { store.compare.offsets[entry.id] = $0 }),
                          format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text("s")
                Stepper("", value: Binding(get: { setup.offset(entry.id) }, set: { store.compare.offsets[entry.id] = $0 }),
                        in: -86_400...86_400).labelsHidden()
                if aligning.contains(entry.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Auto") { autoAlign(entry, reference: reference) }
                        .controlSize(.small)
                        .help("Find the offset where the two files match best (searches ±10 minutes)")
                }
            }
            Text(result.map { Format.duration(Double($0.overlapSeconds)) } ?? "–")
            Text(averageText(result?.otherAverage, channel: entry.channel))
            Text(Format.percent(result?.differencePercent, decimals: 2))
                .bold()
                .foregroundStyle(differenceColor(result?.differencePercent))
            Text(result.map { "\(Format.number($0.meanAbsoluteDifference * unit.scale, decimals: 1)) \(unit.symbol)" } ?? "–")
            Text(Format.number(result?.correlation, decimals: 3))
            Text(fitText(result))
                .font(.caption)
            HStack(spacing: 6) {
                if let suggestion = result?.suggestedAdjustment, entry.channel.isAdjustable {
                    let combined = combinedSuggestion(suggestion, entry: entry)
                    Text(Format.percent(combined, decimals: 2)).bold()
                    Button("Apply…") {
                        store.applySuggestion(combined, channel: entry.channel.key, to: entry.file)
                    }
                    .controlSize(.small)
                    .help("Open \(entry.file.name) in Adjust with \(entry.channel.name) set to \(Format.percent(combined, decimals: 2)), so its average matches the reference.")
                } else {
                    Text("–")
                }
            }
        }
    }

    private func fileLabel(_ entry: ComparedFile) -> some View {
        HStack(spacing: 6) {
            Circle().fill(entry.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.file.name).lineLimit(1)
                Text(entry.channel.name).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func averageText(_ value: Double?, channel: Channel) -> String {
        Format.value(value, channel: channel, system: system)
    }

    private func differenceColor(_ percent: Double?) -> Color {
        guard let percent else { return .primary }
        return abs(percent) < 1 ? .green : abs(percent) < 3 ? .orange : .red
    }

    private func fitText(_ result: ComparisonResult?) -> String {
        guard let slope = result?.slope, let intercept = result?.intercept else { return "–" }
        return "×\(Format.number(slope, decimals: 3)) \(intercept >= 0 ? "+" : "−") \(Format.number(abs(intercept), decimals: 1))"
    }

    /// The suggestion is relative to what's compared; if the file already has an adjustment
    /// (and it's included), combine the two so applying it gives the right total.
    private func combinedSuggestion(_ suggestion: Double, entry: ComparedFile) -> Double {
        guard setup.includeAdjustments else { return suggestion }
        let existing = entry.file.activeAdjustments[entry.channel.key] ?? 0
        return ((1 + existing / 100) * (1 + suggestion / 100) - 1) * 100
    }

    private func autoAlign(_ entry: ComparedFile, reference: ComparedFile) {
        let id = entry.id
        let referenceValues = reference.series.values
        let otherValues = entry.series.values
        let around = entry.shift
        let base = entry.baseShift
        aligning.insert(id)
        Task {
            let best = await Task.detached(priority: .userInitiated) {
                Comparator.bestShift(reference: referenceValues, other: otherValues, around: around, range: 600)
            }.value
            aligning.remove(id)
            if let best {
                store.compare.offsets[id] = best.shift - base
            } else {
                store.alert = FileStore.StoreAlert(title: "Couldn’t line the files up",
                                                   message: "There isn’t enough overlapping data within ten minutes of the current offset.")
            }
        }
    }
}

// MARK: - Charts

private struct OverlayChart: View {
    let compared: [ComparedFile]
    let unit: DisplayUnit
    let decimals: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "\(compared.first?.channel.name ?? "Values") over time",
                          subtitle: "Time from the start of the reference. Files are shifted by their offset.")
            Chart {
                ForEach(compared) { entry in
                    ForEach(entry.line) { point in
                        LineMark(x: .value("Time", point.x), y: .value("Value", point.y),
                                 series: .value("Series", "\(entry.id.uuidString)-\(point.segment)"))
                            .foregroundStyle(entry.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let x = value.as(Double.self) { Text(Format.duration(x)) }
                    }
                }
            }
            .chartYAxisLabel(unit.symbol)
            .frame(height: 220)
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(compared) { entry in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(entry.color).frame(width: 14, height: 3)
                    Text(entry.file.name).font(.caption).lineLimit(1)
                }
            }
        }
    }
}

private struct DifferenceChart: View {
    let compared: [ComparedFile]
    let percent: Bool
    let unit: DisplayUnit
    let smoothing: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Difference from the reference",
                          subtitle: smoothing > 1 ? "Averaged over \(smoothing) s." : nil)
            Chart {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Color.secondary)
                ForEach(compared) { entry in
                    ForEach(entry.difference) { point in
                        LineMark(x: .value("Time", point.x), y: .value("Difference", point.y),
                                 series: .value("Series", "\(entry.id.uuidString)-\(point.segment)"))
                            .foregroundStyle(entry.color)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                    if let average = averageDifference(entry) {
                        RuleMark(y: .value("Average", average))
                            .foregroundStyle(entry.color)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let x = value.as(Double.self) { Text(Format.duration(x)) }
                    }
                }
            }
            .chartYAxisLabel(percent ? "%" : unit.symbol)
            .frame(height: 170)
            Text("Dashed lines: the average difference over the whole overlap.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension DifferenceChart {
    private func averageDifference(_ entry: ComparedFile) -> Double? {
        guard let result = entry.result else { return nil }
        return percent ? result.differencePercent : result.meanDifference * unit.scale
    }
}

private struct BandsTable: View {
    let entry: ComparedFile
    let reference: ComparedFile
    let system: UnitSystem

    var body: some View {
        if let result = entry.result {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "\(entry.file.name): difference by \(reference.channel.name.lowercased()) level",
                              subtitle: "Seconds grouped by the reference’s value. A difference that changes with the level points to a slope (scale) error rather than an offset.")
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 5) {
                    GridRow {
                        Text("Reference range").gridColumnAlignment(.leading)
                        Text("Reference avg")
                        Text("File avg")
                        Text("Difference")
                        Text("Time")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(result.bands) { band in
                        GridRow {
                            Text("\(Format.value(band.lower, channel: reference.channel, system: system, unit: false))–\(Format.value(band.upper, channel: reference.channel, system: system))")
                            Text(Format.value(band.referenceAverage, channel: reference.channel, system: system))
                            Text(Format.value(band.otherAverage, channel: entry.channel, system: system))
                            Text(Format.percent(band.differencePercent, decimals: 2)).bold()
                            Text(Format.duration(Double(band.seconds)))
                        }
                        .monospacedDigit()
                    }
                }
            }
        }
    }
}

private struct ScatterChart: View {
    let reference: ComparedFile
    let others: [ComparedFile]
    let system: UnitSystem
    let ignoreZeros: Bool

    private struct Dot: Identifiable {
        var id: Int
        var x: Double
        var y: Double
        var color: Color
        var series: String
    }

    var body: some View {
        let unit = reference.channel.displayUnit(system)
        let dots = makeDots(unit: unit)
        let maxValue = dots.reduce(0) { max($0, max($1.x, $1.y)) }
        let minValue = dots.reduce(maxValue) { min($0, min($1.x, $1.y)) }
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Second by second",
                          subtitle: "Each dot is one second: the reference across, the other file up. Dots on the dashed line agree exactly.")
            Chart {
                ForEach(dots) { dot in
                    PointMark(x: .value("Reference", dot.x), y: .value("File", dot.y))
                        .symbolSize(8)
                        .foregroundStyle(dot.color.opacity(0.35))
                }
                LineMark(x: .value("Reference", minValue), y: .value("File", minValue), series: .value("Line", "equal"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                LineMark(x: .value("Reference", maxValue), y: .value("File", maxValue), series: .value("Line", "equal"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartXAxisLabel("\(reference.file.name) (\(unit.symbol))")
            .chartYAxisLabel(unit.symbol)
            .frame(height: 320)
            .frame(maxWidth: 520)
        }
    }

    private func makeDots(unit: DisplayUnit) -> [Dot] {
        var dots: [Dot] = []
        for other in others {
            let pairs = Comparator.pairs(reference: reference.series.values, other: other.series.values,
                                         shift: other.shift, ignoreZeros: ignoreZeros)
            let step = max(1, pairs.count / 1500)
            for index in stride(from: 0, to: pairs.count, by: step) {
                dots.append(Dot(id: dots.count, x: unit.convert(pairs[index].reference), y: unit.convert(pairs[index].other),
                                color: other.color, series: other.file.name))
            }
        }
        return dots
    }
}

private struct CurveComparison: View {
    let compared: [ComparedFile]

    private struct CurvePoint: Identifiable {
        var id: String
        var file: String
        var color: Color
        var duration: Double
        var watts: Double
    }

    var body: some View {
        let points = compared.flatMap { entry in
            Analysis.meanMaximal(entry.series.values.compactMap { $0 }).map {
                CurvePoint(id: "\(entry.id)-\($0.duration)", file: entry.id.uuidString, color: entry.color,
                           duration: Double($0.duration), watts: $0.watts)
            }
        }
        let longest = points.map(\.duration).max() ?? 2
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Power curves", subtitle: "Best average power for each duration, per file.")
            Chart(points) { point in
                LineMark(x: .value("Duration", point.duration), y: .value("Power", point.watts),
                         series: .value("File", point.file))
                    .foregroundStyle(point.color)
                    .interpolationMethod(.monotone)
            }
            .chartXScale(domain: 1...max(2, longest), type: .log)
            .chartXAxis {
                AxisMarks(values: [1.0, 5, 15, 60, 300, 1200, 3600, 10800].filter { $0 <= longest }) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) { Text(Format.shortDuration(Int(seconds))) }
                    }
                }
            }
            .chartYAxisLabel("W")
            .frame(height: 220)
        }
    }
}
