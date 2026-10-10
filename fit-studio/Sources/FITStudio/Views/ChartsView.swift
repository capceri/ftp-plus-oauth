import Charts
import FITStudioCore
import SwiftUI

/// Hover position and selected range, shared by all lanes. Only the overlay layers observe it,
/// so moving the mouse doesn't redraw the charts themselves.
@MainActor
final class ChartCursor: ObservableObject {
    @Published var x: Double?
    @Published var selection: ClosedRange<Double>?
}

enum XAxisMode: String, CaseIterable, Identifiable {
    case time, distance
    var id: String { rawValue }
}

struct PlotPoint: Identifiable {
    var id: Int
    var x: Double
    var y: Double
    var segment: Int
}

/// One chart lane: a channel's values ready to draw, plus full-resolution arrays for read-outs.
struct Lane: Identifiable {
    var id: ChannelKey { channel.key }
    var channel: Channel
    var unit: String
    var decimals: Int
    var color: Color
    var points: [PlotPoint]
    var originalPoints: [PlotPoint]
    /// Full-resolution x (axis units) and y (display units, smoothed) for the hover read-out.
    var xs: [Double]
    var ys: [Double?]

    /// The value at the row nearest to `x`.
    func value(atX x: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        var low = 0, high = xs.count - 1
        while low < high {
            let mid = (low + high) / 2
            if xs[mid] < x { low = mid + 1 } else { high = mid }
        }
        let index = low > 0 && abs(xs[low - 1] - x) < abs(xs[low] - x) ? low - 1 : low
        return ys[index]
    }

    func format(_ value: Double) -> String {
        Format.number(value, decimals: decimals) + (unit.isEmpty ? "" : " \(unit)")
    }
}

struct ChartsView: View {
    @ObservedObject var file: LoadedFile
    @AppStorage(SettingsKey.unitSystem) private var system: UnitSystem = .metric
    @AppStorage("chartChannels") private var savedChannels = "power,heart_rate,cadence,speed,altitude"
    @AppStorage("chartSmoothing") private var smoothing = 0
    @State private var xAxis: XAxisMode = .time
    @State private var zoom: ClosedRange<Double>?
    @State private var showOriginal = true
    @State private var cursor = ChartCursor()

    private var activity: Activity { file.displayActivity }

    private var selectedKeys: [ChannelKey] {
        if savedChannels == "none" { return [] }
        let saved = savedChannels.split(separator: ",").map { ChannelKey(String($0)) }
        let present = saved.filter { activity.channel($0) != nil }
        return present.isEmpty ? Array(activity.channels.prefix(3).map(\.key)) : present
    }

    private var distanceAvailable: Bool { activity.channel(.distance) != nil }

    private var effectiveAxis: XAxisMode { distanceAvailable ? xAxis : .time }

    var body: some View {
        let xs = xValues
        let lanes = makeLanes(xs: xs)
        let domain = xDomain(xs)
        VStack(spacing: 0) {
            controls
            Divider()
            if lanes.isEmpty {
                EmptyState(title: "No data to plot", message: "Choose one or more channels above.", symbol: "chart.xyaxis.line")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(lanes) { lane in
                            LaneChart(lane: lane, domain: domain, cursor: cursor, axis: effectiveAxis, system: system,
                                      showsXAxis: lane.id == lanes.last?.id)
                        }
                    }
                    .padding(16)
                }
                Divider()
                SelectionBar(cursor: cursor, lanes: lanes, activity: activity, axis: effectiveAxis, system: system,
                             zoomed: zoom != nil,
                             onZoom: { range in zoom = range; cursor.selection = nil },
                             onReset: { zoom = nil })
            }
        }
        .onExitCommand { cursor.selection = nil }
        .onChange(of: xAxis) { zoom = nil; cursor.selection = nil; cursor.x = nil }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(activity.channels) { channel in
                        let selected = selectedKeys.contains(channel.key)
                        Button {
                            toggle(channel.key)
                        } label: {
                            HStack(spacing: 4) {
                                Circle().fill(ChannelStyle.color(channel.key)).frame(width: 8, height: 8)
                                Text(channel.name)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(selected ? ChannelStyle.color(channel.key).opacity(0.2) : Color.primary.opacity(0.05)))
                            .overlay(Capsule().stroke(selected ? ChannelStyle.color(channel.key) : Color.clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack(spacing: 16) {
                Picker("X axis", selection: $xAxis) {
                    Text("Time").tag(XAxisMode.time)
                    Text("Distance").tag(XAxisMode.distance)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .disabled(!distanceAvailable)
                Picker("Smoothing", selection: $smoothing) {
                    Text("Off").tag(0)
                    Text("3 s").tag(3)
                    Text("10 s").tag(10)
                    Text("30 s").tag(30)
                    Text("60 s").tag(60)
                }
                .frame(width: 170)
                if file.hasAdjustments {
                    Toggle("Show original", isOn: $showOriginal)
                }
                Spacer()
                Text("Drag across a chart to select a range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
    }

    private func toggle(_ key: ChannelKey) {
        var keys = selectedKeys
        if let index = keys.firstIndex(of: key) {
            keys.remove(at: index)
        } else {
            keys.append(key)
        }
        // Keep the order of the channel list.
        let order = activity.channels.map(\.key)
        keys.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        savedChannels = keys.map(\.rawValue).joined(separator: ",")
        if keys.isEmpty { savedChannels = "none" }
    }

    // MARK: Data

    /// x for every row: seconds, or distance in display units.
    private var xValues: [Double?] {
        switch effectiveAxis {
        case .time:
            return activity.times
        case .distance:
            let unit = Quantity.distance.displayUnit(system, fallback: "")
            return activity.channel(.distance)?.values.map { unit.convert($0) } ?? []
        }
    }

    private func xDomain(_ xs: [Double?]) -> ClosedRange<Double> {
        if let zoom { return zoom }
        let present = xs.compactMap { $0 }
        guard let low = present.min(), let high = present.max(), high > low else { return 0...1 }
        return low...high
    }

    private func makeLanes(xs: [Double?]) -> [Lane] {
        let original = file.activity
        let gap: Double = effectiveAxis == .time ? 15 : .infinity
        return selectedKeys.compactMap { key -> Lane? in
            guard let channel = activity.channel(key) else { return nil }
            let unit = channel.displayUnit(system)
            let decimals = channel.decimals(system)
            let display = channel.values.map { unit.convert($0) }
            let smoothed = smoothing > 0 ? Analysis.smooth(times: activity.times, values: display, window: Double(smoothing)) : display

            // Rows inside the visible range (plus one either side so lines reach the edges).
            var rowX: [Double] = [], rowY: [Double?] = [], rowOriginal: [Double?] = []
            let adjusted = file.factor(key) != 1 && showOriginal
            let originalValues: [Double?] = adjusted
                ? Analysis.smooth(times: original.times, values: (original.channel(key)?.values ?? []).map { unit.convert($0) },
                                  window: Double(smoothing))
                : []
            var fullX: [Double] = [], fullY: [Double?] = []
            for (row, x) in xs.enumerated() {
                guard let x else { continue }
                fullX.append(x)
                fullY.append(smoothed[row])
                if let zoom, x < zoom.lowerBound || x > zoom.upperBound {
                    let next = row + 1 < xs.count ? xs[row + 1] : nil
                    let previous = row > 0 ? xs[row - 1] : nil
                    let nearEdge = (next.map { $0 >= zoom.lowerBound } ?? false && x < zoom.lowerBound)
                        || (previous.map { $0 <= zoom.upperBound } ?? false && x > zoom.upperBound)
                    if !nearEdge { continue }
                }
                rowX.append(x)
                rowY.append(smoothed[row])
                if adjusted { rowOriginal.append(row < originalValues.count ? originalValues[row] : nil) }
            }
            let points = Analysis.chartPoints(x: rowX, y: rowY, maxPoints: 1400, gap: gap)
                .enumerated().map { PlotPoint(id: $0.offset, x: $0.element.x, y: $0.element.y, segment: $0.element.segment) }
            let originalPoints = adjusted
                ? Analysis.chartPoints(x: rowX, y: rowOriginal, maxPoints: 900, gap: gap)
                    .enumerated().map { PlotPoint(id: $0.offset, x: $0.element.x, y: $0.element.y, segment: $0.element.segment) }
                : []
            return Lane(channel: channel, unit: unit.symbol, decimals: decimals, color: ChannelStyle.color(key),
                        points: points, originalPoints: originalPoints, xs: fullX, ys: fullY)
        }
    }
}

struct LaneChart: View {
    let lane: Lane
    let domain: ClosedRange<Double>
    let cursor: ChartCursor
    let axis: XAxisMode
    let system: UnitSystem
    let showsXAxis: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: ChannelStyle.symbol(lane.channel.key)).foregroundStyle(lane.color)
                Text(lane.channel.name).font(.subheadline.weight(.semibold))
                if !lane.unit.isEmpty {
                    Text(lane.unit).font(.caption).foregroundStyle(.secondary)
                }
                if !lane.originalPoints.isEmpty {
                    Text("dashed: original").font(.caption).foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(lane.originalPoints) { point in
                    LineMark(x: .value("X", point.x), y: .value("Original", point.y), series: .value("Series", "original-\(point.segment)"))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(lane.points) { point in
                    LineMark(x: .value("X", point.x), y: .value(lane.channel.name, point.y), series: .value("Series", "value-\(point.segment)"))
                        .foregroundStyle(lane.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.3))
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        // Only the bottom lane is labelled; the others share its axis.
                        if showsXAxis, let x = value.as(Double.self) { Text(xLabel(x)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
            }
            .chartOverlay { proxy in
                CursorLayer(proxy: proxy, cursor: cursor, lane: lane)
            }
            .frame(height: 140)
        }
    }

    private func xLabel(_ x: Double) -> String {
        switch axis {
        case .time: return Format.duration(x)
        case .distance: return Format.number(x, decimals: 1) + " " + Quantity.distance.displayUnit(system, fallback: "").symbol
        }
    }
}

/// Draws the hover line, the selected range and the value read-out, and handles the mouse.
struct CursorLayer: View {
    let proxy: ChartProxy
    @ObservedObject var cursor: ChartCursor
    let lane: Lane

    var body: some View {
        GeometryReader { geometry in
            let plot = proxy.plotFrame.map { geometry[$0] } ?? CGRect(origin: .zero, size: geometry.size)
            ZStack(alignment: .topLeading) {
                if let range = cursor.selection,
                   let x0 = proxy.position(forX: range.lowerBound), let x1 = proxy.position(forX: range.upperBound) {
                    let left = plot.minX + max(0, min(x0, x1))
                    let right = plot.minX + min(plot.width, max(x0, x1))
                    Path(CGRect(x: left, y: plot.minY, width: max(1, right - left), height: plot.height))
                        .fill(Color.accentColor.opacity(0.15))
                }
                if let x = cursor.x, let position = proxy.position(forX: x), position >= 0, position <= plot.width {
                    let lineX = plot.minX + position
                    Path { path in
                        path.move(to: CGPoint(x: lineX, y: plot.minY))
                        path.addLine(to: CGPoint(x: lineX, y: plot.maxY))
                    }
                    .stroke(Color.primary.opacity(0.5), lineWidth: 1)
                    if let value = lane.value(atX: x) {
                        let text = lane.format(value)
                        let flip = position > plot.width - 90
                        Text(text)
                            .font(.caption.monospacedDigit().weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.regularMaterial))
                            .fixedSize()
                            .position(x: lineX + (flip ? -45 : 45), y: plot.minY + 10)
                    }
                }
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            cursor.x = proxy.value(atX: location.x - plot.minX, as: Double.self)
                        case .ended:
                            cursor.x = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { drag in
                                guard let a = proxy.value(atX: drag.startLocation.x - plot.minX, as: Double.self),
                                      let b = proxy.value(atX: drag.location.x - plot.minX, as: Double.self) else { return }
                                cursor.selection = min(a, b)...max(a, b)
                                cursor.x = b
                            }
                    )
                    .onTapGesture { cursor.selection = nil }
            }
        }
    }
}

/// The bar under the charts: values at the cursor, or statistics for the selected range.
struct SelectionBar: View {
    @ObservedObject var cursor: ChartCursor
    let lanes: [Lane]
    let activity: Activity
    let axis: XAxisMode
    let system: UnitSystem
    let zoomed: Bool
    let onZoom: (ClosedRange<Double>) -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            if let range = cursor.selection, let times = timeRange(range) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Selection").font(.caption).foregroundStyle(.secondary)
                    Text("\(Format.duration(times.lowerBound))–\(Format.duration(times.upperBound)) · \(Format.duration(times.upperBound - times.lowerBound))")
                        .monospacedDigit()
                }
                if let distance = activity.distance(in: times) {
                    stat("Distance", Format.distance(distance, system: system))
                }
                ForEach(lanes) { lane in
                    if let stats = activity.stats(for: lane.channel, in: times) {
                        stat(lane.channel.name + " avg / max",
                             "\(Format.value(stats.average, channel: lane.channel, system: system, unit: false)) / \(Format.value(stats.maximum, channel: lane.channel, system: system))",
                             color: lane.color)
                    }
                }
                if lanes.contains(where: { $0.channel.key == .power }), let np = activity.powerMetrics(in: times)?.normalized {
                    stat("NP", "\(Format.number(np)) W", color: ChannelStyle.color(.power))
                }
            } else if let x = cursor.x {
                stat(axis == .time ? "Time" : "Distance", axis == .time ? Format.duration(x)
                     : Format.number(x, decimals: 2) + " " + Quantity.distance.displayUnit(system, fallback: "").symbol)
                ForEach(lanes) { lane in
                    stat(lane.channel.name, lane.value(atX: x).map(lane.format) ?? "–", color: lane.color)
                }
            } else {
                Text("Hover to read values. Drag to select a range and see its averages.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let range = cursor.selection {
                Button("Zoom to Selection") { onZoom(range) }
            }
            if zoomed {
                Button("Show All") { onReset() }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }

    private func stat(_ title: String, _ value: String, color: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(color).lineLimit(1)
            Text(value).monospacedDigit().lineLimit(1)
        }
    }

    /// The selection as seconds since the start.
    private func timeRange(_ range: ClosedRange<Double>) -> ClosedRange<Double>? {
        switch axis {
        case .time:
            return range
        case .distance:
            guard let distance = activity.channel(.distance) else { return nil }
            let unit = Quantity.distance.displayUnit(system, fallback: "")
            let rows = activity.times.indices.filter { row in
                guard let value = distance.values[row] else { return false }
                return range.contains(unit.convert(value))
            }
            guard let first = rows.first, let last = rows.last else { return nil }
            return activity.times[first]...activity.times[last]
        }
    }
}
