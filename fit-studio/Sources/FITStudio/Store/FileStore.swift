import AppKit
import FITStudioCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case compare
    case file(UUID)
}

enum FileTab: String, CaseIterable, Identifiable {
    case summary, charts, adjust, data, messages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return "Summary"
        case .charts: return "Charts"
        case .adjust: return "Adjust"
        case .data: return "Data"
        case .messages: return "Messages"
        }
    }

    var symbol: String {
        switch self {
        case .summary: return "list.bullet.rectangle"
        case .charts: return "chart.xyaxis.line"
        case .adjust: return "slider.horizontal.3"
        case .data: return "tablecells"
        case .messages: return "doc.text.magnifyingglass"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .summary: return "1"
        case .charts: return "2"
        case .adjust: return "3"
        case .data: return "4"
        case .messages: return "5"
        }
    }
}

extension UTType {
    /// FIT activity files (declared in Info.plist).
    static let fit = UTType(importedAs: "com.garmin.fit", conformingTo: .data)

    /// Types an open panel should accept for FIT files: ours, plus whatever type another app
    /// may have registered for the .fit extension.
    static var fitFileTypes: [UTType] {
        [.fit] + [UTType(filenameExtension: "fit")].compactMap { $0 }.filter { $0 != .fit }
    }
}

/// The files the user has opened, the selection, and the comparison setup.
@MainActor
final class FileStore: ObservableObject {
    @Published private(set) var files: [LoadedFile] = []
    @Published var selection: SidebarItem?
    @Published var tab: FileTab = .summary
    @Published var loading: [URL] = []
    @Published var alert: StoreAlert?
    @Published var compare = CompareSetup()

    struct StoreAlert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    var selectedFile: LoadedFile? {
        guard case .file(let id) = selection else { return nil }
        return files.first { $0.id == id }
    }

    func file(_ id: UUID?) -> LoadedFile? {
        files.first { $0.id == id }
    }

    func show(_ tab: FileTab) {
        if selectedFile == nil, let first = files.first { selection = .file(first.id) }
        self.tab = tab
    }

    // MARK: Opening

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open FIT Files"
        panel.allowedContentTypes = UTType.fitFileTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    func open(_ urls: [URL]) {
        for url in urls {
            if let existing = files.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                selection = .file(existing.id)
                continue
            }
            guard !loading.contains(url) else { continue }
            loading.append(url)
            Task {
                let result = await Task.detached(priority: .userInitiated) { () -> Result<(FITFile, Activity), Error> in
                    Result {
                        let data = try Data(contentsOf: url)
                        let file = try FITFile(data: data)
                        return (file, Activity(file: file))
                    }
                }.value
                self.loading.removeAll { $0 == url }
                switch result {
                case .success(let (file, activity)):
                    let loaded = LoadedFile(url: url, file: file, activity: activity)
                    self.files.append(loaded)
                    self.selection = .file(loaded.id)
                    self.compare.fileAdded(loaded, all: self.files)
                case .failure(let error):
                    self.alert = StoreAlert(title: "Couldn’t open “\(url.lastPathComponent)”", message: error.localizedDescription)
                }
            }
        }
    }

    func close(_ file: LoadedFile) {
        if file.hasUnsavedAdjustments {
            let alert = NSAlert()
            alert.messageText = "Close “\(file.name)” without saving its adjustments?"
            alert.informativeText = "The original file isn’t changed either way."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let index = files.firstIndex { $0.id == file.id }
        files.removeAll { $0.id == file.id }
        compare.fileRemoved(file.id, all: files)
        if selection == .file(file.id) {
            if let index, !files.isEmpty {
                selection = .file(files[min(index, files.count - 1)].id)
            } else {
                selection = nil
            }
        }
    }

    func closeSelection() {
        if let file = selectedFile { close(file) }
    }

    // MARK: Saving

    func saveAdjustedCopyOfSelection() {
        if let file = selectedFile { saveAdjustedCopy(of: file) }
    }

    /// Writes the adjusted copy next to the original by default. The original is never overwritten.
    func saveAdjustedCopy(of file: LoadedFile) {
        guard file.hasAdjustments else {
            alert = StoreAlert(title: "Nothing to save", message: "Set a percentage for at least one channel in the Adjust tab first.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Adjusted Copy"
        panel.allowedContentTypes = [.fit]
        panel.nameFieldStringValue = file.suggestedAdjustedName
        panel.directoryURL = file.url.deletingLastPathComponent()
        panel.message = "The original file stays as it is."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if destination.standardizedFileURL == file.url.standardizedFileURL {
            alert = StoreAlert(title: "Choose a different name", message: "FIT Studio never overwrites the original file.")
            return
        }
        do {
            let result = file.makeAdjustedCopy()
            try result.data.write(to: destination, options: .atomic)
            file.markSaved(result.report, to: destination)
        } catch {
            alert = StoreAlert(title: "Couldn’t save the file", message: error.localizedDescription)
        }
    }

    func exportCSVOfSelection() {
        if let file = selectedFile { exportCSV(of: file) }
    }

    func exportCSV(of file: LoadedFile) {
        let panel = NSSavePanel()
        panel.title = "Export CSV"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = file.name + (file.hasAdjustments ? " (adjusted)" : "") + ".csv"
        panel.directoryURL = file.url.deletingLastPathComponent()
        if file.hasAdjustments { panel.message = "The CSV includes your adjustments." }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let system = UnitSystem(rawValue: UserDefaults.standard.string(forKey: SettingsKey.unitSystem) ?? "") ?? .metric
        do {
            try CSVExporter.csv(file.displayActivity, system: system).write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            alert = StoreAlert(title: "Couldn’t export the CSV", message: error.localizedDescription)
        }
    }

    /// Takes a comparison's suggested percentage to the other file's Adjust tab.
    func applySuggestion(_ percent: Double, channel: ChannelKey, to file: LoadedFile) {
        file.setAdjustment(channel, to: (percent * 100).rounded() / 100)
        selection = .file(file.id)
        tab = .adjust
    }
}
