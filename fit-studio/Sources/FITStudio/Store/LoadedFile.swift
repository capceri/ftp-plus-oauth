import FITStudioCore
import Foundation

/// One opened FIT file, its pending adjustments and cached analysis.
@MainActor
final class LoadedFile: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let file: FITFile
    let activity: Activity

    /// Percent per channel. Applied to previews immediately; written only with "Save Adjusted Copy".
    @Published private(set) var adjustments: [ChannelKey: Double] = [:]
    /// Adjustments as they were at the last save (to know whether there's anything unsaved).
    @Published private(set) var savedAdjustments: [ChannelKey: Double]?
    @Published private(set) var lastSave: (report: AdjustmentReport, url: URL)?

    private var perSecondCache: [ChannelKey: PerSecondSeries] = [:]
    private var statsCache: [ChannelKey: ChannelStats?] = [:]
    private var cachedPower: PowerMetrics??
    private var previewCache: (adjustments: [ChannelKey: Double], activity: Activity)?
    private var cachedLaps: [LapStats]?
    private var linkedCache: [ChannelKey: [String]] = [:]

    init(url: URL, file: FITFile, activity: Activity) {
        self.url = url
        self.file = file
        self.activity = activity
    }

    var name: String { url.deletingPathExtension().lastPathComponent }

    var suggestedAdjustedName: String { "\(name) (adjusted).fit" }

    /// Only channels that are actually adjusted (non-zero).
    var activeAdjustments: [ChannelKey: Double] { adjustments.filter { $0.value != 0 } }

    var hasAdjustments: Bool { !activeAdjustments.isEmpty }

    var hasUnsavedAdjustments: Bool { hasAdjustments && savedAdjustments != activeAdjustments }

    func adjustment(_ key: ChannelKey) -> Double { adjustments[key] ?? 0 }

    func setAdjustment(_ key: ChannelKey, to percent: Double) {
        let clamped = min(max(percent, -99), 500)
        adjustments[key] = clamped == 0 ? nil : clamped
    }

    func resetAdjustments() {
        adjustments = [:]
    }

    /// The activity with adjustments applied (or the original when there are none), for charts and tables.
    var displayActivity: Activity {
        let active = activeAdjustments
        guard !active.isEmpty else { return activity }
        if let cache = previewCache, cache.adjustments == active { return cache.activity }
        let preview = activity.adjusted(by: active)
        previewCache = (active, preview)
        return preview
    }

    func makeAdjustedCopy() -> (data: Data, report: AdjustmentReport) {
        FITAdjuster.adjust(file, activity: activity, percents: activeAdjustments)
    }

    func markSaved(_ report: AdjustmentReport, to url: URL) {
        savedAdjustments = activeAdjustments
        lastSave = (report, url)
    }

    // MARK: Cached analysis of the original

    func perSecond(_ key: ChannelKey) -> PerSecondSeries? {
        if let cached = perSecondCache[key] { return cached }
        guard let channel = activity.channel(key) else { return nil }
        let series = Analysis.perSecond(channel, in: activity)
        perSecondCache[key] = series
        return series
    }

    func stats(_ key: ChannelKey) -> ChannelStats? {
        if let cached = statsCache[key] { return cached }
        let stats = perSecond(key).flatMap { Analysis.stats($0.values) }
        statsCache[key] = stats
        return stats
    }

    var powerMetrics: PowerMetrics? {
        if let cachedPower { return cachedPower }
        let metrics = perSecond(.power).flatMap { Analysis.powerMetrics($0.values) }
        cachedPower = .some(metrics)
        return metrics
    }

    /// The factor a channel's values are multiplied by in previews (1 when not adjusted).
    func factor(_ key: ChannelKey) -> Double {
        guard activity.channel(key)?.isAdjustable == true else { return 1 }
        return 1 + (activeAdjustments[key] ?? 0) / 100
    }

    /// Per-lap statistics of the original records (laps from the file's lap messages).
    var lapStats: [LapStats] {
        if let cachedLaps { return cachedLaps }
        let power = perSecond(.power)?.values
        let heartRate = perSecond(.heartRate)?.values
        let cadence = perSecond(.cadence)?.values
        let speed = perSecond(.speed)?.values
        func slice(_ values: [Double?]?, _ lap: LapSummary) -> [Double?] {
            guard let values, !values.isEmpty else { return [] }
            let lower = max(0, Int(lap.start.rounded()))
            let upper = min(values.count, Int(lap.end.rounded()))
            return lower < upper ? Array(values[lower..<upper]) : []
        }
        func average(_ values: [Double?], nonZero: Bool = false) -> Double? {
            let present = values.compactMap { $0 }.filter { !nonZero || $0 != 0 }
            return present.isEmpty ? nil : present.reduce(0, +) / Double(present.count)
        }
        let laps = activity.info.laps.map { lap in
            let watts = slice(power, lap)
            return LapStats(id: lap.id, start: lap.start, duration: lap.end - lap.start,
                            distance: lap.distance ?? activity.distance(in: lap.start...max(lap.start, lap.end - 1)),
                            power: average(watts), normalizedPower: Analysis.normalizedPower(watts.compactMap { $0 }),
                            maxPower: watts.compactMap { $0 }.max(), heartRate: average(slice(heartRate, lap)),
                            cadence: average(slice(cadence, lap), nonZero: true), speed: average(slice(speed, lap)))
        }
        cachedLaps = laps
        return laps
    }

    /// Names of the lap/session values in this file that follow a channel when it's adjusted.
    func linkedSummaryFields(_ key: ChannelKey) -> [String] {
        if let cached = linkedCache[key] { return cached }
        let links = Set(FITAdjuster.summaryLinks(for: key).map(\.name))
        var names: [String] = []
        var seen = Set<String>()
        for definition in file.definitions where FITAdjuster.summaryMessages.contains(definition.globalNumber) {
            for field in definition.fields {
                guard let profile = FITProfile.field(message: definition.globalNumber, number: field.number),
                      links.contains(profile.name) else { continue }
                let name = FITNames.humanize(profile.name.replacingOccurrences(of: "enhanced_", with: ""))
                if seen.insert(name).inserted { names.append(name) }
            }
        }
        if key == .power, activity.channel(ChannelKey("accumulated_power")) != nil {
            names.insert("Accumulated power", at: 0)
        }
        linkedCache[key] = names
        return names
    }

    /// Per-second values with this file's adjustment applied (used by the comparison).
    func adjustedPerSecond(_ key: ChannelKey) -> PerSecondSeries? {
        guard var series = perSecond(key) else { return nil }
        let percent = activeAdjustments[key] ?? 0
        guard percent != 0, activity.channel(key)?.isAdjustable == true else { return series }
        let factor = 1 + percent / 100
        series.values = series.values.map { $0.map { $0 * factor } }
        return series
    }
}

struct LapStats: Identifiable {
    var id: Int
    var start: Double
    var duration: Double
    var distance: Double?
    var power: Double?
    var normalizedPower: Double?
    var maxPower: Double?
    var heartRate: Double?
    var cadence: Double?
    var speed: Double?
}
