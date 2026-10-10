import FITStudioCore
import Foundation

/// What the comparison view compares and how.
struct CompareSetup {
    /// Up to this many files are compared against the reference.
    static let maxOthers = 3

    var referenceID: UUID?
    var otherIDs: [UUID] = []
    var channel: ChannelKey = .power
    /// Line files up by their timestamps (same ride recorded twice). Off: by their starts.
    var alignByClock = true
    /// Extra shift per compared file, in seconds (positive: the file is moved later).
    var offsets: [UUID: Int] = [:]
    /// The channel to compare in each other file, when it isn't the reference's channel
    /// (e.g. a developer "Power" field against native power).
    var otherChannels: [UUID: ChannelKey] = [:]
    var ignoreZeros = false
    var smoothing = 10
    var differenceInPercent = true
    /// Compare with each file's pending adjustments applied.
    var includeAdjustments = true

    func offset(_ id: UUID) -> Int { offsets[id] ?? 0 }

    func channel(for id: UUID) -> ChannelKey { otherChannels[id] ?? channel }

    mutating func fileAdded(_ file: LoadedFile, all: [LoadedFile]) {
        if referenceID == nil {
            referenceID = file.id
        } else if file.id != referenceID, otherIDs.count < Self.maxOthers, !otherIDs.contains(file.id) {
            otherIDs.append(file.id)
        }
    }

    mutating func fileRemoved(_ id: UUID, all: [LoadedFile]) {
        otherIDs.removeAll { $0 == id }
        offsets[id] = nil
        otherChannels[id] = nil
        if referenceID == id {
            referenceID = otherIDs.first ?? all.first?.id
            otherIDs.removeAll { $0 == referenceID }
        }
    }

    mutating func makeReference(_ id: UUID) {
        guard id != referenceID else { return }
        if let old = referenceID {
            otherIDs = otherIDs.map { $0 == id ? old : $0 }
        }
        otherIDs.removeAll { $0 == id }
        referenceID = id
    }

    mutating func toggleOther(_ id: UUID) {
        if let index = otherIDs.firstIndex(of: id) {
            otherIDs.remove(at: index)
        } else if id != referenceID {
            if otherIDs.count >= Self.maxOthers { otherIDs.removeFirst() }
            otherIDs.append(id)
        }
    }
}
