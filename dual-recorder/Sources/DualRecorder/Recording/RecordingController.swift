import AppKit
import DualRecorderCore
import Foundation

/// An unfinished ride found on disk at launch (the app quit or crashed while recording).
struct RecoverableRide: Identifiable {
    let url: URL
    let ride: Ride
    var id: URL { url }
}

/// Samples every sensor once per second, records rides, and exports FIT files.
///
/// Sampling runs all the time so live values are available before a ride starts; while recording,
/// each second is also appended to the ride and to a crash-recovery journal on disk.
final class RecordingController: ObservableObject {
    enum Phase: Equatable {
        case idle, recording, finished
    }

    @Published private(set) var phase: Phase = .idle
    @Published var eventName = "" {
        didSet {
            if phase == .recording, eventName != oldValue { journal?.update(eventName: eventName) }
        }
    }
    @Published private(set) var startedAt: Date?
    /// The most recent completed second, for live display.
    @Published private(set) var latest = SecondSample(time: 0)
    /// Power meter vs trainer over the whole ride so far.
    @Published private(set) var rideComparison: PowerComparison?
    /// Sources in this ride that are currently not delivering data.
    @Published private(set) var silentSources: Set<String> = []
    @Published private(set) var summary: RideSummary?
    @Published var showingSummary = false
    @Published private(set) var lastError: String?
    @Published private(set) var recoverableRides: [RecoverableRide] = []

    let exportDirectory: URL
    private let fallbackDirectory: URL
    private let journalDirectory: URL
    private let sensors: SensorManager
    private let alerts = AlertService()

    private var sampler = SecondSampler()
    private var recent: [SecondSample] = []
    private var nextSecond: Int64
    private var timer: Timer?
    private var knownSources: [String: SourceInfo] = [:]

    // The ride being recorded.
    private var recordFrom: Int64 = 0
    private var rideSources: [SourceInfo] = []
    private var rideSamples: [SecondSample] = []
    private var journal: RideJournalWriter?
    private var activity: NSObjectProtocol?
    private var noDataWarned: Set<String> = []

    init(sensors: SensorManager) {
        self.sensors = sensors
        let fileManager = FileManager.default
        exportDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dual Recorder", isDirectory: true)
        journalDirectory = support.appendingPathComponent("In Progress", isDirectory: true)
        fallbackDirectory = support.appendingPathComponent("Exports", isDirectory: true)
        nextSecond = Int64(Date().timeIntervalSince1970.rounded(.down))

        sensors.onReading = { [weak self] sensor, reading, date in
            self?.ingest(sensor.sourceInfo, reading, at: date)
        }
        alerts.requestAuthorization()
        findRecoverableRides()
        // Touch Documents now so macOS asks for access at first launch rather than after the first ride.
        _ = try? fileManager.contentsOfDirectory(atPath: exportDirectory.path)

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Live values

    var isRecording: Bool { phase == .recording }

    /// At least one sensor has its record switch on.
    var hasRecordableSensors: Bool {
        sensors.sensors.contains { $0.isEnabled }
    }

    var elapsed: TimeInterval {
        guard let startedAt, phase == .recording else { return 0 }
        return max(0, Date().timeIntervalSince(startedAt))
    }

    func values(for id: String) -> SourceValues? {
        latest.values[id]
    }

    /// 3-second average power, like most head units show.
    func displayPower(for id: String) -> Int? {
        guard latest.values[id]?.power != nil else { return nil }
        return RideStats.average(recent.suffix(3).compactMap { $0.values[id]?.power })
    }

    /// Power meter vs trainer over the last 10 seconds.
    var liveComparison: PowerComparison? {
        let live = sensors.sensors.map(\.sourceInfo).filter { latest.values[$0.id]?.power != nil }
        guard let pair = RideStats.comparisonPair(in: live) else { return nil }
        return RideStats.compare(pair.powerMeter, with: pair.trainer, over: recent.suffix(10))
    }

    // MARK: Sampling

    private func ingest(_ source: SourceInfo, _ reading: SensorReading, at date: Date) {
        knownSources[source.id] = source
        sampler.add(reading, from: source.id, at: date.timeIntervalSince1970)
    }

    private func tick() {
        let current = Int64(Date().timeIntervalSince1970.rounded(.down))
        // After the Mac slept while idle there's nothing to catch up on.
        if phase != .recording, current - nextSecond > 5 {
            nextSecond = current - 1
        }
        // A second is complete once the clock has moved past it.
        while nextSecond < current {
            handle(sampler.flush(second: nextSecond))
            nextSecond += 1
        }
        if phase == .recording { checkSensorHealth() }
    }

    private func handle(_ sample: SecondSample) {
        // Only sensors that are still added and switched on count, even for a reading that
        // arrived just before one was switched off or forgotten.
        let recordable = Set(sensors.sensors.filter(\.isEnabled).map(\.id.uuidString))
        let sample = sample.keeping(sources: recordable)
        recent.append(sample)
        if recent.count > 30 { recent.removeFirst(recent.count - 30) }

        if phase == .recording, sample.time >= recordFrom {
            let order = Dictionary(sensors.sensors.enumerated().map { ($1.id.uuidString, $0) },
                                   uniquingKeysWith: { first, _ in first })
            let newIDs = sample.values.keys
                .filter { id in !rideSources.contains { $0.id == id } }
                .sorted { (order[$0] ?? .max, $0) < (order[$1] ?? .max, $1) }
            for id in newIDs {
                guard let info = knownSources[id] else { continue }
                rideSources.append(info)
                journal?.add(source: info)
            }
            rideSamples.append(sample)
            journal?.add(sample: sample)
            if let pair = RideStats.comparisonPair(in: rideSources.map { knownSources[$0.id] ?? $0 }) {
                rideComparison = RideStats.compare(pair.powerMeter, with: pair.trainer, over: rideSamples)
            }
        }
        latest = sample
    }

    // MARK: Recording

    func start() {
        guard phase != .recording else { return }
        let now = Date()
        startedAt = now
        recordFrom = Int64(now.timeIntervalSince1970.rounded(.down))
        rideSources = []
        rideSamples = []
        rideComparison = nil
        silentSources = []
        noDataWarned = []
        summary = nil
        showingSummary = false
        lastError = nil

        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let journalURL = journalDirectory.appendingPathComponent("\(stamp).\(RideJournal.fileExtension)")
        do {
            journal = try RideJournalWriter(url: journalURL, startedAt: now, eventName: eventName)
        } catch {
            journal = nil
            lastError = "Crash protection is off for this ride: \(error.localizedDescription)"
        }
        // Keep the Mac awake and stop macOS from suspending or quietly quitting the app.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Recording a ride")
        phase = .recording
    }

    func stop() {
        guard phase == .recording else { return }
        // Include the second that is in progress.
        let current = Int64(Date().timeIntervalSince1970.rounded(.down))
        while nextSecond <= current {
            handle(sampler.flush(second: nextSecond))
            nextSecond += 1
        }
        // Use the latest names and kinds, in case a sensor was renamed during the ride.
        let sources = rideSources.map { knownSources[$0.id] ?? $0 }
        let ride = Ride(startedAt: startedAt ?? Date(), eventName: eventName, sources: sources, samples: rideSamples)
        let journalURL = journal?.url
        journal?.close()
        journal = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        rideSamples = []
        silentSources = []
        phase = .finished
        export(ride, journalURL: journalURL)
    }

    func dismissSummary() {
        showingSummary = false
    }

    private func export(_ ride: Ride, journalURL: URL?) {
        lastError = nil
        do {
            let urls = try RideExporter.write(ride, to: exportDirectory)
            finishExport(ride, urls: urls, journalURL: journalURL)
        } catch {
            let reason = error.localizedDescription
            do {
                let urls = try RideExporter.write(ride, to: fallbackDirectory)
                finishExport(ride, urls: urls, journalURL: journalURL)
                lastError = "Couldn't save to Documents (\(reason)), so the files were saved in Dual Recorder's own folder instead."
            } catch {
                summary = RideSummary(ride: ride, files: [])
                lastError = "Couldn't save the FIT files (\(reason)). The ride has been kept and will be offered for recovery next time Dual Recorder starts."
                showingSummary = true
            }
        }
    }

    private func finishExport(_ ride: Ride, urls: [URL], journalURL: URL?) {
        summary = RideSummary(ride: ride, files: urls)
        if urls.isEmpty {
            lastError = "No sensor data was recorded, so no file was saved."
        }
        if let journalURL { try? FileManager.default.removeItem(at: journalURL) }
        showingSummary = true
    }

    // MARK: Dropout alerts

    private func checkSensorHealth() {
        let now = Date()
        for source in rideSources {
            let sensor = sensors.sensor(id: source.id)
            let name = sensor?.displayName ?? source.name
            let live = sensor?.isLive(within: 5, now: now) ?? false
            if !live, !silentSources.contains(source.id) {
                silentSources.insert(source.id)
                let detail = sensor?.state == .connected
                    ? "Connected, but no data for 5 seconds."
                    : "It disconnected. Dual Recorder reconnects automatically as soon as it's back."
                alerts.warn(title: "\(name) stopped sending data", body: detail)
            } else if live, silentSources.contains(source.id) {
                silentSources.remove(source.id)
                alerts.inform(title: "\(name) is back", body: "Recording continues.")
            }
        }

        // Saved sensors that haven't delivered anything a minute into the ride.
        guard let startedAt, now.timeIntervalSince(startedAt) > 60 else { return }
        for sensor in sensors.sensors where sensor.isEnabled {
            let id = sensor.id.uuidString
            guard !noDataWarned.contains(id), !rideSources.contains(where: { $0.id == id }) else { continue }
            noDataWarned.insert(id)
            alerts.warn(title: "No data from \(sensor.displayName)",
                        body: "It hasn't sent anything since recording started.")
        }
    }

    // MARK: Crash recovery

    private func findRecoverableRides() {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil)) ?? []
        recoverableRides = files
            .filter { $0.pathExtension == RideJournal.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let ride = RideJournal.read(from: url), !ride.samples.isEmpty else {
                    try? fileManager.removeItem(at: url)
                    return nil
                }
                return RecoverableRide(url: url, ride: ride)
            }
    }

    func recover(_ item: RecoverableRide) {
        guard phase != .recording else { return }
        recoverableRides.removeAll { $0.id == item.id }
        phase = .finished
        export(item.ride, journalURL: item.url)
    }

    func discard(_ item: RecoverableRide) {
        recoverableRides.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: item.url)
    }
}
