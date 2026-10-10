import Charts
import FITStudioCore
import MapKit
import SwiftUI

struct SummaryView: View {
    @ObservedObject var file: LoadedFile
    @AppStorage(SettingsKey.unitSystem) private var system: UnitSystem = .metric
    @AppStorage(SettingsKey.ftp) private var ftp: Double = 250

    private var activity: Activity { file.activity }
    private var info: ActivityInfo { file.activity.info }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(info.warnings, id: \.self) { warning in
                    Banner(text: warning)
                }
                if file.hasAdjustments {
                    Banner(text: "Values include your adjustments (\(adjustmentList)). The original file isn’t changed.",
                           symbol: "slider.horizontal.3", tint: .blue)
                }
                header
                tiles
                channelTable
                if let metrics = file.powerMetrics, !metrics.curve.isEmpty {
                    PowerCurveSection(metrics: metrics, factor: file.factor(.power))
                }
                if !file.lapStats.isEmpty {
                    lapsTable
                }
                if activity.hasPositions {
                    RouteMap(positions: activity.positions)
                }
                devicesAndFile
            }
            .padding(20)
        }
    }

    private var adjustmentList: String {
        file.activeAdjustments.sorted { $0.key < $1.key }.map { key, percent in
            "\(activity.channel(key)?.name ?? key.rawValue) \(Format.percent(percent, decimals: 2))"
        }.joined(separator: ", ")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: sportSymbol)
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(info.sport ?? "Activity").font(.title2.bold())
                Text([activity.startDate.map { $0.formatted(date: .complete, time: .shortened) }, info.creator]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sportSymbol: String {
        let sport = (info.sport ?? "").lowercased()
        if sport.contains("cycling") || sport.contains("bik") { return "bicycle" }
        if sport.contains("run") { return "figure.run" }
        if sport.contains("swim") { return "figure.pool.swim" }
        if sport.contains("walk") || sport.contains("hik") { return "figure.walk" }
        if sport.contains("row") { return "figure.rower" }
        return "figure.mixed.cardio"
    }

    // MARK: Tiles

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            Tile(title: "Elapsed time", value: Format.duration(info.elapsedTime ?? activity.duration), symbol: "clock",
                 tint: .secondary,
                 detail: info.timerTime.map { "Timer \(Format.duration($0))" })
            if let distance = info.distance ?? activity.distance() {
                Tile(title: "Distance", value: Format.distance(distance * file.factor(.distance), system: system),
                     symbol: ChannelStyle.symbol(.distance), tint: ChannelStyle.color(.distance), detail: adjustedNote(.distance))
            }
            if let power = file.powerMetrics {
                let k = file.factor(.power)
                Tile(title: "Average power", value: Format.number(power.average * k), unit: "W",
                     symbol: ChannelStyle.symbol(.power), tint: ChannelStyle.color(.power),
                     detail: "Max \(Format.number(power.maximum * k)) W\(adjustedNote(.power).map { " · \($0)" } ?? "")")
                Tile(title: "Normalized power", value: Format.number(power.normalized.map { $0 * k }), unit: "W",
                     symbol: "bolt.badge.clock", tint: ChannelStyle.color(.power),
                     detail: power.variabilityIndex.map { "VI \(Format.number($0, decimals: 2))" })
                Tile(title: "Work", value: Format.number(power.work * k), unit: "kJ", symbol: "flame",
                     tint: ChannelStyle.color(.power), detail: info.calories.map { "\(Format.number($0)) kcal (from file)" })
                if ftp > 0 {
                    Tile(title: "Intensity · TSS",
                         value: "\(Format.number(power.intensityFactor(ftp: ftp).map { $0 * k }, decimals: 2)) · \(Format.number(power.trainingStressScore(ftp: ftp).map { $0 * k * k }))",
                         symbol: "gauge.with.dots.needle.67percent", tint: ChannelStyle.color(.power),
                         detail: "FTP \(Format.number(ftp)) W (Settings)")
                }
            }
            statTile(.heartRate, title: "Heart rate")
            statTile(.cadence, title: "Cadence", nonZero: true)
            statTile(.speed, title: "Speed")
            if let elevation {
                let k = file.factor(.altitude)
                Tile(title: "Elevation gain", value: Format.elevation(elevation.gain * k, system: system),
                     symbol: ChannelStyle.symbol(.altitude), tint: ChannelStyle.color(.altitude),
                     detail: elevation.loss.map { "Loss \(Format.elevation($0 * k, system: system))" })
            }
            statTile(.temperature, title: "Temperature")
        }
    }

    /// Climbing from the file's session, or calculated from the elevation channel.
    private var elevation: (gain: Double, loss: Double?)? {
        if let ascent = info.ascent { return (ascent, info.descent) }
        guard let change = activity.elevationChange() else { return nil }
        return (change.ascent, change.descent)
    }

    @ViewBuilder
    private func statTile(_ key: ChannelKey, title: String, nonZero: Bool = false) -> some View {
        if let channel = activity.channel(key), let stats = file.stats(key) {
            let k = file.factor(key)
            let average = (nonZero ? stats.averageNonZero : stats.average).map { $0 * k }
            let unit = channel.displayUnit(system)
            Tile(title: title, value: Format.value(average, channel: channel, system: system, unit: false), unit: unit.symbol,
                 symbol: ChannelStyle.symbol(key), tint: ChannelStyle.color(key),
                 detail: "Max \(Format.value(stats.maximum * k, channel: channel, system: system))\(adjustedNote(key).map { " · \($0)" } ?? "")")
        }
    }

    private func adjustedNote(_ key: ChannelKey) -> String? {
        let percent = file.activeAdjustments[key] ?? 0
        return percent == 0 ? nil : "adjusted \(Format.percent(percent, decimals: 2))"
    }

    // MARK: Channels

    private var channelTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Channels", subtitle: "Every series recorded in the file. Averages are over the seconds with data.")
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Channel").gridColumnAlignment(.leading)
                    Text("Min")
                    Text("Average")
                    Text("Max")
                    Text("Unit").gridColumnAlignment(.leading)
                    Text("Coverage")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                ForEach(activity.channels) { channel in
                    let stats = file.stats(channel.key)
                    let k = file.factor(channel.key)
                    GridRow {
                        Label {
                            Text(channel.name)
                                + Text(channel.isDocumented ? "" : "  undocumented").font(.caption).foregroundColor(.secondary)
                        } icon: {
                            Image(systemName: ChannelStyle.symbol(channel.key)).foregroundStyle(ChannelStyle.color(channel.key))
                        }
                        .lineLimit(1)
                        Text(Format.value(stats.map { $0.minimum * k }, channel: channel, system: system, unit: false))
                        Text(Format.value(stats.map { $0.average * k }, channel: channel, system: system, unit: false))
                        Text(Format.value(stats.map { $0.maximum * k }, channel: channel, system: system, unit: false))
                        Text(channel.displayUnit(system).symbol).foregroundStyle(.secondary)
                        Text(Format.percent(stats.map { $0.coverage * 100 }, decimals: 0, signed: false))
                            .foregroundStyle((stats?.coverage ?? 1) < 0.98 ? Color.orange : Color.primary)
                    }
                    .monospacedDigit()
                }
            }
        }
    }

    // MARK: Laps

    private var lapsTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Laps", subtitle: "Calculated from the records within each lap.")
            let speed = activity.channel(.speed)
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Lap").gridColumnAlignment(.leading)
                    Text("Start")
                    Text("Time")
                    Text("Distance")
                    Text("Avg power")
                    Text("NP")
                    Text("Max power")
                    Text("Heart rate")
                    Text("Cadence")
                    Text("Speed")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                ForEach(file.lapStats) { lap in
                    let kp = file.factor(.power)
                    GridRow {
                        Text("\(lap.id)")
                        Text(Format.duration(lap.start))
                        Text(Format.duration(lap.duration))
                        Text(Format.distance(lap.distance.map { $0 * file.factor(.distance) }, system: system))
                        Text(lap.power.map { "\(Format.number($0 * kp)) W" } ?? "–")
                        Text(lap.normalizedPower.map { "\(Format.number($0 * kp)) W" } ?? "–")
                        Text(lap.maxPower.map { "\(Format.number($0 * kp)) W" } ?? "–")
                        Text(lap.heartRate.map { "\(Format.number($0 * file.factor(.heartRate))) bpm" } ?? "–")
                        Text(lap.cadence.map { "\(Format.number($0 * file.factor(.cadence))) rpm" } ?? "–")
                        Text(lapSpeed(lap, channel: speed))
                    }
                    .monospacedDigit()
                }
            }
        }
    }

    private func lapSpeed(_ lap: LapStats, channel: Channel?) -> String {
        guard let channel, let speed = lap.speed else { return "–" }
        return Format.value(speed * file.factor(.speed), channel: channel, system: system)
    }

    // MARK: Devices and file

    private var devicesAndFile: some View {
        HStack(alignment: .top, spacing: 30) {
            if !info.devices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Devices")
                    ForEach(info.devices) { device in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).bold()
                            Text(deviceDetail(device)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "File")
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    fileRow("Location", file.url.deletingLastPathComponent().path)
                    fileRow("Type", info.fileType ?? "–")
                    fileRow("Created by", info.creator ?? "–")
                    if let serial = info.serialNumber { fileRow("Serial number", String(serial)) }
                    if let created = info.timeCreated { fileRow("Created", created.formatted(date: .abbreviated, time: .standard)) }
                    fileRow("Size", "\(Format.bytes(info.byteCount)) · \(activity.times.count) records")
                    fileRow("FIT version", "Protocol \(info.protocolVersion), profile \(info.profileVersion)")
                    fileRow("Checksum", file.file.segments.allSatisfy(\.crcIsValid) ? "Valid" : "Not valid")
                    if !info.developerFields.isEmpty {
                        fileRow("Developer fields", info.developerFields.map(\.name).joined(separator: ", "))
                    }
                }
                .font(.callout)
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fileRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(2)
        }
    }

    private func deviceDetail(_ device: DeviceSummary) -> String {
        var parts: [String] = []
        if let type = device.type { parts.append(type) }
        if let serial = device.serialNumber { parts.append("S/N \(serial)") }
        if let version = device.softwareVersion { parts.append("v\(Format.number(version, decimals: 2))") }
        if let battery = device.batteryStatus { parts.append("battery \(battery.lowercased())") }
        if let level = device.batteryLevel { parts.append("\(Format.number(level))%") }
        if let voltage = device.batteryVoltage { parts.append("\(Format.number(voltage, decimals: 2)) V") }
        if let source = device.source { parts.append(source) }
        return parts.isEmpty ? "No details" : parts.joined(separator: " · ")
    }
}

struct PowerCurveSection: View {
    var metrics: PowerMetrics
    var factor: Double

    private let highlights = [5, 60, 300, 1200, 3600]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Power curve", subtitle: "Best average power for each duration.")
            HStack(alignment: .top, spacing: 20) {
                Chart(metrics.curve) { point in
                    LineMark(x: .value("Duration", Double(point.duration)), y: .value("Power", point.watts * factor))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(ChannelStyle.color(.power))
                    PointMark(x: .value("Duration", Double(point.duration)), y: .value("Power", point.watts * factor))
                        .symbolSize(18)
                        .foregroundStyle(ChannelStyle.color(.power))
                }
                .chartXScale(domain: 1...Double(max(2, metrics.curve.last?.duration ?? 2)), type: .log)
                .chartXAxis {
                    AxisMarks(values: [1.0, 5, 15, 60, 300, 1200, 3600, 10800].filter { $0 <= Double(metrics.curve.last?.duration ?? 1) }) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) { Text(Format.shortDuration(Int(seconds))) }
                        }
                    }
                }
                .chartYAxisLabel("W")
                .frame(height: 200)

                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(metrics.curve.filter { highlights.contains($0.duration) }) { point in
                        GridRow {
                            Text(Format.shortDuration(point.duration)).foregroundStyle(.secondary)
                            Text("\(Format.number(point.watts * factor)) W").monospacedDigit().bold()
                        }
                    }
                }
                .frame(width: 130)
            }
        }
    }
}

struct RouteMap: View {
    var positions: [Coordinate?]

    private var coordinates: [CLLocationCoordinate2D] {
        let present = positions.compactMap { $0 }
        let step = max(1, present.count / 2000)
        return stride(from: 0, to: present.count, by: step).map {
            CLLocationCoordinate2D(latitude: present[$0].latitude, longitude: present[$0].longitude)
        }
    }

    var body: some View {
        let coordinates = coordinates
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Route")
            Map(initialPosition: .automatic) {
                MapPolyline(coordinates: coordinates)
                    .stroke(Color.orange, lineWidth: 3)
                if let start = coordinates.first {
                    Marker("Start", systemImage: "flag", coordinate: start).tint(.green)
                }
                if let end = coordinates.last, coordinates.count > 1 {
                    Marker("Finish", systemImage: "flag.checkered", coordinate: end).tint(.red)
                }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
